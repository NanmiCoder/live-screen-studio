import AppKit
import CoreGraphics
import CursorKit
import os

/// Global mouse hooks, run on their own thread so a busy main thread never delays anyone's scrolling or clicks.
///
/// - Clicking the trigger button toggles zoom; holding it and turning the wheel a full notch adjusts zoom.
///   ⌥ + trigger passes through, so the normal middle click is still available.
/// - Left and right clicks are observed (listen-only) for click effects.
/// - While zoomed the cursor is kept inside `cursorBounds`, so it cannot slip onto another display or bring up
///   the Dock: zooming out is always a deliberate click.
/// - While drawing is armed (zoomed in), a left drag draws instead of dragging; a left click still clicks
///   (it is replayed on release, ⌘ included), ⌘-drag is a normal drag and right click undoes a stroke.
/// - While zoomed in, the recorded highlight shortcuts are taken from the keyboard, and Esc clears the strokes
///   and highlights. No key is ever taken while not zoomed.
/// - If the main thread hangs, every event passes through untouched.
final class InputTap {
    enum Action {
        case toggle
        /// Wheel notches; positive when the wheel rolls away from the user.
        case adjustZoom(CGFloat)
        /// A left or right click, in global CG coordinates (top-left origin).
        case click(CGPoint)
        /// The cursor follows swallowed input until the system cursor has caught up.
        case drawingPointer(CGPoint?)
        case strokeBegan(CGPoint)
        /// `straight` while ⇧ is held: the stroke becomes a line from its start.
        case strokeMoved(CGPoint, straight: Bool)
        case strokeEnded
        case undoStroke
        case clearStrokes
        case highlight(HighlightKind)
    }

    /// A key with the modifiers held for it; only ⌘ ⌥ ⌃ ⇧ count.
    struct KeyCombo: Hashable {
        static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

        let keyCode: Int64
        let modifiers: UInt64

        init(keyCode: Int64, modifiers: UInt64) {
            self.keyCode = keyCode
            self.modifiers = modifiers & Self.modifierMask.rawValue
        }
    }

    var onAction: ((Action) -> Void)?

    var triggerButton: Int64 {
        get { state.withLock { $0.triggerButton } }
        set { state.withLock { $0.triggerButton = newValue } }
    }
    var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }
    /// Left drags draw while armed.
    var drawingArmed: Bool {
        get { state.withLock { $0.drawingArmed } }
        set {
            let interrupted = state.withLock { s -> DrawGesture in
                let previous = s.draw
                s.drawingArmed = newValue
                s.swallowRightUp = false
                switch s.draw {
                case .drawing, .finishing:
                    // Keep taking this drag until release, even if zoom or drawing was turned off midway.
                    s.draw = .finishing
                case .idle, .pending, .passthrough:
                    s.draw = .idle
                    s.drawPointer = nil
                }
                return previous
            }
            // Zooming out shows the system cursor again: put it at the pen tip now rather than on the next move.
            let tip = newValue ? nil : state.withLock { s -> CGPoint? in
                defer { s.penTip = nil }
                return s.penTip
            }
            if let tip {
                movePointer(to: tip)
                emit(.drawingPointer(nil))
            }
            updateDrawTap()
            switch interrupted {
            case .pending(let down, _):
                // The app never saw this press; hand it over so the coming release is not an orphan.
                down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                down.post(tap: .cgSessionEventTap)
                emit(.drawingPointer(nil))
            case .drawing:
                emit(.strokeEnded)
            case .idle, .passthrough, .finishing:
                break
            }
        }
    }
    /// Where the cursor may go, in global CG coordinates (top-left origin), edges included; nil leaves it free.
    var cursorBounds: CGRect? {
        get { state.withLock { $0.cursorBounds } }
        set {
            state.withLock { $0.cursorBounds = newValue }
            if let confineTap { CGEvent.tapEnable(tap: confineTap, enable: newValue != nil) }
        }
    }
    /// The highlight shortcuts; they and Esc only act while armed (zoomed in).
    var shortcuts: [KeyCombo: HighlightKind] {
        get { state.withLock { $0.shortcuts } }
        set { state.withLock { $0.shortcuts = newValue } }
    }
    var keysArmed: Bool {
        get { state.withLock { $0.keysArmed } }
        set {
            state.withLock {
                $0.keysArmed = newValue
                // A key still held now is released while the tap is off; never swallow a later release of it.
                $0.heldKeys.removeAll()
            }
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: newValue) }
        }
    }
    /// Right click and Esc only act on strokes when there are some; otherwise they pass through.
    var hasStrokes: Bool {
        get { state.withLock { $0.hasStrokes } }
        set { state.withLock { $0.hasStrokes = newValue } }
    }

    var isRunning: Bool { triggerTap != nil }

    private enum DrawGesture {
        case idle
        /// Left button down, not moved far enough yet to tell a click from a drag. With ⌘ a drag becomes a
        /// normal drag, without it a stroke.
        case pending(down: CGEvent, command: Bool)
        case drawing
        /// Drawing was disarmed mid-stroke; take the remaining drag and release without extending the stroke.
        case finishing
        /// ⌘ was held: a normal drag, passed through without ⌘.
        case passthrough
    }

    private struct State {
        var triggerButton = Int64(TriggerButton.middle.rawValue)
        var enabled = true
        var drawingArmed = false
        var hasStrokes = false
        var triggerPressed = false
        /// Set once the wheel has moved a full notch while the trigger is held; then the press adjusts zoom
        /// instead of toggling. A free-spinning wheel wobbles a little when clicked, so smaller amounts are ignored.
        var adjusting = false
        var wheel: CGFloat = 0
        var draw = DrawGesture.idle
        var drawPointer: DragPointer?
        /// After a stroke the system cursor is still where the stroke began; the next moves the system delivers
        /// bring it to the pen tip. Until then this is where the cursor really is, and how many of those moves
        /// have been seen.
        var penTip: CGPoint?
        var penTipMoves = 0
        var swallowRightUp = false
        var cursorBounds: CGRect?
        var shortcuts: [KeyCombo: HighlightKind] = [:]
        var keysArmed = false
        /// Keys whose press was taken, so their release is taken too.
        var heldKeys: Set<Int64> = []
    }

    /// Marks events LiveZoom re-posts itself so its own taps let them through.
    private static let syntheticMarker: Int64 = 0x4C5A_0001
    private static let dragThreshold: CGFloat = 4
    private static let escapeKeyCode: Int64 = 53

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var triggerTap: CFMachPort?
    private var scrollTap: CFMachPort?
    private var clickTap: CFMachPort?
    private var drawTap: CFMachPort?
    private var confineTap: CFMachPort?
    private var keyTap: CFMachPort?

    /// Fails until the app has Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard triggerTap == nil else { return true }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let trigger = Self.makeTap([.otherMouseDown, .otherMouseUp], options: .defaultTap, me, triggerCallback)
        else { return false }
        let scroll = Self.makeTap([.scrollWheel], options: .defaultTap, me, scrollCallback)
        let click = Self.makeTap([.leftMouseDown, .rightMouseDown], options: .listenOnly, me, clickCallback)
        let draw = Self.makeTap([.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp],
                                options: .defaultTap, me, drawCallback)
        let keys = Self.makeTap([.keyDown, .keyUp], options: .defaultTap, me, keyCallback)
        // Created last, so it comes first; swallowed drags keep their raw samples for the draw tap.
        let confine = Self.makeTap([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged],
                                   options: .defaultTap, me, confineCallback)
        if scroll == nil || click == nil || draw == nil || confine == nil || keys == nil {
            log("some input taps could not be created (scroll \(scroll != nil), click \(click != nil), draw \(draw != nil), confine \(confine != nil), keys \(keys != nil))")
        }
        triggerTap = trigger
        scrollTap = scroll
        clickTap = click
        drawTap = draw
        confineTap = confine
        keyTap = keys
        // The scroll, draw, confine and key taps only run while needed.
        if let scroll { CGEvent.tapEnable(tap: scroll, enable: false) }
        if let draw { CGEvent.tapEnable(tap: draw, enable: drawingArmed) }
        if let confine { CGEvent.tapEnable(tap: confine, enable: cursorBounds != nil) }
        if let keys { CGEvent.tapEnable(tap: keys, enable: keysArmed) }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            for tap in [trigger, scroll, click, draw, confine, keys].compactMap({ $0 }) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "LiveZoom input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    private static func makeTap(_ types: [CGEventType], options: CGEventTapOptions, _ me: UnsafeMutableRawPointer,
                                _ callback: CGEventTapCallBack) -> CFMachPort? {
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        return CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                 eventsOfInterest: mask, callback: callback, userInfo: me)
    }

    private func emit(_ action: Action) {
        emit([action])
    }

    private func emit(_ actions: [Action]) {
        guard !actions.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for action in actions { self?.onAction?(action) }
        }
    }

    /// The system disables a tap whose callback was slow; turn it back on if it should be running.
    private func reenable(_ tap: CFMachPort?, when wanted: Bool) {
        if let tap, wanted { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: - Trigger button and wheel

    fileprivate func handleTrigger(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reenable(triggerTap, when: true)
            return pass
        case .otherMouseDown:
            guard !MainThreadWatch.shared.isStalled else { return pass }
            let start = state.withLock { s -> Bool in
                guard s.enabled, event.getIntegerValueField(.mouseEventButtonNumber) == s.triggerButton,
                      !event.flags.contains(.maskAlternate) else { return false }
                s.triggerPressed = true
                s.adjusting = false
                s.wheel = 0
                return true
            }
            guard start else { return pass }
            if let scrollTap { CGEvent.tapEnable(tap: scrollTap, enable: true) }
            return nil
        case .otherMouseUp:
            let result = state.withLock { s -> (handled: Bool, toggle: Bool) in
                guard s.triggerPressed, event.getIntegerValueField(.mouseEventButtonNumber) == s.triggerButton else {
                    return (false, false)
                }
                s.triggerPressed = false
                return (true, !s.adjusting)
            }
            guard result.handled else { return pass }
            if let scrollTap { CGEvent.tapEnable(tap: scrollTap, enable: false) }
            if result.toggle { emit(.toggle) }
            return nil
        default:
            return pass
        }
    }

    fileprivate func handleScroll(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard type == .scrollWheel else {
            reenable(scrollTap, when: state.withLock { $0.triggerPressed })
            return pass
        }
        let steps = Self.wheelSteps(event)
        let outcome = state.withLock { s -> (swallow: Bool, adjust: CGFloat?) in
            guard s.triggerPressed else { return (false, nil) }
            // The button-up may have been lost while a tap was disabled.
            guard let button = CGMouseButton(rawValue: UInt32(s.triggerButton)),
                  CGEventSource.buttonState(.combinedSessionState, button: button) else {
                s.triggerPressed = false
                return (false, nil)
            }
            s.wheel += steps
            if !s.adjusting, abs(s.wheel) >= 1 { s.adjusting = true }
            guard s.adjusting, s.wheel != 0 else { return (true, nil) }
            defer { s.wheel = 0 }
            return (true, s.wheel)
        }
        if let adjust = outcome.adjust { emit(.adjustZoom(adjust)) }
        if !outcome.swallow, let scrollTap { CGEvent.tapEnable(tap: scrollTap, enable: false) }
        return outcome.swallow ? nil : pass
    }

    private static func wheelSteps(_ event: CGEvent) -> CGFloat {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        // A notched wheel reports whole lines per notch; smooth (pixel) scrolling is converted at ~40 pt a notch.
        var steps = continuous
            ? CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)) / 40
            : CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        // Undo natural scrolling so "wheel away from you" always zooms in.
        if NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == true { steps = -steps }
        return steps
    }

    // MARK: - Clicks (listen only)

    fileprivate func handleClick(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reenable(clickTap, when: true)
        case .leftMouseDown, .rightMouseDown:
            // While drawing is armed the draw tap reports clicks itself, once it knows it was not a stroke.
            guard !state.withLock({ $0.drawingArmed }) else { return }
            emit(.click(event.location))
        default:
            break
        }
    }

    // MARK: - Drawing

    private var wantsDrawTap: Bool {
        state.withLock { $0.drawingArmed || $0.drawPointer != nil || $0.penTip != nil }
    }

    private func updateDrawTap() {
        if let drawTap { CGEvent.tapEnable(tap: drawTap, enable: wantsDrawTap) }
    }

    /// A free move or a new press recovers a missed release without polling session button state.
    private func recoverDrawing() {
        let actions = state.withLock { s -> [Action] in
            let previous = s.draw
            let tip = s.drawPointer?.location
            s.draw = .idle
            s.drawPointer = nil
            switch previous {
            case .drawing:
                s.penTip = tip
                s.penTipMoves = 0
                return [.strokeEnded]
            case .pending, .finishing: return [.drawingPointer(nil)]
            case .idle, .passthrough: return []
            }
        }
        emit(actions)
        if !drawingArmed { updateDrawTap() }
    }

    /// Lets the system cursor catch up with the pen tip after a stroke, without a warp: a warp right after the
    /// stroke made the mouse stall when moved back. The first move the system delivers takes the cursor there; the
    /// drawn cursor stays on the tip until the move after it, when the system position can be trusted again. Should
    /// the system not have kept the stroke's movement, the event is moved to the tip instead.
    private func settleAfterStroke(_ type: CGEventType, _ event: CGEvent) {
        let step = state.withLock { s -> (tip: CGPoint, first: Bool, bounds: CGRect?)? in
            guard let tip = s.penTip else { return nil }
            s.penTipMoves += 1
            // A press starts a new gesture, which tracks the pointer itself.
            if s.penTipMoves >= 2 || type != .mouseMoved { s.penTip = nil }
            return (tip, s.penTipMoves == 1, s.cursorBounds)
        }
        guard let step else { return }
        guard step.first else {
            emit(.drawingPointer(nil))
            if !drawingArmed { updateDrawTap() }
            return
        }
        var expected = step.tip
        if type == .mouseMoved {
            expected.x += CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
            expected.y += CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
        }
        if let bounds = step.bounds {
            expected = CGPoint(x: min(max(expected.x, bounds.minX), bounds.maxX),
                               y: min(max(expected.y, bounds.minY), bounds.maxY))
        }
        let location = event.location
        if hypot(location.x - expected.x, location.y - expected.y) > 40 {
            log(String(format: "the pointer did not keep the stroke's movement (%.0f pt off); moving it to the pen tip",
                       hypot(location.x - expected.x, location.y - expected.y)))
            movePointer(to: expected)
            event.location = expected
        }
        if type == .mouseMoved { emit(.drawingPointer(event.location)) }
    }

    fileprivate func handleDraw(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable(drawTap, when: wantsDrawTap)
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker,
              !MainThreadWatch.shared.isStalled else { return pass }
        let location = event.location

        switch type {
        case .mouseMoved:
            recoverDrawing()
            settleAfterStroke(type, event)
            return pass

        case .leftMouseDown:
            recoverDrawing()
            settleAfterStroke(type, event)
            let location = event.location
            let point = state.withLock { s -> CGPoint? in
                guard s.drawingArmed else { return nil }
                let pointer = DragPointer(at: location, bounds: s.cursorBounds)
                let down = event.copy() ?? event
                down.location = pointer.location
                s.draw = .pending(down: down, command: event.flags.contains(.maskCommand))
                s.drawPointer = pointer
                return pointer.location
            }
            guard let point else { return pass }
            emit(.drawingPointer(point))
            return nil

        case .leftMouseDragged:
            let step = state.withLock { s -> (gesture: DrawGesture, startDrag: CGEvent?, point: CGPoint, actions: [Action]) in
                s.drawPointer?.move(to: location, bounds: s.cursorBounds)
                let point = s.drawPointer?.location ?? location
                switch s.draw {
                case .pending(let down, let command):
                    let start = down.location
                    guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else {
                        return (s.draw, nil, point, [.drawingPointer(point)])
                    }
                    if command {
                        s.draw = .passthrough
                        s.drawPointer = nil
                        return (s.draw, down, point, [.drawingPointer(nil)])
                    }
                    s.draw = .drawing
                    return (s.draw, nil, point, [.drawingPointer(point), .strokeBegan(start),
                                                .strokeMoved(point, straight: event.flags.contains(.maskShift))])
                case .drawing:
                    return (s.draw, nil, point, [.drawingPointer(point),
                                                .strokeMoved(point, straight: event.flags.contains(.maskShift))])
                case .finishing:
                    return (s.draw, nil, point, [.drawingPointer(point)])
                case .idle, .passthrough:
                    return (s.draw, nil, point, [])
                }
            }
            emit(step.actions)
            if let down = step.startDrag {
                // ⌘-drag: give the app the press it has not seen, then this drag, both without ⌘, in order.
                let drag = event.copy() ?? event
                drag.location = step.point
                for replay in [down, drag] {
                    replay.flags.remove(.maskCommand)
                    replay.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                    replay.tapPostEvent(proxy)
                }
                return nil
            }
            switch step.gesture {
            case .idle: return pass
            case .passthrough: return passWithoutCommand(event)
            case .pending, .drawing, .finishing:
                return nil
            }

        case .leftMouseUp:
            let ended = state.withLock { s -> (gesture: DrawGesture, point: CGPoint?) in
                defer {
                    s.draw = .idle
                    s.drawPointer = nil
                }
                return (s.draw, s.drawPointer?.location)
            }
            defer { if !drawingArmed { updateDrawTap() } }
            switch ended.gesture {
            case .idle:
                return pass
            case .passthrough:
                return passWithoutCommand(event)
            case .drawing:
                // No warp here: the system cursor catches up on the next move (see `settleAfterStroke`).
                state.withLock {
                    $0.penTip = ended.point
                    $0.penTipMoves = 0
                }
                emit(.strokeEnded)
                return nil
            case .finishing:
                // Drawing was turned off midway (zooming out), so the system cursor shows again: settle it now.
                if let point = ended.point { movePointer(to: point) }
                emit(.drawingPointer(nil))
                return nil
            case .pending(let down, _):
                // It was a click: replay it as it was (click count and ⌘ included, so double-clicks and
                // ⌘-clicks still work).
                let up = event.copy() ?? event
                for replay in [down, up] {
                    replay.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                    replay.location = down.location
                    replay.tapPostEvent(proxy)
                }
                emit([.drawingPointer(nil), .click(down.location)])
                return nil
            }

        case .rightMouseDown:
            guard drawingArmed else { return pass }
            let undo = state.withLock { s -> Bool in
                guard s.drawingArmed, s.hasStrokes else { return false }
                s.swallowRightUp = true
                return true
            }
            guard undo else {
                emit(.click(location))
                return pass
            }
            emit(.undoStroke)
            return nil

        case .rightMouseUp:
            let swallow = state.withLock { s -> Bool in
                defer { s.swallowRightUp = false }
                return s.swallowRightUp
            }
            return swallow ? nil : pass

        default:
            return pass
        }
    }

    // MARK: - Keys

    fileprivate func handleKey(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable(keyTap, when: keysArmed)
            return pass
        }
        guard !MainThreadWatch.shared.isStalled else { return pass }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            let taken = state.withLock { $0.heldKeys.remove(keyCode) != nil }
            return taken ? nil : pass
        }
        guard type == .keyDown else { return pass }
        let combo = KeyCombo(keyCode: keyCode, modifiers: event.flags.rawValue)
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let action = state.withLock { s -> Action?? in
            guard s.keysArmed else { return nil }
            if let kind = s.shortcuts[combo] {
                s.heldKeys.insert(keyCode)
                // Holding the key down does not repeat the highlight.
                return .some(repeated ? nil : .highlight(kind))
            }
            if keyCode == Self.escapeKeyCode, combo.modifiers == 0, s.hasStrokes {
                s.heldKeys.insert(keyCode)
                return .some(.clearStrokes)
            }
            return nil
        }
        // nil: not ours; .some(nil): ours, but nothing to do (a repeat).
        guard let taken = action else { return pass }
        if let taken { emit(taken) }
        return nil
    }

    // MARK: - Keeping the cursor on the zoomed display

    fileprivate func handleConfine(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable(confineTap, when: cursorBounds != nil)
            return pass
        }
        // A hung app must not trap the cursor on one display.
        guard !MainThreadWatch.shared.isStalled else { return pass }
        let confinement = state.withLock { s in
            (bounds: s.cursorBounds, drawing: type == .leftMouseDragged && s.drawPointer != nil)
        }
        guard let bounds = confinement.bounds, !confinement.drawing else { return pass }
        let location = event.location
        let inside = CGPoint(x: min(max(location.x, bounds.minX), bounds.maxX),
                             y: min(max(location.y, bounds.minY), bounds.maxY))
        guard inside != location else { return pass }
        // The pointer has already moved past the edge; put it back.
        movePointer(to: inside)
        event.location = inside
        return pass
    }

    /// Used to hold the cursor on the zoomed display and, rarely, to settle it after a stroke. Warping each sample
    /// of a swallowed drag stopped the drag, and a warp right after one stalled the next move, so drawing avoids it.
    private func movePointer(to location: CGPoint) {
        CGWarpMouseCursorPosition(location)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// ⌘-drag while zoomed means "normal drag": the app should not see ⌘.
    private func passWithoutCommand(_ event: CGEvent) -> Unmanaged<CGEvent> {
        event.flags.remove(.maskCommand)
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - C callbacks
//
// A handler returns nil to swallow the event, so it must be returned as is: `owner?.handle(…) ?? pass` would
// flatten that nil into "no owner" and pass every swallowed event on to the app.

private func owner(_ userInfo: UnsafeMutableRawPointer?) -> InputTap? {
    userInfo.map { Unmanaged<InputTap>.fromOpaque($0).takeUnretainedValue() }
}

private func triggerCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let tap = owner(userInfo) else { return Unmanaged.passUnretained(event) }
    return tap.handleTrigger(type, event)
}

private func scrollCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let tap = owner(userInfo) else { return Unmanaged.passUnretained(event) }
    return tap.handleScroll(type, event)
}

private func clickCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    owner(userInfo)?.handleClick(type, event)
    return Unmanaged.passUnretained(event)
}

private func drawCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                          userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let tap = owner(userInfo) else { return Unmanaged.passUnretained(event) }
    return tap.handleDraw(proxy, type, event)
}

private func keyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let tap = owner(userInfo) else { return Unmanaged.passUnretained(event) }
    return tap.handleKey(type, event)
}

private func confineCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let tap = owner(userInfo) else { return Unmanaged.passUnretained(event) }
    return tap.handleConfine(type, event)
}

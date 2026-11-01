import AppKit
import CoreGraphics
import os

/// Global mouse hooks, run on their own thread so a busy main thread never delays anyone's scrolling or clicks.
///
/// - Clicking the trigger button toggles zoom; holding it and turning the wheel a full notch adjusts zoom.
///   ⌥ + trigger passes through, so the normal middle click is still available.
/// - Left and right clicks are observed (listen-only) for click effects.
/// - While drawing is armed (zoomed in), a left drag draws instead of dragging; a left click still clicks
///   (it is replayed on release, ⌘ included), ⌘-drag is a normal drag, right click undoes a stroke and Esc
///   clears them.
/// - If the main thread hangs, every event passes through untouched.
final class InputTap {
    enum Action {
        case toggle
        /// Wheel notches; positive when the wheel rolls away from the user.
        case adjustZoom(CGFloat)
        /// A left or right click, in global CG coordinates (top-left origin).
        case click(CGPoint)
        case strokeBegan(CGPoint)
        /// `straight` while ⇧ is held: the stroke becomes a line from its start.
        case strokeMoved(CGPoint, straight: Bool)
        case strokeEnded
        case undoStroke
        case clearStrokes
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
                defer {
                    s.drawingArmed = newValue
                    s.draw = .idle
                    s.swallowRightUp = false
                }
                return s.draw
            }
            if let drawTap { CGEvent.tapEnable(tap: drawTap, enable: newValue) }
            switch interrupted {
            case .pending(let down, _):
                // The app never saw this press; hand it over so the coming release is not an orphan.
                down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                down.post(tap: .cgSessionEventTap)
            case .drawing:
                emit(.strokeEnded)
            case .idle, .passthrough:
                break
            }
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
        var swallowRightUp = false
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

    /// Fails until the app has Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard triggerTap == nil else { return true }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let trigger = Self.makeTap([.otherMouseDown, .otherMouseUp], options: .defaultTap, me, triggerCallback)
        else { return false }
        let scroll = Self.makeTap([.scrollWheel], options: .defaultTap, me, scrollCallback)
        let click = Self.makeTap([.leftMouseDown, .rightMouseDown], options: .listenOnly, me, clickCallback)
        let draw = Self.makeTap([.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown],
                                options: .defaultTap, me, drawCallback)
        if scroll == nil || click == nil || draw == nil {
            log("some input taps could not be created (scroll \(scroll != nil), click \(click != nil), draw \(draw != nil))")
        }
        triggerTap = trigger
        scrollTap = scroll
        clickTap = click
        drawTap = draw
        // The scroll and draw taps only run while needed.
        if let scroll { CGEvent.tapEnable(tap: scroll, enable: false) }
        if let draw { CGEvent.tapEnable(tap: draw, enable: drawingArmed) }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            for tap in [trigger, scroll, click, draw].compactMap({ $0 }) {
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
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
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

    fileprivate func handleDraw(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable(drawTap, when: drawingArmed)
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker,
              !MainThreadWatch.shared.isStalled else { return pass }
        let location = event.location

        switch type {
        case .leftMouseDown:
            let armed = state.withLock { s -> Bool in
                guard s.drawingArmed else { return false }
                s.draw = .pending(down: event.copy() ?? event, command: event.flags.contains(.maskCommand))
                return true
            }
            return armed ? nil : pass

        case .leftMouseDragged:
            let step = state.withLock { s -> (gesture: DrawGesture, startDrag: CGEvent?, actions: [Action]) in
                switch s.draw {
                case .pending(let down, let command):
                    let start = down.location
                    guard hypot(location.x - start.x, location.y - start.y) >= Self.dragThreshold else {
                        return (s.draw, nil, [])
                    }
                    if command {
                        s.draw = .passthrough
                        return (s.draw, down, [])
                    }
                    s.draw = .drawing
                    return (s.draw, nil, [.strokeBegan(start), .strokeMoved(location, straight: event.flags.contains(.maskShift))])
                case .drawing:
                    return (s.draw, nil, [.strokeMoved(location, straight: event.flags.contains(.maskShift))])
                case .idle, .passthrough:
                    return (s.draw, nil, [])
                }
            }
            step.actions.forEach(emit)
            if let down = step.startDrag {
                // ⌘-drag: give the app the press it has not seen, then this drag, both without ⌘, in order.
                for replay in [down, event.copy() ?? event] {
                    replay.flags.remove(.maskCommand)
                    replay.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                    replay.tapPostEvent(proxy)
                }
                return nil
            }
            switch step.gesture {
            case .idle: return pass
            case .passthrough: return passWithoutCommand(event)
            case .pending, .drawing: return nil
            }

        case .leftMouseUp:
            let gesture = state.withLock { s -> DrawGesture in
                defer { s.draw = .idle }
                return s.draw
            }
            switch gesture {
            case .idle:
                return pass
            case .passthrough:
                return passWithoutCommand(event)
            case .drawing:
                emit(.strokeEnded)
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
                emit(.click(down.location))
                return nil
            }

        case .rightMouseDown:
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

        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode,
                  state.withLock({ $0.drawingArmed && $0.hasStrokes }) else { return pass }
            emit(.clearStrokes)
            return nil

        default:
            return pass
        }
    }

    /// ⌘-drag while zoomed means "normal drag": the app should not see ⌘.
    private func passWithoutCommand(_ event: CGEvent) -> Unmanaged<CGEvent> {
        event.flags.remove(.maskCommand)
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - C callbacks

private func owner(_ userInfo: UnsafeMutableRawPointer?) -> InputTap? {
    userInfo.map { Unmanaged<InputTap>.fromOpaque($0).takeUnretainedValue() }
}

private func triggerCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    owner(userInfo)?.handleTrigger(type, event) ?? Unmanaged.passUnretained(event)
}

private func scrollCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    owner(userInfo)?.handleScroll(type, event) ?? Unmanaged.passUnretained(event)
}

private func clickCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    owner(userInfo)?.handleClick(type, event)
    return Unmanaged.passUnretained(event)
}

private func drawCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                          userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    owner(userInfo)?.handleDraw(proxy, type, event) ?? Unmanaged.passUnretained(event)
}

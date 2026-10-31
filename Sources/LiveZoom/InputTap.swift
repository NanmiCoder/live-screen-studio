import AppKit
import CoreGraphics

/// Global mouse hook. Clicking the trigger button toggles zoom; scrolling while holding it adjusts the zoom level.
/// ⌥ + trigger passes through, so a normal middle click is still available.
final class InputTap {
    enum Action {
        case toggle
        /// Wheel notches; positive when the wheel rolls away from the user.
        case adjustZoom(CGFloat)
    }

    var triggerButton: Int64 = Int64(TriggerButton.middle.rawValue)
    var isEnabled = true
    var onAction: ((Action) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pressed = false
    private var scrolledWhilePressed = false

    var isRunning: Bool { tap != nil }

    /// Fails until the app has Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .otherMouseDown:
            guard isEnabled, isTrigger(event), !event.flags.contains(.maskAlternate) else { break }
            pressed = true
            scrolledWhilePressed = false
            return nil
        case .otherMouseUp:
            guard pressed, isTrigger(event) else { break }
            pressed = false
            if !scrolledWhilePressed { onAction?(.toggle) }
            return nil
        case .scrollWheel:
            guard pressed else { break }
            // The button-up may have been lost while the tap was disabled.
            guard let button = CGMouseButton(rawValue: UInt32(triggerButton)),
                  CGEventSource.buttonState(.combinedSessionState, button: button) else {
                pressed = false
                break
            }
            scrolledWhilePressed = true
            let steps = Self.wheelSteps(event)
            if steps != 0 { onAction?(.adjustZoom(steps)) }
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func isTrigger(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.mouseEventButtonNumber) == triggerButton
    }

    private static func wheelSteps(_ event: CGEvent) -> CGFloat {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        var steps = continuous
            ? CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)) / 40
            : CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        // Undo natural scrolling so "wheel away from you" always zooms in.
        if NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == true { steps = -steps }
        return steps
    }
}

private func inputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}

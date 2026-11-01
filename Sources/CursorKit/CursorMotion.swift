import CoreGraphics
import Foundation
import ZoomCore

/// Where the drawn cursor is and how visible it is: optional smoothing and fade-out when idle.
public struct CursorMotion {
    /// 0 follows the mouse exactly.
    public var smoothTime: Double = 0
    /// nil never hides the cursor.
    public var idleDelay: Double?
    public var fadeOutDuration: Double = 0.35
    public var fadeInDuration: Double = 0.08

    public private(set) var position: CGPoint
    public private(set) var opacity: CGFloat = 1

    private var velocity = CGVector.zero
    private var lastInput: CGPoint
    private var lastActivity: TimeInterval

    public init(position: CGPoint, now: TimeInterval) {
        self.position = position
        lastInput = position
        lastActivity = now
    }

    public mutating func update(input: CGPoint, buttonsDown: Bool, now: TimeInterval, dt: Double) {
        if input != lastInput || buttonsDown {
            lastInput = input
            lastActivity = now
        }
        if smoothTime > 0 {
            position = SmoothDamp.step(current: position, target: input, velocity: &velocity, smoothTime: smoothTime,
                                       maxSpeed: .greatestFiniteMagnitude, dt: dt)
        } else {
            position = input
            velocity = .zero
        }
        let hidden = idleDelay.map { now - lastActivity >= $0 } ?? false
        if hidden {
            opacity = max(0, opacity - CGFloat(dt / fadeOutDuration))
        } else {
            opacity = min(1, opacity + CGFloat(dt / fadeInDuration))
        }
    }

    /// Moves without smoothing, e.g. when the drawing starts.
    public mutating func jump(to point: CGPoint, now: TimeInterval) {
        position = point
        lastInput = point
        lastActivity = now
        velocity = .zero
        opacity = 1
    }
}

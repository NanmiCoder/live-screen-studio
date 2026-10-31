import CoreGraphics
import Foundation

public enum SmoothDamp {
    /// Critically damped spring toward `target` (Game Programming Gems 4, 1.10).
    /// Never overshoots, and moves at most `maxSpeed` units per second.
    public static func step(
        current: CGPoint,
        target: CGPoint,
        velocity: inout CGVector,
        smoothTime: Double,
        maxSpeed: CGFloat,
        dt: Double
    ) -> CGPoint {
        guard dt > 0 else { return current }
        let smoothTime = max(0.0001, smoothTime)
        let omega = 2 / smoothTime
        let x = omega * dt
        let decay = CGFloat(1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x))
        let omegaF = CGFloat(omega), dtF = CGFloat(dt)

        var change = CGVector(dx: current.x - target.x, dy: current.y - target.y)
        let maxChange = maxSpeed * CGFloat(smoothTime)
        let changeLength = hypot(change.dx, change.dy)
        if changeLength > maxChange {
            change.dx *= maxChange / changeLength
            change.dy *= maxChange / changeLength
        }
        let clampedTarget = CGPoint(x: current.x - change.dx, y: current.y - change.dy)

        let temp = CGVector(dx: (velocity.dx + omegaF * change.dx) * dtF,
                            dy: (velocity.dy + omegaF * change.dy) * dtF)
        var newVelocity = CGVector(dx: (velocity.dx - omegaF * temp.dx) * decay,
                                   dy: (velocity.dy - omegaF * temp.dy) * decay)
        var output = CGPoint(x: clampedTarget.x + (change.dx + temp.dx) * decay,
                             y: clampedTarget.y + (change.dy + temp.dy) * decay)

        // Stop exactly on the target instead of passing it.
        let toTarget = CGVector(dx: target.x - current.x, dy: target.y - current.y)
        let past = CGVector(dx: output.x - target.x, dy: output.y - target.y)
        if toTarget.dx * past.dx + toTarget.dy * past.dy > 0 {
            output = target
            newVelocity = .zero
        }

        // Hard speed cap so a sudden far target never produces a fast pan.
        let stepVector = CGVector(dx: output.x - current.x, dy: output.y - current.y)
        let stepLength = hypot(stepVector.dx, stepVector.dy)
        let maxStep = maxSpeed * dtF
        if stepLength > maxStep {
            let scale = maxStep / stepLength
            output = CGPoint(x: current.x + stepVector.dx * scale, y: current.y + stepVector.dy * scale)
            newVelocity = CGVector(dx: stepVector.dx * scale / dtF, dy: stepVector.dy * scale / dtF)
        }

        velocity = newVelocity
        return output
    }
}

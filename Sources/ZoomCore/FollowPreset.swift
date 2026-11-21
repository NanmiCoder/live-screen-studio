import CoreGraphics

/// How the zoomed viewport chases the cursor.
public struct FollowPreset: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        /// Maps the cursor continuously across the display so there is zero deadzone and 1:1 hand-eye feel.
        case proportional
        /// Holds the camera still inside a central quiet zone and glides smoothly once the cursor crosses it.
        case safeZone
    }

    public var mode: Mode
    /// Safe-zone margin on each edge, as a fraction of the viewport size (used by `.safeZone`).
    public var margin: CGFloat
    /// Where the cursor ends up from the edge after following (`== margin` avoids staircase ratcheting).
    public var settleMargin: CGFloat
    /// Critically damped spring time constant in seconds.
    public var smoothTime: Double
    /// Maximum pan speed as seen on screen, in points per second.
    public var maxVisualSpeed: CGFloat

    public init(
        mode: Mode = .safeZone,
        margin: CGFloat,
        settleMargin: CGFloat,
        smoothTime: Double,
        maxVisualSpeed: CGFloat
    ) {
        self.mode = mode
        self.margin = margin
        self.settleMargin = settleMargin
        self.smoothTime = smoothTime
        self.maxVisualSpeed = maxVisualSpeed
    }

    /// Apple macOS Accessibility Zoom (`⌥⌘+`) default style: 84% of the viewport stays completely rock-solid still
    /// while moving the cursor inside; pushing past the 8% edge rim glides 1:1 smoothly with zero ratchet jump.
    public static let edge = FollowPreset(mode: .safeZone, margin: 0.08, settleMargin: 0.08, smoothTime: 0.085, maxVisualSpeed: 2000)
    /// Quiet central zone (44% of viewport) with gentle, motion-sickness-free speed for live walkthroughs.
    public static let calm = FollowPreset(mode: .safeZone, margin: 0.28, settleMargin: 0.28, smoothTime: 0.22, maxVisualSpeed: 1500)
    /// Continuous proportional follow (mirrors macOS "Continuously with pointer") with gentle damping and speed cap.
    public static let continuous = FollowPreset(mode: .proportional, margin: 0, settleMargin: 0, smoothTime: 0.24, maxVisualSpeed: 1800)
}

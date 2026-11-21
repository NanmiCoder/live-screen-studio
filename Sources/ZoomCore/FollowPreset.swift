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

    /// Quiet central zone (40% of viewport) with zero staircase teleport jumps.
    public static let calm = FollowPreset(mode: .safeZone, margin: 0.30, settleMargin: 0.30, smoothTime: 0.24, maxVisualSpeed: 2200)
    /// Continuous proportional follow with creamy Screen Studio-like glide.
    public static let standard = FollowPreset(mode: .proportional, margin: 0, settleMargin: 0, smoothTime: 0.15, maxVisualSpeed: 4000)
    /// Continuous proportional follow tuned for tight, immediate 1:1 responsiveness.
    public static let snappy = FollowPreset(mode: .proportional, margin: 0, settleMargin: 0, smoothTime: 0.085, maxVisualSpeed: 6000)
}

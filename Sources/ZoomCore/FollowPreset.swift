import CoreGraphics

/// How the zoomed viewport chases the cursor.
public struct FollowPreset: Equatable, Sendable {
    /// Safe-zone margin on each edge, as a fraction of the viewport size.
    public var margin: CGFloat
    /// Where the cursor ends up (distance from the edge it crossed) after the camera follows.
    public var settleMargin: CGFloat
    /// Time the camera takes to roughly catch up with its target.
    public var smoothTime: Double
    /// Maximum pan speed as seen on screen, in points per second.
    public var maxVisualSpeed: CGFloat

    public init(margin: CGFloat, settleMargin: CGFloat, smoothTime: Double, maxVisualSpeed: CGFloat) {
        self.margin = margin
        self.settleMargin = settleMargin
        self.smoothTime = smoothTime
        self.maxVisualSpeed = maxVisualSpeed
    }

    public static let calm = FollowPreset(margin: 0.25, settleMargin: 0.33, smoothTime: 0.6, maxVisualSpeed: 900)
    public static let standard = FollowPreset(margin: 0.20, settleMargin: 0.28, smoothTime: 0.4, maxVisualSpeed: 1500)
    public static let snappy = FollowPreset(margin: 0.12, settleMargin: 0.18, smoothTime: 0.25, maxVisualSpeed: 2500)
}

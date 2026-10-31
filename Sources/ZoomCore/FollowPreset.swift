import CoreGraphics

/// How the zoomed viewport chases the cursor.
public struct FollowPreset: Equatable, Sendable {
    /// Safe-zone margin on each edge, as a fraction of the viewport size.
    public var margin: CGFloat
    /// Time the camera takes to roughly catch up with its target.
    public var smoothTime: Double
    /// Maximum pan speed as seen on screen, in points per second.
    public var maxVisualSpeed: CGFloat

    public init(margin: CGFloat, smoothTime: Double, maxVisualSpeed: CGFloat) {
        self.margin = margin
        self.smoothTime = smoothTime
        self.maxVisualSpeed = maxVisualSpeed
    }

    public static let calm = FollowPreset(margin: 0.25, smoothTime: 0.6, maxVisualSpeed: 900)
    public static let standard = FollowPreset(margin: 0.20, smoothTime: 0.4, maxVisualSpeed: 1500)
    public static let snappy = FollowPreset(margin: 0.12, smoothTime: 0.25, maxVisualSpeed: 2500)
}

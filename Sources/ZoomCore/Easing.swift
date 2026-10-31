import Foundation

public enum Easing {
    /// Slow start, slow finish; velocity is zero at both ends.
    public static func easeInOutCubic(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

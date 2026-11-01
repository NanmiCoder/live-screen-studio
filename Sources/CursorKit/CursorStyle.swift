import CoreGraphics

/// Pointer looks drawn by LiveZoom. Only the arrow is replaced (and, for `.dot`, the pointing hand);
/// text, resize and other cursors keep their system image so their meaning stays clear.
public enum CursorStyle: String, CaseIterable, Sendable {
    case system
    case classic
    case light
    case ocean
    case sunset
    case mint
    case dot
    case spotlight

    public var title: String {
        switch self {
        case .system: "系统原生"
        case .classic: "经典黑"
        case .light: "经典白"
        case .ocean: "海蓝"
        case .sunset: "日落"
        case .mint: "薄荷"
        case .dot: "圆点"
        case .spotlight: "聚光"
        }
    }

    public var replacesPointingHand: Bool { self == .dot }
}

public enum ClickEffect: String, CaseIterable, Sendable {
    case none
    case ripple
    case halo

    public var title: String {
        switch self {
        case .none: "无"
        case .ripple: "波纹"
        case .halo: "光圈"
        }
    }

    public var duration: Double {
        switch self {
        case .none: 0
        case .ripple: 0.5
        case .halo: 0.45
        }
    }

    /// How a click mark looks `age` seconds after the click, in points at 1× cursor size; nil once it has faded.
    public func appearance(age: Double) -> ClickAppearance? {
        guard self != .none, age >= 0, age < duration else { return nil }
        let t = age / duration
        let eased = CGFloat(1 - pow(1 - t, 3))
        let fade = CGFloat(1 - t)
        switch self {
        case .none:
            return nil
        case .ripple:
            return ClickAppearance(radius: 5 + 23 * eased, lineWidth: 3 - 1.8 * eased, opacity: 0.9 * fade, filled: false)
        case .halo:
            return ClickAppearance(radius: 9 + 13 * eased, lineWidth: 0, opacity: 0.5 * fade, filled: true)
        }
    }
}

public struct ClickAppearance: Equatable, Sendable {
    public var radius: CGFloat
    public var lineWidth: CGFloat
    public var opacity: CGFloat
    public var filled: Bool
}

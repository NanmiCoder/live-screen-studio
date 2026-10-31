import Foundation
import ZoomCore

enum FollowStyle: String, CaseIterable {
    case calm, standard, snappy

    var title: String {
        switch self {
        case .calm: "平稳"
        case .standard: "标准"
        case .snappy: "灵敏"
        }
    }

    var preset: FollowPreset {
        switch self {
        case .calm: .calm
        case .standard: .standard
        case .snappy: .snappy
        }
    }
}

/// Mouse button numbers as reported by CGEvent.
enum TriggerButton: Int, CaseIterable {
    case middle = 2, back = 3, forward = 4

    var title: String {
        switch self {
        case .middle: "中键"
        case .back: "侧键（后退）"
        case .forward: "侧键（前进）"
        }
    }
}

final class Settings {
    static let shared = Settings()
    static let zoomLevels: [Double] = [1.5, 2, 2.5, 3]

    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var defaultZoom: Double {
        get { defaults.double(forKey: "defaultZoom") > 0 ? defaults.double(forKey: "defaultZoom") : 2 }
        set { defaults.set(newValue, forKey: "defaultZoom") }
    }

    var trigger: TriggerButton {
        get { TriggerButton(rawValue: defaults.integer(forKey: "triggerButton")) ?? .middle }
        set { defaults.set(newValue.rawValue, forKey: "triggerButton") }
    }

    var followStyle: FollowStyle {
        get { FollowStyle(rawValue: defaults.string(forKey: "followStyle") ?? "") ?? .calm }
        set { defaults.set(newValue.rawValue, forKey: "followStyle") }
    }
}

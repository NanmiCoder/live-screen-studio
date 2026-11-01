import AppKit
import Combine
import CursorKit
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

enum ClickColor: String, CaseIterable {
    case blue, yellow, red, green, white

    var title: String {
        switch self {
        case .blue: "蓝"
        case .yellow: "黄"
        case .red: "红"
        case .green: "绿"
        case .white: "白"
        }
    }

    var color: NSColor {
        switch self {
        case .blue: NSColor(srgbRed: 0.2, green: 0.55, blue: 1, alpha: 1)
        case .yellow: NSColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1)
        case .red: NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1)
        case .green: NSColor(srgbRed: 0.2, green: 0.85, blue: 0.5, alpha: 1)
        case .white: NSColor(white: 1, alpha: 1)
        }
    }
}

/// User preferences, persisted in UserDefaults and observed by the console UI.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // Zoom
    @Published var enabled: Bool { didSet { save(enabled, "enabled") } }
    @Published var defaultZoom: Double { didSet { save(defaultZoom, "defaultZoom") } }
    @Published var trigger: TriggerButton { didSet { save(trigger.rawValue, "triggerButton") } }
    @Published var followStyle: FollowStyle { didSet { save(followStyle.rawValue, "followStyle") } }
    /// Left-drag draws while zoomed in.
    @Published var drawWhileZoomed: Bool { didSet { save(drawWhileZoomed, "drawWhileZoomed") } }

    // Cursor
    @Published var cursorStyle: CursorStyle { didSet { save(cursorStyle.rawValue, "cursorStyle") } }
    @Published var cursorSize: Double { didSet { save(cursorSize, "cursorSize") } }
    @Published var clickEffect: ClickEffect { didSet { save(clickEffect.rawValue, "clickEffect") } }
    @Published var clickColor: ClickColor { didSet { save(clickColor.rawValue, "clickColor") } }
    @Published var smoothCursor: Bool { didSet { save(smoothCursor, "smoothCursor") } }
    @Published var hideIdleCursor: Bool { didSet { save(hideIdleCursor, "hideIdleCursor") } }
    @Published var idleDelay: Double { didSet { save(idleDelay, "idleDelay") } }
    /// Draw the custom cursor all the time, not only while zoomed.
    @Published var customCursorAlways: Bool { didSet { save(customCursorAlways, "customCursorAlways") } }

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        defaultZoom = d.double(forKey: "defaultZoom") > 0 ? d.double(forKey: "defaultZoom") : 2
        trigger = TriggerButton(rawValue: d.integer(forKey: "triggerButton")) ?? .middle
        followStyle = FollowStyle(rawValue: d.string(forKey: "followStyle") ?? "") ?? .calm
        drawWhileZoomed = d.object(forKey: "drawWhileZoomed") as? Bool ?? true
        cursorStyle = CursorStyle(rawValue: d.string(forKey: "cursorStyle") ?? "") ?? .classic
        cursorSize = d.double(forKey: "cursorSize") > 0 ? d.double(forKey: "cursorSize") : 1.2
        clickEffect = ClickEffect(rawValue: d.string(forKey: "clickEffect") ?? "") ?? .ripple
        clickColor = ClickColor(rawValue: d.string(forKey: "clickColor") ?? "") ?? .blue
        smoothCursor = d.object(forKey: "smoothCursor") as? Bool ?? false
        hideIdleCursor = d.object(forKey: "hideIdleCursor") as? Bool ?? false
        idleDelay = d.double(forKey: "idleDelay") > 0 ? d.double(forKey: "idleDelay") : 3
        customCursorAlways = d.object(forKey: "customCursorAlways") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

import AppKit
import Combine
import CursorKit
import ZoomCore

enum FollowStyle: String, CaseIterable {
    case edge, calm, continuous

    var title: String {
        switch self {
        case .edge: "边缘推屏"
        case .calm: "平稳居中"
        case .continuous: "持续跟随"
        }
    }

    var detail: String {
        switch self {
        case .edge: "类似 macOS 原生 ⌥⌘+：光标在画面内移动时镜头静止，推到边缘才 1:1 丝滑跟进。"
        case .calm: "保留中心静区，越界后以柔和速度平稳跟进，直播讲解最不晕。"
        case .continuous: "对标系统「随指针持续移动」：无死区按比例平缓跟随，且限速防抖。"
        }
    }

    var preset: FollowPreset {
        switch self {
        case .edge: .edge
        case .calm: .calm
        case .continuous: .continuous
        }
    }
}

enum CloseWindowBehavior: String, CaseIterable {
    case keepInMenuBar, quitApp

    var title: String {
        switch self {
        case .keepInMenuBar: "后台运行"
        case .quitApp: "彻底退出"
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

    var shortTitle: String {
        switch self {
        case .middle: "中键"
        case .back: "后退侧键"
        case .forward: "前进侧键"
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

enum InkColor: String, CaseIterable {
    case red, yellow, green, blue, pink, white

    var title: String {
        switch self {
        case .red: "红"
        case .yellow: "黄"
        case .green: "绿"
        case .blue: "蓝"
        case .pink: "粉"
        case .white: "白"
        }
    }

    var color: NSColor {
        switch self {
        case .red: NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow: NSColor(srgbRed: 1, green: 0.82, blue: 0.1, alpha: 1)
        case .green: NSColor(srgbRed: 0.2, green: 0.88, blue: 0.5, alpha: 1)
        case .blue: NSColor(srgbRed: 0.25, green: 0.6, blue: 1, alpha: 1)
        case .pink: NSColor(srgbRed: 1, green: 0.33, blue: 0.72, alpha: 1)
        case .white: NSColor(white: 1, alpha: 1)
        }
    }
}

/// A recorded keyboard shortcut: the key code, the ⌘ ⌥ ⌃ ⇧ flags held with it, and how it reads (e.g. "⌥1").
struct Shortcut: Codable, Equatable {
    /// Default stroke-undo shortcut while zoomed in: `⌘Z` (`kVK_ANSI_Z = 6`).
    static let defaultUndo = Shortcut(keyCode: 6, modifiers: CGEventFlags.maskCommand.rawValue, display: "⌘Z")

    var keyCode: Int64
    var modifiers: UInt64
    var display: String

    var combo: InputTap.KeyCombo { InputTap.KeyCombo(keyCode: keyCode, modifiers: modifiers) }
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

    // Ink: strokes and highlights
    @Published var inkStyle: InkStyle { didSet { save(inkStyle.rawValue, "inkStyle") } }
    @Published var inkColor: InkColor { didSet { save(inkColor.rawValue, "inkColor") } }
    /// On screen, in points.
    @Published var strokeWidth: Double { didSet { save(strokeWidth, "strokeWidth") } }
    /// Highlight shortcuts, none until the user records them.
    @Published private(set) var shortcuts: [HighlightKind: Shortcut] {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
            save((try? JSONEncoder().encode(stored)) ?? Data(), "shortcuts")
        }
    }
    /// Undo-last-stroke shortcut while zoomed in and strokes exist; defaults to `⌘Z`.
    @Published private(set) var undoShortcut: Shortcut? {
        didSet {
            save((try? JSONEncoder().encode(undoShortcut)) ?? Data(), "undoShortcut")
        }
    }

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

    // Window behavior
    @Published var closeWindowBehavior: CloseWindowBehavior { didSet { save(closeWindowBehavior.rawValue, "closeWindowBehavior") } }
    @Published var hasPromptedCloseBehavior: Bool { didSet { save(hasPromptedCloseBehavior, "hasPromptedCloseBehavior") } }

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        defaultZoom = d.double(forKey: "defaultZoom") > 0 ? d.double(forKey: "defaultZoom") : 2
        trigger = TriggerButton(rawValue: d.integer(forKey: "triggerButton")) ?? .middle
        followStyle = FollowStyle(rawValue: d.string(forKey: "followStyle") ?? "") ?? .edge
        drawWhileZoomed = d.object(forKey: "drawWhileZoomed") as? Bool ?? true
        inkStyle = InkStyle(rawValue: d.string(forKey: "inkStyle") ?? "") ?? .marker
        inkColor = InkColor(rawValue: d.string(forKey: "inkColor") ?? "") ?? .red
        strokeWidth = d.double(forKey: "strokeWidth") > 0 ? d.double(forKey: "strokeWidth") : 5
        let stored = d.data(forKey: "shortcuts").flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
        let loadedShortcuts = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            HighlightKind(rawValue: key).map { ($0, value) }
        })
        shortcuts = loadedShortcuts
        if let rawUndo = d.data(forKey: "undoShortcut"),
           let decoded = try? JSONDecoder().decode(Shortcut?.self, from: rawUndo) {
            undoShortcut = decoded
        } else {
            // Fresh install, upgrade from pre-undo versions, or corrupt stored data: default to ⌘Z unless
            // a highlight shortcut already owns that combination.
            let taken = loadedShortcuts.values.contains { $0.combo == Shortcut.defaultUndo.combo }
            undoShortcut = taken ? nil : .defaultUndo
        }
        cursorStyle = CursorStyle(rawValue: d.string(forKey: "cursorStyle") ?? "") ?? .classic
        cursorSize = d.double(forKey: "cursorSize") > 0 ? d.double(forKey: "cursorSize") : 1.2
        clickEffect = ClickEffect(rawValue: d.string(forKey: "clickEffect") ?? "") ?? .ripple
        clickColor = ClickColor(rawValue: d.string(forKey: "clickColor") ?? "") ?? .blue
        smoothCursor = d.object(forKey: "smoothCursor") as? Bool ?? false
        hideIdleCursor = d.object(forKey: "hideIdleCursor") as? Bool ?? false
        idleDelay = d.double(forKey: "idleDelay") > 0 ? d.double(forKey: "idleDelay") : 3
        customCursorAlways = d.object(forKey: "customCursorAlways") as? Bool ?? true
        closeWindowBehavior = CloseWindowBehavior(rawValue: d.string(forKey: "closeWindowBehavior") ?? "") ?? .keepInMenuBar
        hasPromptedCloseBehavior = d.bool(forKey: "hasPromptedCloseBehavior")
    }

    /// Sets or clears one shortcut; a combination can only belong to one action. Returns the displaced action's title, if any.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for kind: HighlightKind) -> String? {
        var displaced: String?
        var updated = shortcuts
        if let shortcut {
            for (other, existing) in updated where other != kind && existing.combo == shortcut.combo {
                updated[other] = nil
                displaced = other.title
            }
            if undoShortcut?.combo == shortcut.combo {
                undoShortcut = nil
                displaced = "画线撤销"
            }
        }
        updated[kind] = shortcut
        shortcuts = updated
        return displaced
    }

    /// Sets or clears the undo-stroke shortcut; clears any conflicting highlight shortcut and returns its title, if any.
    @discardableResult
    func setUndoShortcut(_ shortcut: Shortcut?) -> String? {
        var displaced: String?
        if let shortcut {
            var updated = shortcuts
            var changed = false
            for (kind, existing) in updated where existing.combo == shortcut.combo {
                updated[kind] = nil
                displaced = kind.title
                changed = true
            }
            if changed { shortcuts = updated }
        }
        undoShortcut = shortcut
        return displaced
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

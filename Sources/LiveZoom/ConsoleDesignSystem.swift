import AppKit
import SwiftUI

// MARK: - Studio Design System

struct StudioPalette {
    let scheme: ColorScheme

    var isDark: Bool { scheme == .dark }
    var sidebarBg: Color { isDark ? Color(red: 0.075, green: 0.086, blue: 0.110) : Color(red: 0.945, green: 0.953, blue: 0.969) }
    var canvasBg: Color { isDark ? Color(red: 0.094, green: 0.106, blue: 0.133) : Color(red: 0.969, green: 0.973, blue: 0.980) }
    var cardBg: Color { isDark ? Color(red: 0.125, green: 0.141, blue: 0.176) : Color.white }
    var wellBg: Color { isDark ? Color(red: 0.086, green: 0.098, blue: 0.125) : Color(red: 0.941, green: 0.949, blue: 0.965) }
    var cardBorder: Color { isDark ? Color.white.opacity(0.085) : Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.075) }
    var topRim: Color { isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.9) }
    var divider: Color { isDark ? Color.white.opacity(0.07) : Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.065) }
    var shadow: Color { isDark ? Color.black.opacity(0.28) : Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.055) }

    /// Single calibrated studio cobalt accent (saturation < 80%, zero purple/neon slop).
    var accent: Color { isDark ? Color(red: 0.25, green: 0.54, blue: 0.96) : Color(red: 0.16, green: 0.41, blue: 0.90) }
    var accentSoft: Color { accent.opacity(isDark ? 0.18 : 0.11) }
    var emerald: Color { isDark ? Color(red: 0.16, green: 0.78, blue: 0.55) : Color(red: 0.06, green: 0.62, blue: 0.42) }
    var amber: Color { isDark ? Color(red: 0.96, green: 0.68, blue: 0.22) : Color(red: 0.85, green: 0.49, blue: 0.06) }

    var inkPrimary: Color { isDark ? Color(white: 0.95) : Color(red: 0.07, green: 0.09, blue: 0.15) }
    var inkSecondary: Color { isDark ? Color(white: 0.62) : Color(red: 0.36, green: 0.40, blue: 0.48) }
    var inkMuted: Color { isDark ? Color(white: 0.46) : Color(red: 0.50, green: 0.55, blue: 0.63) }
}

enum StudioSpring {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let tactile = Animation.spring(response: 0.20, dampingFraction: 0.75)
}

struct TactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(StudioSpring.tactile, value: configuration.isPressed)
    }
}

struct StudioCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.cardBg, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [p.topRim, p.cardBorder], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
            .shadow(color: p.shadow, radius: 14, x: 0, y: 6)
    }
}

struct PageHeader: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let subtitle: String

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(p.inkPrimary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(p.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CardHeading: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let icon: String
    var detail: String? = nil

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.accent)
                .frame(width: 24, height: 24)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.inkPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.inkSecondary)
                }
            }
        }
    }
}

/// Sculpted macOS keycap pill (e.g. `⌘Z`, `⌥1`, `Esc`).
struct KeycapBadge: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var accented: Bool = false

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(accented ? p.accent : p.inkPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(accented ? p.accentSoft : p.wellBg, in: shape)
            .overlay(shape.strokeBorder(accented ? p.accent.opacity(0.45) : p.cardBorder, lineWidth: 1))
    }
}

/// Crisp status indicator dot with a soft ambient halo (static, so SwiftUI never ticks the main thread at 120 Hz).
struct BreathingDot: View {
    let color: Color
    var animated: Bool = true

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .fill(color.opacity(0.22))
                    .frame(width: 12, height: 12)
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 12, height: 12)
    }
}

/// Spring-animated segmented control with matched geometry pill.
struct StudioSegmentedPicker<Option: Hashable>: View {
    @Environment(\.colorScheme) private var scheme
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @Namespace private var ns

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let active = selection == option
                Button {
                    withAnimation(StudioSpring.snappy) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(active ? p.inkPrimary : p.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(p.cardBg)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(p.cardBorder, lineWidth: 1)
                                    )
                                    .shadow(color: p.shadow, radius: 4, x: 0, y: 1)
                                    .matchedGeometryEffect(id: "seg-pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(p.wellBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.cardBorder, lineWidth: 1))
    }
}

struct StudioToggleRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(p.inkPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.inkSecondary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct ColorDot: View {
    @Environment(\.colorScheme) private var scheme
    let color: NSColor
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
                .frame(width: 19, height: 19)
                .padding(3)
                .overlay(
                    Circle()
                        .strokeBorder(p.accent, lineWidth: 2)
                        .scaleEffect(selected ? 1.0 : 0.75)
                        .opacity(selected ? 1 : 0)
                )
                .scaleEffect(selected ? 1.06 : 1.0)
                .contentShape(Circle())
        }
        .buttonStyle(TactileButtonStyle())
        .accessibilityLabel(title)
        .help(title)
    }
}

// MARK: - Unified Shortcut Recorder

/// Coordinates all shortcut recorders in the console so at most one local `.keyDown` monitor is ever active
/// and closing or defocusing the console window always cancels recording cleanly.
final class ShortcutRecorderCoordinator: ObservableObject {
    @Published private(set) var activeID: String?
    private var monitor: Any?

    func toggle(id: String, onCapture: @escaping (Shortcut) -> Void) {
        if activeID == id {
            cancel()
            return
        }
        cancel()
        activeID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode != 53 {
                onCapture(Shortcut(event: event))
            }
            self?.cancel()
            return nil
        }
    }

    func cancel() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if activeID != nil {
            activeID = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct StudioShortcutRecorder: View {
    @Environment(\.colorScheme) private var scheme
    let id: String
    let shortcut: Shortcut?
    let placeholder: String
    @ObservedObject var coordinator: ShortcutRecorderCoordinator
    let onChange: (Shortcut?) -> Void

    private var isRecording: Bool { coordinator.activeID == id }

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        HStack(spacing: 5) {
            Button {
                coordinator.toggle(id: id) { captured in
                    onChange(captured)
                }
            } label: {
                HStack(spacing: 5) {
                    if isRecording {
                        Circle()
                            .fill(p.accent)
                            .frame(width: 6, height: 6)
                        Text("按下快捷键…")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(p.accent)
                    } else if let shortcut {
                        Text(shortcut.display)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .foregroundStyle(p.inkPrimary)
                    } else {
                        Text(placeholder)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(p.inkMuted)
                    }
                }
                .frame(minWidth: 76)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    isRecording ? p.accentSoft : p.cardBg,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isRecording ? p.accent : p.cardBorder, lineWidth: isRecording ? 1.5 : 1)
                )
            }
            .buttonStyle(TactileButtonStyle())

            if shortcut != nil, !isRecording {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(p.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除快捷键")
                .help("清除快捷键")
            }
        }
    }
}

extension Shortcut {
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
        self.init(keyCode: Int64(event.keyCode), modifiers: UInt64(flags.rawValue),
                  display: symbols + Self.keyName(event))
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = specialKeys[event.keyCode] { return name }
        // The key's own character, as if no modifier were held (⌥1 reads "1", not "¡").
        let character = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        return character.isEmpty ? "键\(event.keyCode)" : character.uppercased()
    }
}

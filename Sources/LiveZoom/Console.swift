import AppKit
import CursorKit
import ServiceManagement
import SwiftUI

/// Live state shown in the console's General page.
final class AppStatus: ObservableObject {
    @Published var accessibility = false
    @Published var screenRecording = false
    @Published var inputTapRunning = false
    @Published var launchAtLogin = false

    var isInputTapRunning: () -> Bool = { false }
    private var refreshing = false

    /// The permission and login-item queries take 10–25 ms, so they run off the main thread (which draws the
    /// cursor and the zoom every frame); published values change only when they actually changed.
    func refresh() {
        let tapRunning = isInputTapRunning()
        if inputTapRunning != tapRunning { inputTapRunning = tapRunning }
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let accessibility = Permissions.accessibility
            let screenRecording = Permissions.screenRecording
            let launchAtLogin = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshing = false
                if self.accessibility != accessibility { self.accessibility = accessibility }
                if self.screenRecording != screenRecording { self.screenRecording = screenRecording }
                if self.launchAtLogin != launchAtLogin { self.launchAtLogin = launchAtLogin }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("launch at login: \(error.localizedDescription)")
        }
        refresh()
    }
}

final class ConsoleWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Refreshes the permission status only while the console is open and visible.
    private var statusTimer: Timer?
    private weak var status: AppStatus?

    var windowNumber: Int? { window?.windowNumber }

    func show(settings: AppSettings, status: AppStatus, section: String? = nil) {
        status.refresh()
        if window == nil {
            let initial = section.flatMap(ConsoleSection.init(rawValue:)) ?? .zoom
            let controller = NSHostingController(rootView: ConsoleView(settings: settings, status: status, initialSection: initial))
            let window = NSWindow(contentViewController: controller)
            window.title = "LiveZoom 控制台"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 600))
            window.center()
            window.delegate = self
            self.window = window
        }
        self.status = status
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if statusTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let window = self.window, window.occlusionState.contains(.visible) else { return }
                self.status?.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            statusTimer = timer
        }
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}

// MARK: - Views

enum ConsoleSection: String, CaseIterable, Identifiable {
    case zoom, cursor, general

    var id: Self { self }

    var title: String {
        switch self {
        case .zoom: "放大"
        case .cursor: "光标"
        case .general: "通用"
        }
    }

    var icon: String {
        switch self {
        case .zoom: "plus.magnifyingglass"
        case .cursor: "cursorarrow.rays"
        case .general: "gearshape"
        }
    }
}

struct ConsoleView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: AppStatus
    @State private var section: ConsoleSection?

    init(settings: AppSettings, status: AppStatus, initialSection: ConsoleSection = .zoom) {
        self.settings = settings
        self.status = status
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            List(ConsoleSection.allCases, selection: $section) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch section ?? .zoom {
            case .zoom: ZoomPage(settings: settings)
            case .cursor: CursorPage(settings: settings)
            case .general: GeneralPage(settings: settings, status: status)
            }
        }
        .frame(minWidth: 700, minHeight: 520)
    }
}

private struct ZoomPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("默认倍数") {
                    HStack {
                        Slider(value: $settings.defaultZoom, in: 1.25...4, step: 0.25)
                        Text(String(format: "%.2f×", settings.defaultZoom))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Picker("触发键", selection: $settings.trigger) {
                    ForEach(TriggerButton.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("跟随速度", selection: $settings.followStyle) {
                    ForEach(FollowStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("放大")
            } footer: {
                Text("鼠标在画面中间移动时镜头不动，靠近边缘才平滑跟过去；「平稳」最不容易晕。")
            }

            Section {
                Toggle("放大时左键拖动画线", isOn: $settings.drawWhileZoomed)
                if settings.drawWhileZoomed {
                    shortcut("左键拖动", "画线（按住 ⇧ 画直线）")
                    shortcut("⌘ + 左键拖动", "正常拖拽、选文字")
                    shortcut("右键", "撤销一笔")
                }
                shortcut("Esc", "清除全部笔迹和高亮")
                LazyVGrid(columns: inkColumns, spacing: 10) {
                    ForEach(InkStyle.allCases, id: \.self) { style in
                        InkTile(style: style, color: settings.inkColor.color, selected: settings.inkStyle == style)
                            .onTapGesture { settings.inkStyle = style }
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("颜色") {
                    HStack(spacing: 10) {
                        ForEach(InkColor.allCases, id: \.self) { option in
                            ColorDot(color: option.color, title: option.title, selected: settings.inkColor == option)
                                .onTapGesture { settings.inkColor = option }
                        }
                    }
                }
                LabeledContent("粗细") {
                    HStack {
                        Slider(value: $settings.strokeWidth, in: 2...12, step: 1)
                        Text("\(Int(settings.strokeWidth)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            } header: {
                Text("画笔")
            } footer: {
                Text("放大时单击、双击照常生效；笔迹跟着画面移动，缩回时自动清除。")
            }

            Section {
                ForEach(HighlightKind.allCases, id: \.self) { kind in
                    LabeledContent(kind.title) { ShortcutRecorder(kind: kind, settings: settings) }
                }
            } header: {
                Text("高亮快捷键")
            } footer: {
                Text("放大后把光标停在一行文字上按快捷键，自动识别这一行并加上框、划线、荧光笔或聚光灯；聚光灯再按一次关闭。只在放大时生效，建议带上 ⌥ 或 ⌃，以免占用打字的键。")
            }

            Section("操作") {
                shortcut("单击\(settings.trigger.title)", "放大 / 缩回")
                shortcut("按住\(settings.trigger.title)并滚动滚轮", "调整倍数")
                shortcut("⌥ + \(settings.trigger.title)", "原来的点击")
                shortcut("放大时", "光标留在这块屏幕里，单击\(settings.trigger.title)才缩回")
            }
        }
        .formStyle(.grouped)
    }

    private let inkColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    private func shortcut(_ action: String, _ result: String) -> some View {
        LabeledContent(action) { Text(result).foregroundStyle(.secondary) }
    }
}

private struct ColorDot: View {
    let color: NSColor
    let title: String
    let selected: Bool

    var body: some View {
        Circle()
            .fill(Color(nsColor: color))
            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
            .frame(width: 20, height: 20)
            .padding(3)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
            .help(title)
    }
}

/// A wavy sample line in one stroke style, drawn like the real thing on a dark background.
private struct InkTile: View {
    let style: InkStyle
    let color: NSColor
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            // Only the dashes move, so only that tile animates.
            TimelineView(.animation(minimumInterval: nil, paused: style != .dashed)) { timeline in
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.12, green: 0.13, blue: 0.16)))
                    draw(in: &ctx, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
            )
            Text(style.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time: Double) {
        let points = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40
            return CGPoint(x: 14 + t * (size.width - 28), y: size.height / 2 + sin(t * .pi * 2) * size.height * 0.2)
        }
        var path = Path()
        path.addLines(points)
        let c = Color(nsColor: color)
        let w: CGFloat = 3
        func line(_ color: Color, _ width: CGFloat, cap: CGLineCap = .round, dash: [CGFloat] = [], phase: CGFloat = 0) {
            ctx.stroke(path, with: .color(color),
                       style: SwiftUI.StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round, dash: dash, dashPhase: phase))
        }
        switch style {
        case .marker:
            line(c, w)
        case .neon:
            line(c.opacity(0.14), w * 3.6)
            line(c.opacity(0.32), w * 2)
            line(c, w)
            line(Color(nsColor: color.blended(withFraction: 0.7, of: .white) ?? .white), w * 0.38)
        case .highlighter:
            line(c.opacity(0.38), w * 3.6, cap: .butt)
        case .arrow:
            line(c, w)
            if let (a, b) = ArrowHead.barbs(for: points, length: 12), let tip = points.last {
                var head = Path()
                head.addLines([a, tip, b])
                ctx.stroke(head, with: .color(c), style: SwiftUI.StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
        case .dashed:
            // Same pace as on screen: one dash and gap every 0.6 s.
            let cycle = w * 4.6
            line(c, w, dash: [w * 2.4, w * 2.2], phase: -CGFloat(time.truncatingRemainder(dividingBy: 0.6) / 0.6) * cycle)
        }
    }
}

/// Records a shortcut: click, then press the keys. Esc cancels (it is kept for clearing the marks).
private struct ShortcutRecorder: View {
    let kind: HighlightKind
    @ObservedObject var settings: AppSettings
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                monitor == nil ? start() : stop()
            } label: {
                Text(monitor != nil ? "按下快捷键…" : settings.shortcuts[kind]?.display ?? "点击录制")
                    .frame(minWidth: 96)
            }
            if settings.shortcuts[kind] != nil, monitor == nil {
                Button {
                    settings.setShortcut(nil, for: kind)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("清除")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != 53 { settings.setShortcut(Shortcut(event: event), for: kind) }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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

private struct CursorPage: View {
    @ObservedObject var settings: AppSettings
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        Form {
            Section {
                CursorPreview(style: settings.cursorStyle, size: settings.cursorSize, effect: settings.clickEffect,
                              color: settings.clickColor.color)
                    .frame(height: 150)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("在任意位置点击，就能看到实际效果。")
            }

            Section("样式") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(CursorStyle.allCases, id: \.self) { style in
                        StyleTile(style: style, selected: settings.cursorStyle == style)
                            .onTapGesture { settings.cursorStyle = style }
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("大小") {
                    HStack {
                        Slider(value: $settings.cursorSize, in: 0.75...2.5)
                        Text(String(format: "%.2f×", settings.cursorSize))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            Section("点击效果") {
                Picker("效果", selection: $settings.clickEffect) {
                    ForEach(ClickEffect.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("颜色") {
                    HStack(spacing: 10) {
                        ForEach(ClickColor.allCases, id: \.self) { option in
                            Circle()
                                .fill(Color(nsColor: option.color))
                                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                                .frame(width: 20, height: 20)
                                .padding(3)
                                .overlay(
                                    Circle().stroke(Color.accentColor, lineWidth: 2)
                                        .opacity(settings.clickColor == option ? 1 : 0)
                                )
                                .help(option.title)
                                .onTapGesture { settings.clickColor = option }
                        }
                    }
                }
                .disabled(settings.clickEffect == .none)
            }

            Section("动效") {
                Toggle(isOn: $settings.smoothCursor) {
                    Text("移动平滑")
                    Text("光标轨迹更顺滑，但会比手稍慢一点").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("静止后自动隐藏", isOn: $settings.hideIdleCursor)
                if settings.hideIdleCursor {
                    LabeledContent("等待时间") {
                        HStack {
                            Slider(value: $settings.idleDelay, in: 1...10, step: 1)
                            Text("\(Int(settings.idleDelay)) 秒").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }

            Section {
                Toggle("平时也使用自定义光标", isOn: $settings.customCursorAlways)
            } footer: {
                Text("关闭后，自定义光标和点击效果只在放大时出现，平时用系统原生光标。")
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: AppStatus

    var body: some View {
        Form {
            Section {
                Toggle("启用 LiveZoom", isOn: $settings.enabled)
                Toggle("登录时自动启动", isOn: Binding(get: { status.launchAtLogin }, set: { status.setLaunchAtLogin($0) }))
            }

            Section {
                permissionRow("辅助功能", "用来识别触发键和点击", granted: status.accessibility) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                permissionRow("屏幕录制", "用来采集要放大的画面", granted: status.screenRecording) {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                }
            } header: {
                Text("权限")
            } footer: {
                Text("授予屏幕录制权限后，需要退出并重新打开 LiveZoom 才会生效。")
            }

            Section("关于") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ title: String, _ detail: String, granted: Bool, open: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("去授权…", action: open)
            }
        } label: {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StyleTile: View {
    let style: CursorStyle
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
                if let art = CursorThumbnail.art(for: style, scale: 3) {
                    // Shown at 1.3× its real size.
                    Image(decorative: art.image, scale: CGFloat(art.image.width) / art.size.width / 1.3)
                }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
            )
            Text(style.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }
}

/// The selected style at its real size on light and dark backgrounds, with a looping click effect.
private struct CursorPreview: View {
    let style: CursorStyle
    let size: Double
    let effect: ClickEffect
    let color: NSColor

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, canvasSize in
                let half = canvasSize.width / 2
                ctx.fill(Path(CGRect(x: 0, y: 0, width: half, height: canvasSize.height)),
                         with: .color(Color(white: 0.95)))
                ctx.fill(Path(CGRect(x: half, y: 0, width: half, height: canvasSize.height)),
                         with: .color(Color(red: 0.13, green: 0.14, blue: 0.17)))
                let age = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)
                let pixelScale = 2 * size
                guard let art = CursorThumbnail.art(for: style, scale: pixelScale) else { return }
                for x in [half / 2, half * 1.5] {
                    let tip = CGPoint(x: x, y: canvasSize.height / 2)
                    if let look = effect.appearance(age: age) {
                        let r = look.radius * size
                        let rect = CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)
                        let shading = GraphicsContext.Shading.color(Color(nsColor: color).opacity(look.opacity))
                        if look.filled {
                            ctx.fill(Path(ellipseIn: rect), with: shading)
                        } else {
                            ctx.stroke(Path(ellipseIn: rect), with: shading, lineWidth: look.lineWidth * size)
                        }
                    }
                    let frame = CGRect(x: tip.x - art.hotSpot.x * size, y: tip.y - art.hotSpot.y * size,
                                       width: art.size.width * size, height: art.size.height * size)
                    ctx.draw(Image(decorative: art.image, scale: 1), in: frame)
                }
            }
        }
    }
}

enum CursorThumbnail {
    private static var cache: [String: CursorImage] = [:]

    /// Custom styles from CursorArt; `.system` shows the standard arrow. The scale is rounded so dragging the
    /// size slider reuses a handful of images instead of rendering (and keeping) one per slider value.
    static func art(for style: CursorStyle, scale: Double) -> CursorImage? {
        let scale = max((scale * 4).rounded() / 4, 0.25)
        let key = "\(style.rawValue)@\(scale)"
        if let cached = cache[key] { return cached }
        if cache.count > 64 { cache.removeAll() }
        let art: CursorImage?
        if style == .system {
            let cursor = NSCursor.arrow
            let rep = cursor.image.representations.max { $0.pixelsWide < $1.pixelsWide }
            var rect = CGRect(x: 0, y: 0, width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
            art = rep?.cgImage(forProposedRect: &rect, context: nil, hints: nil).map {
                CursorImage(image: $0, size: cursor.image.size, hotSpot: cursor.hotSpot)
            }
        } else {
            art = CursorArt.render(style, scale: scale)
        }
        cache[key] = art
        return art
    }
}

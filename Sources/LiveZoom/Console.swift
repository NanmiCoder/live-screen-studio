import AppKit
import ServiceManagement
import SwiftUI

/// Live state shown in the console's General page and sidebar status pill.
final class AppStatus: ObservableObject {
    @Published var accessibility = false
    @Published var screenRecording = false
    @Published var inputTapRunning = false
    @Published var launchAtLogin = false

    var isInputTapRunning: () -> Bool = { false }
    private var refreshing = false

    var permissionsGranted: Bool { accessibility && screenRecording }
    /// Matches menu bar readiness: input tap running plus screen recording granted.
    var isReady: Bool { inputTapRunning && screenRecording }

    struct StatusSummary {
        let pillText: String
        let bannerTitle: String
        let bannerDetail: String
        let color: Color
        let breathes: Bool
        let needsPermissions: Bool
    }

    func summary(enabled: Bool, triggerTitle: String, palette p: StudioPalette) -> StatusSummary {
        if !permissionsGranted {
            return StatusSummary(
                pillText: "需要完成系统授权",
                bannerTitle: "还需要完成系统权限授权",
                bannerDetail: "授权下方两项权限后即可开始使用 LiveZoom。",
                color: p.amber,
                breathes: true,
                needsPermissions: true
            )
        }
        if !enabled {
            return StatusSummary(
                pillText: "已暂停 · 点击下方开启",
                bannerTitle: "LiveZoom 当前已暂停",
                bannerDetail: "重新启用后，单击\(triggerTitle)即可放大光标区域。",
                color: p.inkMuted,
                breathes: false,
                needsPermissions: false
            )
        }
        if !inputTapRunning {
            return StatusSummary(
                pillText: "正在连接输入监听…",
                bannerTitle: "正在等待输入监听就绪",
                bannerDetail: "若长时间未就绪，请尝试退出并重新打开 LiveZoom。",
                color: p.amber,
                breathes: true,
                needsPermissions: false
            )
        }
        return StatusSummary(
            pillText: "就绪 · 可随时放大",
            bannerTitle: "所有系统权限已就绪",
            bannerDetail: "单击\(triggerTitle)即可随时放大当前光标区域。",
            color: p.emerald,
            breathes: true,
            needsPermissions: false
        )
    }

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
    private var statusTickCount = 0
    private weak var status: AppStatus?
    private weak var settings: AppSettings?
    private let recorderCoordinator = ShortcutRecorderCoordinator()
    private let visibility = ConsoleVisibility()

    var windowNumber: Int? { window?.windowNumber }

    func show(settings: AppSettings, status: AppStatus, section: String? = nil) {
        self.settings = settings
        self.status = status
        status.refresh()
        // Pre-render custom cursor thumbnails off the main thread before the user clicks "光标与动效".
        Task { @MainActor in
            CursorThumbnail.warmUpIfNeeded(previewStyle: settings.cursorStyle, previewSize: settings.cursorSize)
        }
        if window == nil {
            let initial = section.flatMap(ConsoleSection.init(rawValue:)) ?? .zoom
            let controller = NSHostingController(
                rootView: ConsoleView(
                    settings: settings,
                    status: status,
                    recorder: recorderCoordinator,
                    visibility: visibility,
                    initialSection: initial
                )
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "LiveZoom 控制台"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 660))
            window.minSize = NSSize(width: 840, height: 580)
            window.center()
            window.delegate = self
            self.window = window
        }
        visibility.isVisible = true
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if statusTimer == nil {
            statusTickCount = 0
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let window = self.window, window.occlusionState.contains(.visible),
                      let status = self.status else { return }
                self.statusTickCount += 1
                // Poll every 1s while awaiting permissions; once ready, back off to every 3s.
                if status.isReady, self.statusTickCount % 3 != 0 { return }
                status.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            statusTimer = timer
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        visibility.isVisible = window.occlusionState.contains(.visible)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let settings else { return true }
        if settings.hasPromptedCloseBehavior {
            if settings.closeWindowBehavior == .quitApp {
                NSApp.terminate(nil)
                return false
            }
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "关闭控制台窗口"
        alert.informativeText = "LiveZoom 默认会在顶部菜单栏保持运行，以便随时中键放大画面。你也可以选择关闭窗口时直接退出应用，或随时按 ⌘Q 退出。"
        alert.addButton(withTitle: "在菜单栏后台运行")
        alert.addButton(withTitle: "彻底退出")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "记住我的选择（可在「通用与权限」中修改）"
        alert.suppressionButton?.state = .on
        let response = alert.runModal()
        let shouldQuit = response == .alertSecondButtonReturn
        if alert.suppressionButton?.state == .on {
            settings.closeWindowBehavior = shouldQuit ? .quitApp : .keepInMenuBar
            settings.hasPromptedCloseBehavior = true
        }
        if shouldQuit {
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        recorderCoordinator.cancel()
        visibility.isVisible = false
        // Tear down the SwiftUI view hierarchy when closed so it consumes zero main-thread DisplayLink work.
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        recorderCoordinator.cancel()
    }
}

final class ConsoleVisibility: ObservableObject {
    @Published var isVisible = false
}

// MARK: - Navigation & Shell

enum ConsoleSection: String, CaseIterable, Identifiable {
    case zoom, cursor, general

    var id: Self { self }

    var title: String {
        switch self {
        case .zoom: "放大与标注"
        case .cursor: "光标与动效"
        case .general: "通用与权限"
        }
    }

    var icon: String {
        switch self {
        case .zoom: "plus.magnifyingglass"
        case .cursor: "cursorarrow.rays"
        case .general: "slider.horizontal.3"
        }
    }
}

struct ConsoleView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: AppStatus
    /// Passed through without subscribing at the top level, so recording a shortcut never redraws the sidebar.
    let recorder: ShortcutRecorderCoordinator
    @ObservedObject var visibility: ConsoleVisibility
    @State private var section: ConsoleSection
    @Namespace private var navNamespace

    init(
        settings: AppSettings,
        status: AppStatus,
        recorder: ShortcutRecorderCoordinator,
        visibility: ConsoleVisibility,
        initialSection: ConsoleSection = .zoom
    ) {
        self.settings = settings
        self.status = status
        self.recorder = recorder
        self.visibility = visibility
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        HStack(spacing: 0) {
            sidebar(palette: p)
                .frame(width: 218)
                .background(p.sidebarBg)
                .ignoresSafeArea(.container, edges: .top)

            Rectangle()
                .fill(p.divider)
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .top)

            // Give ScrollView an opaque canvas background and reset scroll to top cleanly when switching tabs.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 0).id("console-scroll-top")
                        switch section {
                        case .zoom: ZoomPage(settings: settings, recorder: recorder, isVisible: visibility.isVisible)
                        case .cursor: CursorPage(settings: settings, isVisible: visibility.isVisible)
                        case .general: GeneralPage(settings: settings, status: status)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 780, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(p.canvasBg.ignoresSafeArea(.container, edges: .top))
                .onChange(of: section) { _, _ in
                    recorder.cancel()
                    proxy.scrollTo("console-scroll-top", anchor: .top)
                }
            }
        }
        .tint(p.accent)
        .onDisappear { recorder.cancel() }
    }

    private func sidebar(palette p: StudioPalette) -> some View {
        let summary = status.summary(enabled: settings.enabled, triggerTitle: settings.trigger.shortTitle, palette: p)
        return VStack(alignment: .leading, spacing: 0) {
            // Brand header below macOS traffic lights.
            HStack(spacing: 10) {
                AppBrandBadge()
                VStack(alignment: .leading, spacing: 1) {
                    Text("LiveZoom")
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(p.inkPrimary)
                    Text("v\(AppBrandBadge.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.inkMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 42)
            .padding(.bottom, 16)

            // Live status pill (real button so clicks work reliably and support keyboard/VoiceOver).
            Button {
                if summary.needsPermissions {
                    section = .general
                }
            } label: {
                HStack(spacing: 8) {
                    BreathingDot(color: summary.color, animated: summary.breathes)
                    Text(summary.pillText)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(summary.color)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(summary.color.opacity(p.isDark ? 0.14 : 0.10),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(summary.color.opacity(0.22), lineWidth: 1)
                )
            }
            .buttonStyle(TactileButtonStyle())
            .disabled(!summary.needsPermissions)
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            // Navigation items: animate only the pill highlight locally so detail pages swap instantaneously with
            // zero 600 ms dual-page crossfade overhead.
            VStack(spacing: 4) {
                ForEach(ConsoleSection.allCases) { item in
                    let active = section == item
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? p.accent : p.inkSecondary)
                                .frame(width: 20)
                            Text(item.title)
                                .font(.system(size: 13, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? p.inkPrimary : p.inkSecondary)
                            Spacer(minLength: 0)
                            if item == .general, summary.needsPermissions {
                                Circle()
                                    .fill(p.amber)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(p.cardBg)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(p.cardBorder, lineWidth: 1)
                                    )
                                    .matchedGeometryEffect(id: "nav-pill", in: navNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TactileButtonStyle())
                }
            }
            .animation(StudioSpring.snappy, value: section)
            .padding(.horizontal, 12)

            Spacer(minLength: 16)

            // Bottom master enable dock + always-accessible Quit button (essential on Notch MacBooks).
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(p.divider).frame(height: 1)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.enabled ? "已启用" : "已暂停")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(p.inkPrimary)
                        Text("单击\(settings.trigger.shortTitle)放大")
                            .font(.system(size: 11))
                            .foregroundStyle(p.inkMuted)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)

                SidebarQuitButton(palette: p)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }
}

private struct SidebarQuitButton: View {
    let palette: StudioPalette
    @State private var hovering = false

    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("退出 LiveZoom")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text("⌘Q")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(hovering ? Color.red.opacity(0.85) : palette.inkMuted)
            }
            .foregroundStyle(hovering ? Color.red : palette.inkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                hovering ? Color.red.opacity(palette.isDark ? 0.14 : 0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("彻底退出 LiveZoom 后台进程 (⌘Q)")
    }
}

private struct AppBrandBadge: View {
    static let version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"

    /// Pre-scaled 34pt Retina bitmap cached once so SwiftUI never resizes the 1024px app icon on redraws.
    private static let cachedIcon: NSImage? = {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app",
              let icon = NSApp.applicationIconImage else { return nil }
        let target = NSSize(width: 34, height: 34)
        let rendered = NSImage(size: target)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .sourceOver, fraction: 1)
        rendered.unlockFocus()
        return rendered
    }()

    var body: some View {
        if let icon = Self.cachedIcon {
            Image(nsImage: icon)
                .frame(width: 34, height: 34)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.24), Color(red: 0.14, green: 0.28, blue: 0.56)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
        }
    }
}

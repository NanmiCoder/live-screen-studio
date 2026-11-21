import AppKit
import CursorKit
import SwiftUI

// MARK: - Page 1: Zoom & Ink

struct ZoomPage: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: ShortcutRecorderCoordinator
    let isVisible: Bool
    @State private var conflictNotice: String?
    @State private var noticeTask: Task<Void, Never>?

    private let inkColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)
    private let highlightColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)

    var body: some View {
        let p = StudioPalette(scheme: scheme)

        PageHeader(title: "放大与标注", subtitle: "调节实时缩放镜头、画笔笔触与放大期间的快捷操作")

        // Bento Row 1: Asymmetric split (Lens Controls | Dynamic Cheat Sheet)
        HStack(alignment: .top, spacing: 14) {
            StudioCard {
                VStack(alignment: .leading, spacing: 16) {
                    CardHeading(title: "镜头控制", icon: "scope")

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("默认放大倍数")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(p.inkSecondary)
                            Spacer()
                            Text(String(format: "%.2f×", settings.defaultZoom))
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(p.inkPrimary)
                        }
                        Slider(value: $settings.defaultZoom, in: 1.25...4, step: 0.25)
                    }

                    Rectangle().fill(p.divider).frame(height: 1)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("触发键")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(p.inkSecondary)
                        StudioSegmentedPicker(options: TriggerButton.allCases, selection: $settings.trigger) { $0.shortTitle }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("镜头跟随")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(p.inkSecondary)
                        StudioSegmentedPicker(options: FollowStyle.allCases, selection: $settings.followStyle) { $0.title }
                        Text("「灵敏」「标准」随光标连续丝滑跟随；「平稳」保留中心静区，越界后平滑跟进。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.inkMuted)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StudioCard {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeading(title: "操控速查", icon: "keyboard")

                    VStack(spacing: 11) {
                        cheatRow("单击\(settings.trigger.shortTitle)", "放大 / 缩回", palette: p)
                        cheatRow("按住 + 滚轮", "调节本次倍数", palette: p)
                        if settings.drawWhileZoomed {
                            cheatRow("左键拖动", "画线（⇧ 直线）", palette: p)
                            cheatRow("⌘ + 拖动", "正常拖拽 / 选字", palette: p)
                            cheatRow(settings.undoShortcut.map { "\($0.display) / 右键" } ?? "右键", "撤销上一笔", palette: p)
                        } else if let undo = settings.undoShortcut {
                            cheatRow(undo.display, "撤销上一个高亮", palette: p)
                        }
                        cheatRow("Esc", "清除全部标注", palette: p)
                        cheatRow("⌥ + \(settings.trigger.shortTitle)", "透传原生点击", palette: p)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 268)
            .frame(maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)

        // Bento Row 2: Live Ink Styles & Undo Shortcut
        StudioCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    CardHeading(title: "实时画笔与撤销", icon: "scribble.variable", detail: "笔触、颜色与粗细同时作用于手绘画线与文字高亮")
                    Spacer()
                    HStack(spacing: 8) {
                        Text("左键拖动画线")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(p.inkSecondary)
                        Toggle("", isOn: $settings.drawWhileZoomed.animation(StudioSpring.snappy))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                LazyVGrid(columns: inkColumns, spacing: 10) {
                    ForEach(InkStyle.allCases, id: \.self) { style in
                        InkTile(
                            style: style,
                            color: settings.inkColor.color,
                            selected: settings.inkStyle == style,
                            animate: isVisible && style == .dashed
                        ) {
                            withAnimation(StudioSpring.snappy) { settings.inkStyle = style }
                        }
                    }
                }

                Rectangle().fill(p.divider).frame(height: 1)

                // Spacious color & width strip (never squeezed even at minSize)
                HStack(spacing: 24) {
                    HStack(spacing: 12) {
                        Text("颜色")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(p.inkSecondary)
                        HStack(spacing: 8) {
                            ForEach(InkColor.allCases, id: \.self) { option in
                                ColorDot(color: option.color, title: option.title, selected: settings.inkColor == option) {
                                    withAnimation(StudioSpring.tactile) { settings.inkColor = option }
                                }
                            }
                        }
                    }

                    Rectangle().fill(p.divider).frame(width: 1, height: 22)

                    HStack(spacing: 10) {
                        Text("粗细")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(p.inkSecondary)
                        Slider(value: $settings.strokeWidth, in: 2...12, step: 1)
                        Circle()
                            .fill(Color(nsColor: settings.inkColor.color))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .frame(width: settings.strokeWidth, height: settings.strokeWidth)
                            .frame(width: 14, height: 14)
                        Text("\(Int(settings.strokeWidth)) pt")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(p.inkPrimary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                Rectangle().fill(p.divider).frame(height: 1)

                // Dedicated full-width Undo Stroke Shortcut row
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("画线撤销快捷键")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.inkPrimary)
                        Text("有笔迹或高亮时撤销上一笔，无标注时自动透传给当前应用。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.inkSecondary)
                    }

                    Spacer(minLength: 12)

                    if settings.undoShortcut?.combo != Shortcut.defaultUndo.combo {
                        Button("重置 ⌘Z") {
                            let displaced = settings.setUndoShortcut(.defaultUndo)
                            showConflictIfNeeded(displaced, shortcut: .defaultUndo)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(p.accent)
                    }

                    StudioShortcutRecorder(
                        id: "undo-stroke",
                        shortcut: settings.undoShortcut,
                        placeholder: "点击录制",
                        coordinator: recorder
                    ) { captured in
                        let displaced = settings.setUndoShortcut(captured)
                        if let captured { showConflictIfNeeded(displaced, shortcut: captured) }
                    }
                }
            }
        }

        // Bento Row 3: Smart Text Highlight Shortcuts (2x2 Grid)
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    CardHeading(
                        title: "智能文字高亮快捷键",
                        icon: "text.viewfinder",
                        detail: "放大后悬停在文字行上按快捷键自动识别标注，建议配合 ⌥ 或 ⌃ 避免冲突"
                    )
                    Spacer(minLength: 8)
                    if let conflictNotice {
                        Text(conflictNotice)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.amber)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(p.amber.opacity(p.isDark ? 0.16 : 0.11), in: Capsule())
                            .transition(.opacity)
                    }
                }

                LazyVGrid(columns: highlightColumns, spacing: 10) {
                    ForEach(HighlightKind.allCases, id: \.self) { kind in
                        HStack(spacing: 8) {
                            Image(systemName: kind.symbolName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(p.inkSecondary)
                                .frame(width: 20)
                            Text(kind.shortTitle)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(p.inkPrimary)
                            Spacer(minLength: 6)
                            StudioShortcutRecorder(
                                id: "highlight-\(kind.rawValue)",
                                shortcut: settings.shortcuts[kind],
                                placeholder: "点击录制",
                                coordinator: recorder
                            ) { captured in
                                let displaced = settings.setShortcut(captured, for: kind)
                                if let captured { showConflictIfNeeded(displaced, shortcut: captured) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(p.wellBg, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(p.cardBorder, lineWidth: 1)
                        )
                    }
                }
            }
        }
        .onDisappear { noticeTask?.cancel() }
    }

    private func cheatRow(_ keys: String, _ desc: String, palette p: StudioPalette) -> some View {
        HStack(spacing: 8) {
            KeycapBadge(text: keys)
            Spacer(minLength: 6)
            Text(desc)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(p.inkSecondary)
        }
    }

    private func showConflictIfNeeded(_ displaced: String?, shortcut: Shortcut) {
        guard let displaced else { return }
        noticeTask?.cancel()
        withAnimation(StudioSpring.snappy) {
            conflictNotice = "已从「\(displaced)」移至 \(shortcut.display)"
        }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(StudioSpring.snappy) { conflictNotice = nil }
            }
        }
    }
}

private extension HighlightKind {
    var symbolName: String {
        switch self {
        case .box: "rectangle.dashed"
        case .underline: "underline"
        case .fill: "highlighter"
        case .spotlight: "flashlight.on.fill"
        }
    }

    var shortTitle: String {
        switch self {
        case .box: "框住这一行"
        case .underline: "下划线标注"
        case .fill: "荧光笔涂亮"
        case .spotlight: "聚光灯"
        }
    }
}

// MARK: - Page 2: Cursor & Motion

struct CursorPage: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var settings: AppSettings
    let isVisible: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        let p = StudioPalette(scheme: scheme)

        PageHeader(title: "光标与动效", subtitle: "定制指针外观、点击反馈与移动平滑体验")

        // Live preview stage card
        StudioCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    CursorPreview(style: settings.cursorStyle, size: settings.cursorSize, effect: settings.clickEffect,
                                  color: settings.clickColor.color, animate: isVisible)
                        .frame(height: 158)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(p.cardBorder, lineWidth: 1)
                        )

                    VStack {
                        HStack {
                            previewPill("浅色画面", dark: false)
                            Spacer()
                            previewPill(String(format: "实时预览 · %.2f×", settings.cursorSize), dark: true)
                        }
                        .padding(10)
                        Spacer()
                    }
                }

                HStack {
                    Text("在屏幕任意位置点击即可看到真实光标与点击效果")
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.inkMuted)
                    Spacer()
                    Text(settings.cursorStyle.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(p.inkSecondary)
                }
                .padding(.horizontal, 4)
            }
        }

        // Style grid + size slider
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeading(title: "光标样式与大小", icon: "cursorarrow")

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(CursorStyle.allCases, id: \.self) { style in
                        StyleTile(style: style, selected: settings.cursorStyle == style) {
                            withAnimation(StudioSpring.snappy) { settings.cursorStyle = style }
                        }
                    }
                }

                Rectangle().fill(p.divider).frame(height: 1)

                HStack(spacing: 12) {
                    Text("大小")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(p.inkSecondary)
                    Slider(value: $settings.cursorSize, in: 0.75...2.5)
                    Text(String(format: "%.2f×", settings.cursorSize))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(p.inkPrimary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }

        // Bottom 1:1 Bento Split (equalized height)
        HStack(alignment: .top, spacing: 14) {
            StudioCard {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeading(title: "点击反馈", icon: "dot.radiowaves.left.and.right")

                    StudioSegmentedPicker(options: ClickEffect.allCases, selection: $settings.clickEffect) { $0.title }

                    HStack {
                        Text("颜色")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(p.inkSecondary)
                        Spacer()
                        HStack(spacing: 8) {
                            ForEach(ClickColor.allCases, id: \.self) { option in
                                ColorDot(color: option.color, title: option.title, selected: settings.clickColor == option) {
                                    withAnimation(StudioSpring.tactile) { settings.clickColor = option }
                                }
                            }
                        }
                    }
                    .opacity(settings.clickEffect == .none ? 0.35 : 1)
                    .disabled(settings.clickEffect == .none)

                    Spacer(minLength: 0)

                    Text("点击鼠标左键或右键时，在光标落点渲染反馈波纹。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.inkMuted)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StudioCard {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeading(title: "动效与显示", icon: "sparkles")

                    StudioToggleRow(
                        title: "移动平滑",
                        detail: "轨迹更顺滑，会比手略微柔和跟手",
                        isOn: $settings.smoothCursor
                    )

                    Rectangle().fill(p.divider).frame(height: 1)

                    StudioToggleRow(
                        title: "静止后自动隐藏",
                        isOn: $settings.hideIdleCursor.animation(StudioSpring.snappy)
                    )

                    if settings.hideIdleCursor {
                        HStack(spacing: 10) {
                            Text("等待时间")
                                .font(.system(size: 12))
                                .foregroundStyle(p.inkSecondary)
                            Slider(value: $settings.idleDelay, in: 1...10, step: 1)
                            Text("\(Int(settings.idleDelay)) 秒")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(p.inkPrimary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Rectangle().fill(p.divider).frame(height: 1)

                    StudioToggleRow(
                        title: "平时也使用自定义光标",
                        detail: "关闭后仅在放大期间生效",
                        isOn: $settings.customCursorAlways
                    )
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func previewPill(_ text: String, dark: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.68))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((dark ? Color.black.opacity(0.45) : Color.white.opacity(0.75)), in: Capsule())
    }
}

// MARK: - Page 3: General & Permissions

struct GeneralPage: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: AppStatus
    @State private var isInstalling = false

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        let summary = status.summary(enabled: settings.enabled, triggerTitle: settings.trigger.shortTitle, palette: p)

        PageHeader(title: "通用与权限", subtitle: "系统隐私授权、登录自启与应用安装位置")

        // Overview + launch switches card
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    BreathingDot(color: summary.color, animated: summary.breathes)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.bannerTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(p.inkPrimary)
                        Text(summary.bannerDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(p.inkSecondary)
                    }
                    Spacer()
                }

                Rectangle().fill(p.divider).frame(height: 1)

                StudioToggleRow(
                    title: "启用 LiveZoom",
                    detail: "暂停后将透传所有鼠标与键盘事件",
                    isOn: $settings.enabled
                )

                Rectangle().fill(p.divider).frame(height: 1)

                StudioToggleRow(
                    title: "登录时自动启动",
                    detail: "开机登录 macOS 后自动在菜单栏就绪",
                    isOn: Binding(get: { status.launchAtLogin }, set: { status.setLaunchAtLogin($0) })
                )

                if !AppInstaller.isInstalled {
                    Rectangle().fill(p.divider).frame(height: 1)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("安装位置")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(p.inkPrimary)
                            Text(AppInstaller.consoleInstallSubtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(p.inkSecondary)
                        }
                        Spacer(minLength: 8)
                        if isInstalling {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在移动…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.inkSecondary)
                            }
                        } else {
                            Button {
                                isInstalling = true
                                AppInstaller.installFromConsole { isInstalling = false }
                            } label: {
                                Text("移到\(AppInstaller.targetFolderDisplayName)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(p.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(TactileButtonStyle())
                        }
                    }
                }
            }
        }

        // Permissions Bento Split (1:1 equalized height)
        HStack(alignment: .top, spacing: 14) {
            permissionCard(
                title: "辅助功能",
                icon: "hand.tap",
                detail: "用于监听触发键、点击波纹、画笔手势与快捷键。",
                granted: status.accessibility,
                palette: p
            ) {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }

            permissionCard(
                title: "屏幕录制",
                icon: "rectangle.dashed.badge.record",
                detail: "用于高帧率采集放大画面。授权后需退出并重新打开 LiveZoom。",
                granted: status.screenRecording,
                palette: p
            ) {
                Permissions.requestScreenRecording()
                Permissions.openScreenRecordingSettings()
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        // About hairline strip (clean negative space, anti-card overuse)
        VStack(spacing: 12) {
            Rectangle().fill(p.divider).frame(height: 1)
            HStack(spacing: 16) {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                let versionText = build.map { "v\(version) (\($0))" } ?? version
                let path = (Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath

                Label(versionText, systemImage: "info.circle")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(p.inkMuted)

                Spacer()

                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(p.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
        }
        .padding(.top, 4)
    }

    private func permissionCard(
        title: String,
        icon: String,
        detail: String,
        granted: Bool,
        palette p: StudioPalette,
        action: @escaping () -> Void
    ) -> some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardHeading(title: title, icon: icon)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                        Text(granted ? "已授权" : "未授权")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(granted ? p.emerald : p.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((granted ? p.emerald : p.amber).opacity(p.isDark ? 0.16 : 0.11), in: Capsule())
                }

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(p.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if !granted {
                    Button(action: action) {
                        HStack(spacing: 6) {
                            Text("前往系统设置授权")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(p.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(TactileButtonStyle())
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(p.emerald)
                        Text("权限正常，无需额外操作")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.inkMuted)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Visual Tiles & Live Previews

/// A wavy sample line in one stroke style, drawn like the real thing on a dark studio canvas.
private struct InkTile: View {
    @Environment(\.colorScheme) private var scheme
    let style: InkStyle
    let color: NSColor
    let selected: Bool
    let animate: Bool
    let action: () -> Void

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        Button(action: action) {
            VStack(spacing: 6) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { timeline in
                    Canvas { ctx, size in
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.10, green: 0.115, blue: 0.145)))
                        draw(in: &ctx, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? p.accent : p.cardBorder, lineWidth: selected ? 2 : 1)
                )
                Text(style.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? p.inkPrimary : p.inkSecondary)
            }
            .scaleEffect(selected ? 1.02 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle())
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
            let cycle = w * 4.6
            line(c, w, dash: [w * 2.4, w * 2.2], phase: -CGFloat(time.truncatingRemainder(dividingBy: 0.6) / 0.6) * cycle)
        }
    }
}

private struct StyleTile: View {
    @Environment(\.colorScheme) private var scheme
    let style: CursorStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let p = StudioPalette(scheme: scheme)
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: p.isDark
                                    ? [Color(red: 0.16, green: 0.18, blue: 0.22), Color(red: 0.11, green: 0.13, blue: 0.17)]
                                    : [Color(red: 0.96, green: 0.97, blue: 0.985), Color(red: 0.91, green: 0.93, blue: 0.955)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    if let art = CursorThumbnail.art(for: style, scale: 3) {
                        // Scale down spotlight slightly so its halo fits cleanly inside the 64pt tile without top clipping.
                        let previewMagnification: CGFloat = style == .spotlight ? 1.0 : 1.25
                        Image(decorative: art.image, scale: CGFloat(art.image.width) / art.size.width / previewMagnification)
                    }
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(selected ? p.accent : p.cardBorder, lineWidth: selected ? 2 : 1)
                )
                Text(style.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? p.inkPrimary : p.inkSecondary)
            }
            .scaleEffect(selected ? 1.02 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle())
    }
}

/// The selected style at its real size on light and dark backgrounds, with a looping click effect.
private struct CursorPreview: View {
    let style: CursorStyle
    let size: Double
    let effect: ClickEffect
    let color: NSColor
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animate)) { timeline in
            Canvas { ctx, canvasSize in
                let half = canvasSize.width / 2
                ctx.fill(Path(CGRect(x: 0, y: 0, width: half, height: canvasSize.height)),
                         with: .color(Color(red: 0.96, green: 0.965, blue: 0.975)))
                ctx.fill(Path(CGRect(x: half, y: 0, width: half, height: canvasSize.height)),
                         with: .color(Color(red: 0.10, green: 0.115, blue: 0.145)))
                let age = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)
                let pixelScale = 2 * size
                guard let art = CursorThumbnail.art(for: style, scale: pixelScale) else { return }
                for x in [half / 2, half * 1.5] {
                    let tip = CGPoint(x: x, y: canvasSize.height / 2 + 6)
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

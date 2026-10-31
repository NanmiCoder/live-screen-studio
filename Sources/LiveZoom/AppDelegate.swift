import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let input = InputTap()
    private lazy var zoom = ZoomController(zoomLevel: settings.defaultZoom, followPreset: settings.followStyle.preset)
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var demo: Demo?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "LiveZoom")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        input.triggerButton = Int64(settings.trigger.rawValue)
        input.isEnabled = settings.enabled
        input.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggle: zoom.toggle()
            case .adjustZoom(let steps): zoom.adjustZoom(steps: steps)
            }
        }

        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--demo"), args.count > index + 2, let id = UInt32(args[index + 1]) {
            demo = Demo(zoom: zoom, displayID: id, outputDir: URL(fileURLWithPath: args[index + 2]))
            demo?.run()
            return
        }

        if !Permissions.screenRecording { Permissions.requestScreenRecording() }
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        startInputTap()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.zoom.reset()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        zoom.reset()
    }

    /// The event tap needs Accessibility permission; keep retrying until it is granted.
    private func startInputTap() {
        if input.start() {
            log("input tap running")
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.input.start() else { return }
            log("input tap running")
            timer.invalidate()
            self.permissionTimer = nil
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let ready = input.isRunning && Permissions.screenRecording
        let status = ready
            ? "就绪 · 点击\(settings.trigger.title)放大"
            : "需要授权后才能使用"
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        if !Permissions.accessibility {
            menu.addItem(item("授权「辅助功能」…", #selector(openAccessibility)))
        }
        if !Permissions.screenRecording {
            menu.addItem(item("授权「屏幕录制」…（授权后需重启 App）", #selector(openScreenRecording)))
        }
        menu.addItem(.separator())

        let enabled = item("启用", #selector(toggleEnabled))
        enabled.state = settings.enabled ? .on : .off
        menu.addItem(enabled)

        menu.addItem(submenu("默认倍数", Settings.zoomLevels.map { level in
            let entry = item(String(format: "%g×", level), #selector(selectZoom(_:)))
            entry.representedObject = level
            entry.state = settings.defaultZoom == level ? .on : .off
            return entry
        }))
        menu.addItem(submenu("触发键", TriggerButton.allCases.map { button in
            let entry = item(button.title, #selector(selectTrigger(_:)))
            entry.representedObject = button.rawValue
            entry.state = settings.trigger == button ? .on : .off
            return entry
        }))
        menu.addItem(submenu("跟随速度", FollowStyle.allCases.map { style in
            let entry = item(style.title, #selector(selectFollow(_:)))
            entry.representedObject = style.rawValue
            entry.state = settings.followStyle == style ? .on : .off
            return entry
        }))

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "按住触发键滚动滚轮可调倍数，⌥ + 触发键为原始点击", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(item("退出 LiveZoom", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        input.isEnabled = settings.enabled
        if !settings.enabled { zoom.reset() }
    }

    @objc private func selectZoom(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Double else { return }
        settings.defaultZoom = level
        zoom.zoomLevel = level
    }

    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let button = TriggerButton(rawValue: raw) else { return }
        settings.trigger = button
        input.triggerButton = Int64(raw)
    }

    @objc private func selectFollow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = FollowStyle(rawValue: raw) else { return }
        settings.followStyle = style
        zoom.followPreset = style.preset
    }

    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func openScreenRecording() {
        Permissions.requestScreenRecording()
        Permissions.openScreenRecordingSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

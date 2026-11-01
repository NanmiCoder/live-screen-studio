import AppKit
import Combine
import CursorKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let status = AppStatus()
    private let input = InputTap()
    private let presenter = CursorPresenter()
    private lazy var zoom = ZoomController(zoomLevel: settings.defaultZoom, followPreset: settings.followStyle.preset,
                                           presenter: presenter)
    private let console = ConsoleWindowController()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var settingsObserver: AnyCancellable?
    private var demo: Demo?
    private var diagnosis: CursorDiagnosis?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "LiveZoom")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        status.isInputTapRunning = { [weak self] in self?.input.isRunning ?? false }
        MainThreadWatch.shared.start {
            log("main thread stalled; restoring the system cursor and passing input through")
            CursorRenderer.forceShowSystemCursor()
        }
        input.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggle: zoom.toggle()
            case .adjustZoom(let steps): zoom.adjustZoom(steps: steps)
            case .click(let location): presenter.click(at: location)
            case .drawingPointer(let location): presenter.drawingPointer = location
            case .strokeBegan(let location):
                presenter.beginStroke(at: location)
                zoom.isDrawing = true
            case .strokeMoved(let location, let straight): presenter.moveStroke(to: location, straight: straight)
            case .strokeEnded:
                presenter.endStroke()
                zoom.isDrawing = false
            case .undoStroke: presenter.undoStroke()
            case .clearStrokes: presenter.clearStrokes(animated: true)
            case .highlight(let kind): highlight(kind)
            }
        }
        zoom.onDrawingAvailable = { [weak self] available in
            guard let self else { return }
            input.drawingArmed = available && settings.drawWhileZoomed
            input.keysArmed = available
            if available, !settings.shortcuts.isEmpty { TextFinder.warmUp() }
        }
        zoom.onCursorBounds = { [weak self] bounds in self?.input.cursorBounds = bounds }
        presenter.onStrokesChanged = { [weak self] any in self?.input.hasStrokes = any }
        applySettings()
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new value is stored.
            DispatchQueue.main.async { self?.applySettings() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.zoom.reset()
            self?.presenter.resetDisplays()
        }

        let args = CommandLine.arguments
        // Shows only the console on one page, without taking over the cursor or the mouse (for screenshots).
        if let index = args.firstIndex(of: "--console-preview") {
            console.show(settings: settings, status: status, section: args.count > index + 1 ? args[index + 1] : nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                log("console window \(self?.console.windowNumber ?? -1)")
            }
            return
        }
        if let index = args.firstIndex(of: "--cursor-diagnose"), args.count > index + 1 {
            diagnosis = CursorDiagnosis(presenter: presenter, outputDir: URL(fileURLWithPath: args[index + 1]))
            presenter.start()
            diagnosis?.run()
            return
        }
        if let index = args.firstIndex(where: { $0 == "--demo" || $0 == "--demo-ink" }), args.count > index + 2,
           let id = UInt32(args[index + 1]) {
            demo = Demo(zoom: zoom, presenter: presenter, displayID: id, outputDir: URL(fileURLWithPath: args[index + 2]))
            guard let demo else {
                let ids = NSScreen.screens.compactMap { $0.displayID }.map(String.init).joined(separator: ", ")
                log("demo: no display \(id); available: \(ids)")
                exit(1)
            }
            demo.run(ink: args[index] == "--demo-ink")
            presenter.start()
            return
        }

        if !Permissions.screenRecording { Permissions.requestScreenRecording() }
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        startInputTap()
        presenter.start()
        if !Permissions.accessibility || !Permissions.screenRecording {
            console.show(settings: settings, status: status)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        console.show(settings: settings, status: status)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        zoom.reset()
        presenter.shutdown()
    }

    private func applySettings() {
        input.isEnabled = settings.enabled
        input.triggerButton = Int64(settings.trigger.rawValue)
        zoom.followPreset = settings.followStyle.preset
        zoom.zoomLevel = settings.defaultZoom
        if !settings.enabled, zoom.isZooming { zoom.reset() }
        // Only on an actual change: re-arming resets any gesture in progress.
        let armed = zoom.isDrawingAvailable && settings.drawWhileZoomed
        if input.drawingArmed != armed { input.drawingArmed = armed }

        presenter.inkStyle = settings.inkStyle
        presenter.strokeColor = settings.inkColor.color
        presenter.strokeWidth = settings.strokeWidth
        input.shortcuts = Dictionary(settings.shortcuts.map { ($0.value.combo, $0.key) }, uniquingKeysWith: { a, _ in a })

        presenter.style = settings.cursorStyle
        presenter.sizeScale = settings.cursorSize
        presenter.clickEffect = settings.clickEffect
        presenter.clickColor = settings.clickColor.color
        presenter.smoothing = settings.smoothCursor
        presenter.idleDelay = settings.hideIdleCursor ? settings.idleDelay : nil
        presenter.alwaysOn = settings.customCursorAlways
        presenter.isEnabled = settings.enabled
    }

    /// Marks the line of text under the cursor; the spotlight shortcut turns an existing spotlight off instead.
    private func highlight(_ kind: HighlightKind) {
        if kind == .spotlight, presenter.removeSpotlight() { return }
        zoom.lineOfText { [weak self] line in
            // Zooming out clears the marks once; one arriving after that would stay behind.
            guard let self, let line, zoom.isDrawingAvailable else { return }
            presenter.addHighlight(kind, around: line)
        }
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
        let title = ready ? "就绪 · 单击\(settings.trigger.title)放大" : "需要授权后才能使用"
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let enabled = item("启用", #selector(toggleEnabled))
        enabled.state = settings.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(item("打开控制台…", #selector(openConsole), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("退出 LiveZoom", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
    }

    @objc private func openConsole() {
        console.show(settings: settings, status: status)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

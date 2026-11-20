import AppKit
import Darwin
import Foundation
import ServiceManagement

/// Offers to install LiveZoom into the macOS Applications folder when launched from a temporary location
/// (such as Downloads, a mounted DMG, or an App Translocation path), then relaunches from the installed copy.
enum AppInstaller {
    private static let suppressionKey = "suppressMoveToApplicationsPrompt"
    private static let restoreLoginItemKey = "restoreLoginItemAfterMove"

    /// The running `.app` bundle URL, or `nil` when invoked as a bare SwiftPM executable.
    static var currentAppURL: URL? {
        let url = Bundle.main.bundleURL.standardizedFileURL
        return url.pathExtension.lowercased() == "app" ? url : nil
    }

    /// Canonical app bundle filename (e.g. `LiveZoom.app`), avoiding duplicate names like `LiveZoom (1).app`.
    static var canonicalAppName: String {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (name?.isEmpty == false ? name! : "LiveZoom")
        return base.hasSuffix(".app") ? base : "\(base).app"
    }

    /// Whether LiveZoom is already running from `/Applications` or `~/Applications` (or not an `.app` bundle).
    static var isInstalled: Bool {
        guard let url = currentAppURL else { return true }
        return isInApplications(url)
    }

    /// Display name of the target Applications folder for UI labels.
    static var targetFolderDisplayName: String {
        applicationsFolderDisplayName(for: targetApplicationsDirectory())
    }

    /// Contextual explanation shown in the Console's General page when not running from Applications.
    static var consoleInstallSubtitle: String {
        let target = targetFolderDisplayName
        if let source = currentAppURL, isOnReadOnlyDiskImage(source) {
            return "当前正在安装包映像中运行，移入\(target)文件夹后会自动重启"
        }
        return "当前不在\(target)文件夹中，移入后清理「下载」文件夹不会丢失（会自动重启）"
    }

    /// Re-registers Launch at Login after a move if it had been enabled before moving.
    static func restoreLoginItemIfNeeded() {
        guard UserDefaults.standard.bool(forKey: restoreLoginItemKey) else { return }
        UserDefaults.standard.removeObject(forKey: restoreLoginItemKey)
        guard isInstalled else { return }
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("restore launch at login after move: \(error.localizedDescription)")
        }
    }

    /// Checks whether the app is running outside the Applications folder and, if appropriate, prompts the user
    /// to move it there. Returns `true` when the app has initiated a move + relaunch and should stop launching.
    @discardableResult
    static func promptIfNeeded() -> Bool {
        guard let source = currentAppURL else { return false }
        let forceOffer = CommandLine.arguments.contains("--offer-move")
        if !forceOffer {
            if isInApplications(source) { return false }
            if isDevelopmentBuild(source) { return false }
            if UserDefaults.standard.bool(forKey: suppressionKey) { return false }
        }

        let targetDir = targetApplicationsDirectory()
        let destination = targetDir.appendingPathComponent(canonicalAppName)
        guard !isSameItem(source, destination) else { return false }

        let targetName = applicationsFolderDisplayName(for: targetDir)
        let fromDiskImage = isOnReadOnlyDiskImage(source)
        let willReplace = FileManager.default.fileExists(atPath: destination.path)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "移到\(targetName)文件夹？"
        var detail = fromDiskImage
            ? "LiveZoom 当前正在安装包映像中运行。移到\(targetName)文件夹后，推出安装包也可以继续使用。"
            : "LiveZoom 当前不在\(targetName)文件夹中。移入后推出安装包或清理「下载」文件夹都不会影响使用，也能在启动台和聚焦搜索里随时打开。"
        if willReplace {
            detail += "\n\n\(targetName)文件夹中已有 LiveZoom，移动后会替换现有版本。"
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "移到\(targetName)")
        alert.addButton(withTitle: "暂不移动")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再提示"

        let response = runModalForeground(alert)
        guard response == .alertFirstButtonReturn else {
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: suppressionKey)
            }
            return false
        }

        switch performInstall(from: source, to: destination) {
        case .relaunched:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        case .installedButRelaunchFailed(let error):
            showRelaunchError(error, targetName: targetName)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        case .failed(let error):
            showInstallError(error, targetName: targetName)
            return false
        }
    }

    /// Triggered explicitly from the console's General page. Runs installation off the main thread so the UI
    /// and `MainThreadWatch` never stall.
    static func installFromConsole(onFinish: @escaping () -> Void) {
        guard let source = currentAppURL, !isInApplications(source) else {
            onFinish()
            return
        }
        let targetDir = targetApplicationsDirectory()
        let destination = targetDir.appendingPathComponent(canonicalAppName)
        guard !isSameItem(source, destination) else {
            onFinish()
            return
        }
        let targetName = applicationsFolderDisplayName(for: targetDir)

        if FileManager.default.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "替换现有的 LiveZoom？"
            alert.informativeText = "\(targetName)文件夹中已有 LiveZoom，移动后会替换它并从新位置重新打开。"
            alert.addButton(withTitle: "替换并重启")
            alert.addButton(withTitle: "取消")
            guard runModalForeground(alert) == .alertFirstButtonReturn else {
                onFinish()
                return
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = performInstall(from: source, to: destination)
            DispatchQueue.main.async {
                switch outcome {
                case .relaunched:
                    NSApp.terminate(nil)
                case .installedButRelaunchFailed(let error):
                    showRelaunchError(error, targetName: targetName)
                    NSApp.terminate(nil)
                case .failed(let error):
                    onFinish()
                    showInstallError(error, targetName: targetName)
                }
            }
        }
    }

    // MARK: - Path checks

    /// Accepts either the symlink-unresolved or symlink-resolved path inside `/Applications` or `~/Applications`
    /// (so Homebrew Cask symlinks in `/Applications` are treated as already installed).
    static func isInApplications(_ url: URL) -> Bool {
        let candidates = [
            normalizedComponents(url.standardizedFileURL),
            normalizedComponents(url.resolvingSymlinksInPath().standardizedFileURL),
        ]
        let roots = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            .map { normalizedComponents($0.resolvingSymlinksInPath().standardizedFileURL) }
        return roots.contains { prefix in
            candidates.contains { components in
                components.count > prefix.count && Array(components.prefix(prefix.count)) == prefix
            }
        }
    }

    static func isTranslocated(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/AppTranslocation/")
    }

    static func isReadOnlyLocation(_ url: URL) -> Bool {
        if isTranslocated(url) { return true }
        if let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return true
        }
        return false
    }

    static func isOnReadOnlyDiskImage(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix("/Volumes/") && isReadOnlyLocation(url)
    }

    /// Local builds inside a SwiftPM / Xcode project directory should not auto-prompt during development.
    static func isDevelopmentBuild(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let components = resolved.pathComponents
        if components.contains(".build") || components.contains("DerivedData") {
            return true
        }
        let fm = FileManager.default
        let parent = resolved.deletingLastPathComponent()
        let grandParent = parent.deletingLastPathComponent()
        return fm.fileExists(atPath: parent.appendingPathComponent("Package.swift").path)
            || fm.fileExists(atPath: grandParent.appendingPathComponent("Package.swift").path)
    }

    static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        if let idA = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject,
           let idB = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject {
            return idA.isEqual(idB)
        }
        return normalizedComponents(a.resolvingSymlinksInPath().standardizedFileURL)
            == normalizedComponents(b.resolvingSymlinksInPath().standardizedFileURL)
    }

    // MARK: - Installation

    private enum InstallOutcome {
        case relaunched
        case installedButRelaunchFailed(Error)
        case failed(Error)
    }

    private static func targetApplicationsDirectory() -> URL {
        let fm = FileManager.default
        let systemApps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fm.isWritableFile(atPath: systemApps.path) {
            return systemApps
        }
        return fm.urls(for: .applicationDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    private static func applicationsFolderDisplayName(for directory: URL) -> String {
        directory.path == "/Applications" ? "「应用程序」" : "个人「应用程序」"
    }

    private static func performInstall(from source: URL, to destination: URL) -> InstallOutcome {
        let fm = FileManager.default
        let appsDir = destination.deletingLastPathComponent()
        let token = UUID().uuidString
        let staged = appsDir.appendingPathComponent(".\(destination.lastPathComponent).installing-\(token)")
        let backup = appsDir.appendingPathComponent(".\(destination.lastPathComponent).backup-\(token)")
        var movedExistingToBackup = false

        do {
            try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
            // `--noqtn` avoids copying quarantine xattrs; `xattr -drs` clears any inherited ones without following symlinks.
            try runTool("/usr/bin/ditto", arguments: ["--noqtn", source.path, staged.path])
            _ = try? runTool("/usr/bin/xattr", arguments: ["-drs", "com.apple.quarantine", staged.path])

            let hadLoginItem = SMAppService.mainApp.status == .enabled
            terminateOtherInstances()

            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: backup)
                movedExistingToBackup = true
            }

            do {
                try fm.moveItem(at: staged, to: destination)
            } catch {
                if movedExistingToBackup {
                    try? fm.moveItem(at: backup, to: destination)
                }
                throw error
            }

            if movedExistingToBackup {
                if (try? fm.trashItem(at: backup, resultingItemURL: nil)) == nil {
                    try? fm.removeItem(at: backup)
                }
            }

            if hadLoginItem {
                UserDefaults.standard.set(true, forKey: restoreLoginItemKey)
                try? SMAppService.mainApp.unregister()
            }

            if !isReadOnlyLocation(source) && !isDevelopmentBuild(source) && !isSameItem(source, destination) {
                try? fm.trashItem(at: source, resultingItemURL: nil)
            }
        } catch {
            try? fm.removeItem(at: staged)
            log("failed to move app to \(destination.path): \(error.localizedDescription)")
            return .failed(error)
        }

        do {
            try scheduleRelaunch(of: destination)
            log("installed to \(destination.path); relaunching")
            return .relaunched
        } catch {
            log("installed to \(destination.path), but relaunch failed: \(error.localizedDescription)")
            return .installedButRelaunchFailed(error)
        }
    }

    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        guard !others.isEmpty else { return }

        for app in others { app.terminate() }
        let pids = others.map(\.processIdentifier)
        waitUntilExited(pids, timeout: 2.0)

        let survivors = others.filter { isProcessAlive($0.processIdentifier) }
        guard !survivors.isEmpty else { return }
        for app in survivors { app.forceTerminate() }
        waitUntilExited(survivors.map(\.processIdentifier), timeout: 0.5)
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func waitUntilExited(_ pids: [pid_t], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while pids.contains(where: isProcessAlive), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func scheduleRelaunch(of appURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        trap '' HUP
        pid="$1"
        app="$2"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        sleep 0.1
        /usr/bin/open -n "$app"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "_", "\(pid)", appURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    private static func runTool(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        // Drain pipe before waitUntilExit to avoid deadlocking if stderr exceeds the pipe buffer.
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "com.relakkes.livezoom.installer",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "命令执行失败（退出码 \(process.terminationStatus)）" : message]
            )
        }
        return message
    }

    /// Brings the alert in front of Finder/DMG windows even though LiveZoom is an `LSUIElement` accessory app.
    private static func runModalForeground(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        alert.window.orderFrontRegardless()
        return alert.runModal()
    }

    private static func showInstallError(_ error: Error, targetName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法自动移到\(targetName)文件夹"
        alert.informativeText = "请手动将 LiveZoom 拖进\(targetName)文件夹。\n\n错误详情：\(error.localizedDescription)"
        alert.addButton(withTitle: "好的")
        _ = runModalForeground(alert)
    }

    private static func showRelaunchError(_ error: Error, targetName: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已移到\(targetName)文件夹"
        alert.informativeText = "LiveZoom 已安装完成，但未能自动重启，请从\(targetName)文件夹中重新打开。\n\n错误详情：\(error.localizedDescription)"
        alert.addButton(withTitle: "好的")
        _ = runModalForeground(alert)
    }

    private static func normalizedComponents(_ url: URL) -> [String] {
        url.pathComponents.map { $0.lowercased() }
    }
}

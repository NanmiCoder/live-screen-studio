import AppKit

/// `LiveZoom --cursor-diagnose <outDir>`: runs the real cursor pipeline for a few seconds, nudges the mouse,
/// and captures the area around it (with the system cursor composited) to check that only one cursor shows.
final class CursorDiagnosis {
    private let presenter: CursorPresenter
    private let outputDir: URL
    private var shots = 0

    init(presenter: CursorPresenter, outputDir: URL) {
        self.presenter = presenter
        self.outputDir = outputDir
    }

    func run() {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        presenter.recordsFrames = true
        presenter.isEnabled = true
        presenter.alwaysOn = true
        at(0.4) { self.shot() }
        at(0.6) { self.nudge(4) }
        at(0.8) { self.shot() }
        at(1.0) { self.nudge(-4) }
        at(1.2) { self.shot() }
        at(1.4) { for i in 0..<12 { self.at(Double(i) * 0.016) { self.nudge(2) } } }
        at(1.7) { self.shot() }
        at(1.9) { for i in 0..<12 { self.at(Double(i) * 0.016) { self.nudge(-2) } } }
        at(2.3) { self.shot() }
        at(2.6) {
            self.report()
            self.presenter.shutdown()
            self.at(0.2) { NSApp.terminate(nil) }
        }
    }

    private func at(_ seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }

    private func nudge(_ dx: CGFloat) {
        guard let location = CGEvent(source: nil)?.location else { return }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: location.x + dx, y: location.y), mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func shot() {
        let mouse = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens[0].frame.height
        let region = "\(Int(mouse.x) - 50),\(Int(mainHeight - mouse.y) - 50),100,100"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", "-R", region, outputDir.appendingPathComponent("shot\(shots).png").path]
        shots += 1
        try? process.run()
    }

    private func report() {
        let times = presenter.frameTimes
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.sorted()
        guard !gaps.isEmpty else { return log("diagnose: no frames drawn") }
        let median = gaps[gaps.count / 2], p95 = gaps[Int(Double(gaps.count) * 0.95)], worst = gaps.last!
        log(String(format: "diagnose: %d frames, interval median %.1f ms, p95 %.1f ms, max %.1f ms; system cursor visible in %d frames",
                   times.count, median, p95, worst, presenter.revealedFrames))
    }
}

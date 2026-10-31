import AppKit
import ZoomCore

/// Scripted run on one display with a virtual cursor, so zoom can be verified without touching the real mouse.
///   LiveZoom --demo <displayID> <outputDir>
/// Logs the camera every frame and takes screenshots at fixed moments.
final class Demo {
    private struct Move {
        let start: Double
        let end: Double
        let to: CGPoint
    }

    private let zoom: ZoomController
    private let screen: NSScreen
    private let outputDir: URL
    private let startTime = CACurrentMediaTime()
    private var cursor: CGPoint
    private var moveFrom: CGPoint
    private var move: Move?
    private var lines: [String] = []

    init?(zoom: ZoomController, displayID: CGDirectDisplayID, outputDir: URL) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return nil }
        self.zoom = zoom
        self.screen = screen
        self.outputDir = outputDir
        cursor = CGPoint(x: screen.frame.width * 0.5, y: screen.frame.height * 0.5)
        moveFrom = cursor
    }

    private var size: CGSize { screen.frame.size }
    private var elapsed: Double { CACurrentMediaTime() - startTime }

    func run() {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        zoom.managesSystemCursor = false
        zoom.cursorLocation = { [unowned self] in self.global(self.currentCursor()) }
        zoom.onFrame = { [unowned self] camera in
            let vp = camera.viewport
            let c = self.currentCursor()
            self.lines.append(String(format: "%.3f %@ z=%.4f vp=%.1f,%.1f,%.1f,%.1f cursor=%.1f,%.1f",
                                     self.elapsed, "\(camera.phase)", camera.zoom, vp.minX, vp.minY, vp.width, vp.height,
                                     c.x, c.y))
        }

        // 1. Overlay at exactly 1× must look identical to the real screen.
        at(0.0) { self.shot("0-before") }
        at(0.4) {
            self.mark("identity")
            self.zoom.minZoom = 1
            self.zoom.zoomLevel = 1
            self.zoom.toggle()
        }
        at(1.4) { self.shot("1-identity") }
        at(2.2) { self.zoom.toggle() }
        // 2. Eased zoom-in toward a point, then small moves inside the safe zone.
        at(3.0) {
            self.mark("zoom-in")
            self.zoom.minZoom = 1.25
            self.zoom.zoomLevel = 2
            self.cursor = CGPoint(x: self.size.width * 0.3, y: self.size.height * 0.35)
            self.zoom.toggle()
        }
        at(3.25) { self.shot("2-zooming") }
        at(4.0) { self.shot("3-zoomed") }
        at(4.2) { self.moveTo(x: self.size.width * 0.3 + 80, y: self.size.height * 0.35 + 50, over: 0.8) }
        // 3. Fast move to the far corner: the camera should follow at limited speed.
        at(5.5) { self.mark("follow"); self.moveTo(x: self.size.width * 0.92, y: self.size.height * 0.85, over: 0.4) }
        at(8.4) { self.shot("4-followed") }
        // 4. Wheel adjustment, then zoom out.
        at(8.6) { self.mark("wheel"); self.zoom.adjustZoom(steps: 4) }
        at(9.6) { self.shot("5-wheel") }
        at(10.0) { self.mark("zoom-out"); self.zoom.toggle() }
        at(11.0) {
            self.shot("6-after")
            self.mark("end")
        }
        at(11.6) {
            try? self.lines.joined(separator: "\n").write(to: self.outputDir.appendingPathComponent("camera.log"),
                                                          atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func at(_ seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }

    private func mark(_ name: String) {
        lines.append(String(format: "%.3f MARK %@", elapsed, name))
    }

    private func moveTo(x: CGFloat, y: CGFloat, over duration: Double) {
        moveFrom = currentCursor()
        move = Move(start: elapsed, end: elapsed + duration, to: CGPoint(x: x, y: y))
    }

    private func currentCursor() -> CGPoint {
        guard let move else { return cursor }
        let t = min(max((elapsed - move.start) / (move.end - move.start), 0), 1)
        let p = CGPoint(x: moveFrom.x + (move.to.x - moveFrom.x) * t, y: moveFrom.y + (move.to.y - moveFrom.y) * t)
        if t >= 1 {
            cursor = move.to
            self.move = nil
        }
        return p
    }

    /// Display-local top-left point → global AppKit coordinates.
    private func global(_ p: CGPoint) -> NSPoint {
        NSPoint(x: screen.frame.minX + p.x, y: screen.frame.maxY - p.y)
    }

    private func shot(_ name: String) {
        let mainHeight = NSScreen.screens[0].frame.height
        let f = screen.frame
        let region = "\(Int(f.minX)),\(Int(mainHeight - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", region, outputDir.appendingPathComponent("\(name).png").path]
        try? process.run()
        mark("shot \(name)")
    }
}

import AppKit
import CursorKit
import ZoomCore

/// Scripted run on one display with a virtual cursor, so zoom can be verified without touching the real mouse.
///   LiveZoom --demo <displayID> <outputDir>       zoom, follow, a stroke, the wheel
///   LiveZoom --demo-ink <displayID> <outputDir>   every stroke style, then every highlight on real text
/// Logs the camera every frame and takes screenshots at fixed moments.
final class Demo {
    private struct Move {
        let start: Double
        let end: Double
        let to: CGPoint
    }

    private let zoom: ZoomController
    private let presenter: CursorPresenter
    private let screen: NSScreen
    private let outputDir: URL
    private let startTime = CACurrentMediaTime()
    private var cursor: CGPoint
    private var moveFrom: CGPoint
    private var move: Move?
    private var lines: [String] = []

    init?(zoom: ZoomController, presenter: CursorPresenter, displayID: CGDirectDisplayID, outputDir: URL) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return nil }
        self.zoom = zoom
        self.presenter = presenter
        self.screen = screen
        self.outputDir = outputDir
        cursor = CGPoint(x: screen.frame.width * 0.5, y: screen.frame.height * 0.5)
        moveFrom = cursor
    }

    private var size: CGSize { screen.frame.size }
    private var elapsed: Double { CACurrentMediaTime() - startTime }

    func run(ink: Bool = false) {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        zoom.cursorLocation = { [unowned self] in self.global(self.currentCursor()) }
        presenter.managesSystemCursor = false
        presenter.cursorLocation = zoom.cursorLocation
        zoom.onFrame = { [unowned self] camera, sequence in
            let vp = camera.viewport
            let c = self.currentCursor()
            self.lines.append(String(format: "%.3f %@ z=%.4f vp=%.1f,%.1f,%.1f,%.1f cursor=%.1f,%.1f seq=%d",
                                     self.elapsed, "\(camera.phase)", camera.zoom, vp.minX, vp.minY, vp.width, vp.height,
                                     c.x, c.y, sequence))
        }
        if ink { return runInk() }

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
        // A circled annotation around the cursor; it must stay on the content while the camera pans later.
        at(5.05) { self.drawCircle(radius: 70, over: 0.4) }
        at(5.5) { self.shot("3b-drawn") }
        // 3. Fast move to the far corner: the camera should follow at limited speed.
        at(5.8) { self.mark("follow"); self.moveTo(x: self.size.width * 0.92, y: self.size.height * 0.85, over: 0.4) }
        at(8.2) { self.click() }
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

    /// Zooms in on text, draws one stroke in each style, then marks lines of text with each highlight.
    private func runInk() {
        at(0.0) { self.shot("ink-0-before") }
        at(0.3) {
            self.zoom.zoomLevel = 2
            self.cursor = CGPoint(x: self.size.width * 0.3, y: self.size.height * 0.32)
            self.zoom.toggle()
        }
        at(1.5) {
            self.mark("styles")
            for (i, style) in InkStyle.allCases.enumerated() {
                self.presenter.inkStyle = style
                let y = self.cursor.y - 120 + CGFloat(i) * 50
                let points = (0...30).map { k -> CGPoint in
                    let t = CGFloat(k) / 30
                    return CGPoint(x: self.cursor.x - 160 + t * 320, y: y + sin(t * .pi * 2) * 12)
                }
                self.presenter.beginStroke(at: self.cg(points[0]))
                points.dropFirst().forEach { self.presenter.moveStroke(to: self.cg($0), straight: false) }
                self.presenter.endStroke()
            }
        }
        at(2.4) { self.shot("ink-1-styles") }
        at(2.8) {
            self.presenter.clearStrokes(animated: false)
            self.presenter.inkStyle = .neon
        }
        // One highlight per line, at rows of the stage's text (on the 1728 × 1117 built-in display); the camera
        // holds still for these small moves. The underline is pointed at from just below its line.
        let targets: [(HighlightKind, CGFloat)] = [(.box, 209), (.underline, 328), (.fill, 461)]
        for (i, (kind, y)) in targets.enumerated() {
            at(3.0 + Double(i) * 0.9) {
                self.cursor = CGPoint(x: self.size.width * 0.3, y: y)
                self.mark("highlight \(kind)")
                self.zoom.lineOfText { line in
                    self.lines.append("line for \(kind): \(line.map { "\($0)" } ?? "none")")
                    if let line { self.presenter.addHighlight(kind, around: line) }
                }
            }
        }
        at(6.0) { self.shot("ink-2-highlights") }
        at(6.3) {
            self.cursor = CGPoint(x: self.size.width * 0.3, y: 503)
            self.zoom.lineOfText { line in
                self.lines.append("line for spotlight: \(line.map { "\($0)" } ?? "none")")
                if let line { self.presenter.addHighlight(.spotlight, around: line) }
            }
        }
        at(7.2) { self.shot("ink-3-spotlight") }
        at(7.5) { self.zoom.toggle() }
        at(8.6) { self.shot("ink-4-after") }
        at(9.2) {
            try? self.lines.joined(separator: "\n").write(to: self.outputDir.appendingPathComponent("camera.log"),
                                                          atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func at(_ seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }

    private func drawCircle(radius: CGFloat, over duration: Double) {
        let center = currentCursor()
        let steps = 24
        mark("draw")
        zoom.isDrawing = true
        for i in 0...steps {
            at(duration * Double(i) / Double(steps)) {
                let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let p = self.cg(CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
                if i == 0 { self.presenter.beginStroke(at: p) } else { self.presenter.moveStroke(to: p, straight: false) }
                if i == steps { self.zoom.isDrawing = false }
            }
        }
    }

    /// Display-local top-left point → global CG coordinates (top-left origin).
    private func cg(_ p: CGPoint) -> CGPoint {
        let g = global(p)
        return CGPoint(x: g.x, y: NSScreen.screens[0].frame.height - g.y)
    }

    /// A click mark at the virtual cursor, as the event tap would report it (global CG coordinates).
    private func click() {
        let p = global(currentCursor())
        presenter.click(at: CGPoint(x: p.x, y: NSScreen.screens[0].frame.height - p.y))
        mark("click")
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

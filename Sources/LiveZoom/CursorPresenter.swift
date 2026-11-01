import AppKit
import CursorKit
import QuartzCore

/// Draws the cursor LiveZoom shows (style, size, smoothing, idle fade, click marks) in place of the system one.
/// Runs on its own display link, or is driven by ZoomController while zoomed so cursor and content move in lockstep.
final class CursorPresenter: NSObject {
    struct ZoomMapping {
        let displayID: CGDirectDisplayID
        /// Display-local point → where it appears on the zoomed overlay.
        let map: (CGPoint) -> CGPoint
        let scale: CGFloat
        /// Top-left of the visible part of the display, display-local.
        let origin: CGPoint
        /// The cursor is being held on this display (see `InputTap.cursorBounds`).
        let holdsCursor: Bool
    }

    var style: CursorStyle = .classic
    var sizeScale: CGFloat = 1.2
    var clickEffect: ClickEffect = .ripple
    var clickColor: NSColor = .systemBlue
    var smoothing = false {
        didSet { motion.smoothTime = smoothing ? 0.06 : 0 }
    }
    var idleDelay: Double? {
        didSet { motion.idleDelay = idleDelay }
    }
    var inkStyle: InkStyle = .marker
    var strokeColor = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    /// Line width on screen at the moment of drawing; strokes then scale with the content.
    var strokeWidth: CGFloat = 5
    /// Called with whether any strokes or highlights remain.
    var onStrokesChanged: ((Bool) -> Void)?
    /// Show the custom cursor all the time, not only while zoomed.
    var alwaysOn = true {
        didSet { updateActivation() }
    }
    var isEnabled = true {
        didSet { updateActivation() }
    }

    /// Global CG coordinates of input owned by the draw tap, independent of whether ink remains after undo.
    var drawingPointer: CGPoint?
    var drawingCursorLocation: NSPoint? {
        guard let drawingPointer, let main = NSScreen.screens.first else { return nil }
        return NSPoint(x: drawingPointer.x, y: main.frame.height - drawingPointer.y)
    }

    // Test hooks: the demo drives a virtual cursor and leaves the real one alone.
    var cursorLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var managesSystemCursor = true
    /// Diagnostics: timestamps of drawn frames.
    var recordsFrames = false
    private(set) var frameTimes: [CFTimeInterval] = []
    var revealedFrames: Int { system.revealedFrames }
    /// The system cursor is showing although LiveZoom hides it (e.g. over the Dock).
    var isSystemCursorRevealed: Bool { active && managesSystemCursor && system.isRevealed }

    private let system = CursorRenderer()
    private var canvases: [CGDirectDisplayID: CursorCanvasWindow] = [:]
    private var link: CADisplayLink?
    private var linkDisplay: CGDirectDisplayID?
    private var lastTimestamp: CFTimeInterval = 0
    private var motion = CursorMotion(position: .zero, now: 0)
    private var active = false
    private var activeFrames = 0
    private var zoomDriven = false
    private var zoomMapping: ZoomMapping?
    /// Click positions in global AppKit coordinates.
    private var marks: [(position: CGPoint, start: CFTimeInterval)] = []
    private var artCache: [String: CursorImage] = [:]
    private var lastFrameTime: CFTimeInterval = 0
    private var lastSeed: Int32?
    private var watchdog: Timer?
    /// Strokes and highlights on the zoomed display, oldest first.
    private var annotations: [Annotation] = []
    private var strokesDisplay: CGDirectDisplayID?
    /// The last stroke is still being drawn (between `beginStroke` and `endStroke`).
    private var strokeInProgress = false

    private var shouldBeActive: Bool { isEnabled && (alwaysOn || zoomDriven) }

    func start() {
        updateActivation()
        // Safety net: if drawing ever stalls, give the user back the real cursor.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.active, self.system.isSystemCursorHidden,
                  CACurrentMediaTime() - self.lastFrameTime > 0.5 else { return }
            log("cursor drawing stalled; restoring the system cursor")
            self.system.showSystemCursor()
            if !self.zoomDriven { self.startLink() }
        }
    }

    /// Restores the system cursor, e.g. before quitting.
    func shutdown() {
        isEnabled = false
    }

    /// Drops per-display windows after the display layout changed.
    func resetDisplays() {
        for canvas in canvases.values { canvas.orderOut(nil) }
        canvases.removeAll()
        artCache.removeAll()
        if active, !zoomDriven { startLink() }
    }

    // MARK: - Zoom integration

    func beginZoom() {
        zoomDriven = true
        stopLink()
        updateActivation()
    }

    func zoomFrame(now: CFTimeInterval, dt: Double, mapping: ZoomMapping?) {
        zoomMapping = mapping
        frame(now: now, dt: dt)
    }

    func endZoom() {
        guard zoomDriven else { return }
        zoomDriven = false
        zoomMapping = nil
        if shouldBeActive { startLink() } else { updateActivation() }
    }

    // MARK: - Annotations

    /// - Parameter location: Global CG coordinates (top-left origin), as reported by the event tap.
    func beginStroke(at location: CGPoint) {
        guard let mapping = zoomMapping, let screen = Self.screen(id: mapping.displayID) else { return }
        let stroke = Annotation(strokeFrom: Self.local(cg: location, display: mapping.displayID), look: ink,
                                zoom: mapping.scale)
        add(stroke, on: screen, mapping: mapping)
        strokeInProgress = true
    }

    func moveStroke(to location: CGPoint, straight: Bool) {
        // After an undo mid-stroke the rest of that drag is ignored instead of extending an older stroke.
        guard strokeInProgress, let display = strokesDisplay, let stroke = annotations.last else { return }
        stroke.extend(to: Self.local(cg: location, display: display), straight: straight)
    }

    func endStroke() {
        strokeInProgress = false
    }

    /// Marks the line of text at `line` (display-local content points) on the zoomed display.
    func addHighlight(_ kind: HighlightKind, around line: CGRect) {
        guard let mapping = zoomMapping, let screen = Self.screen(id: mapping.displayID) else { return }
        if kind == .spotlight { removeSpotlight() }
        let highlight = Annotation(highlight: kind, line: line, display: screen.frame.size, look: ink, zoom: mapping.scale)
        add(highlight, on: screen, mapping: mapping)
    }

    /// Fades out the spotlight, if there is one; returns whether there was.
    @discardableResult
    func removeSpotlight() -> Bool {
        guard let index = annotations.lastIndex(where: \.isSpotlight) else { return false }
        fadeOut([annotations.remove(at: index).layer])
        onStrokesChanged?(!annotations.isEmpty)
        return true
    }

    /// Removes the stroke being drawn, or else the last stroke or highlight.
    func undoStroke() {
        annotations.popLast()?.layer.removeFromSuperlayer()
        strokeInProgress = false
        onStrokesChanged?(!annotations.isEmpty)
    }

    /// Removes all strokes and highlights; `animated` fades them out first (used when zooming out).
    func clearStrokes(animated: Bool) {
        guard !annotations.isEmpty else { return }
        let layers = annotations.map(\.layer)
        annotations.removeAll()
        strokeInProgress = false
        onStrokesChanged?(false)
        if animated {
            fadeOut(layers)
        } else {
            layers.forEach { $0.removeFromSuperlayer() }
        }
    }

    private var ink: InkLook { InkLook(style: inkStyle, color: strokeColor, width: strokeWidth) }

    private func add(_ annotation: Annotation, on screen: NSScreen, mapping: ZoomMapping) {
        if strokesDisplay != mapping.displayID { removeStrokes() }
        strokesDisplay = mapping.displayID
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas(for: screen, id: mapping.displayID).strokesLayer.addSublayer(annotation.layer)
        CATransaction.commit()
        annotations.append(annotation)
        onStrokesChanged?(true)
    }

    private func fadeOut(_ layers: [CALayer]) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setCompletionBlock { layers.forEach { $0.removeFromSuperlayer() } }
        layers.forEach { $0.opacity = 0 }
        CATransaction.commit()
    }

    private func removeStrokes() {
        annotations.forEach { $0.layer.removeFromSuperlayer() }
        annotations.removeAll()
        strokeInProgress = false
    }

    /// - Parameter location: Global CG coordinates (top-left origin), as reported by the event tap.
    func click(at location: CGPoint) {
        guard active, clickEffect != .none, let main = NSScreen.screens.first else { return }
        marks.append((CGPoint(x: location.x, y: main.frame.height - location.y), CACurrentMediaTime()))
    }

    // MARK: - Activation

    private func updateActivation() {
        if shouldBeActive, !active {
            active = true
            activeFrames = 0
            let now = CACurrentMediaTime()
            motion.jump(to: cursorLocation(), now: now)
            system.refresh()
            if !zoomDriven { startLink() }
            frame(now: now, dt: 1.0 / 60)
        } else if !shouldBeActive, active {
            active = false
            stopLink()
            if managesSystemCursor { system.showSystemCursor() }
            // One more frame with both cursors at the same spot, then remove ours.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.active else { return }
                for canvas in self.canvases.values { canvas.orderOut(nil) }
                self.marks.removeAll()
            }
        }
    }

    // MARK: - Frame

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(now - lastTimestamp, 1.0 / 240), 1.0 / 20)
        lastTimestamp = now
        frame(now: now, dt: dt)
    }

    private func frame(now: CFTimeInterval, dt: Double) {
        guard active else { return }
        activeFrames += 1
        lastFrameTime = CACurrentMediaTime()
        if recordsFrames { frameTimes.append(lastFrameTime) }
        var mouse = drawingCursorLocation ?? cursorLocation()
        if let mapping = zoomMapping, mapping.holdsCursor, let zoomed = Self.screen(id: mapping.displayID),
           !NSMouseInRect(mouse, zoomed.frame, false) {
            // Pushed past an edge and not yet put back by the input tap: draw it at the edge rather than
            // flicker onto the next display.
            mouse.x = min(max(mouse.x, zoomed.frame.minX), zoomed.frame.maxX - 0.5)
            mouse.y = min(max(mouse.y, zoomed.frame.minY + 0.5), zoomed.frame.maxY)
        }
        // Ink and its cursor use the same sample, without the optional cursor smoothing trailing the pen.
        if drawingPointer != nil { motion.jump(to: mouse, now: now) }
        let buttonsDown = drawingPointer != nil || NSEvent.pressedMouseButtons != 0
        motion.update(input: CGPoint(x: mouse.x, y: mouse.y), buttonsDown: buttonsDown,
                      now: now, dt: dt)
        let position = motion.position
        guard let screen = Self.screen(containing: position) else { return }
        // Hide the real cursor once ours has surely reached the screen.
        // A new cursor seed means another app just changed the cursor: re-read its image at once.
        let seed = CursorRenderer.cursorSeed?()
        if seed != lastSeed || seed == nil && activeFrames % 2 == 1 || activeFrames % 30 == 1 {
            lastSeed = seed
            system.refresh()
        }
        if activeFrames >= 2, managesSystemCursor {
            system.hideSystemCursor()
        }
        if !zoomDriven, linkDisplay != screen.displayID { startLink(on: screen) }

        var cursorImage: CGImage?
        var cursorFrame: CGRect?
        // If the system cursor cannot be hidden right now (over the Dock), let it show alone.
        let yielding = managesSystemCursor && system.isRevealed
        if !yielding, let screenID = screen.displayID,
           let art = currentArt(scale: sizeScale * zoomScale(on: screenID), screen: screen) {
            let scale = sizeScale * zoomScale(on: screenID)
            let p = mapped(Self.local(position, in: screen), on: screenID)
            cursorImage = art.image
            cursorFrame = CGRect(x: p.x - art.hotSpot.x * scale, y: p.y - art.hotSpot.y * scale,
                                 width: art.size.width * scale, height: art.size.height * scale)
        }

        marks.removeAll { clickEffect.appearance(age: now - $0.start) == nil }
        var marksByScreen: [CGDirectDisplayID: [CursorCanvasWindow.Mark]] = [:]
        for mark in marks {
            guard let look = clickEffect.appearance(age: now - mark.start),
                  let markScreen = Self.screen(containing: mark.position), let id = markScreen.displayID else { continue }
            let scale = sizeScale * zoomScale(on: id)
            var scaled = look
            scaled.radius *= scale
            scaled.lineWidth *= scale
            let center = mapped(Self.local(mark.position, in: markScreen), on: id)
            marksByScreen[id, default: []].append(.init(center: center, look: scaled, color: clickColor))
        }

        for target in NSScreen.screens {
            guard let id = target.displayID else { continue }
            let isCursorScreen = target == screen
            let screenMarks = marksByScreen[id] ?? []
            guard isCursorScreen || !screenMarks.isEmpty || id == strokesDisplay || canvases[id]?.isVisible == true
            else { continue }
            let canvas = canvas(for: target, id: id)
            canvas.render(cursorImage: isCursorScreen ? cursorImage : nil, cursorFrame: isCursorScreen ? cursorFrame : nil,
                          opacity: motion.opacity, marks: screenMarks)
            if id == strokesDisplay {
                canvas.setStrokeTransform(origin: zoomMapping?.origin ?? .zero, zoom: zoomMapping?.scale ?? 1)
            }
            if !canvas.isVisible { canvas.orderFrontRegardless() }
        }
    }

    /// The custom style for arrow-like cursors, the system image for everything else.
    private func currentArt(scale: CGFloat, screen: NSScreen) -> CursorImage? {
        let snapshot = system.snapshot
        let replace = style != .system
            && (snapshot == nil || snapshot?.kind == .arrow || (snapshot?.kind == .pointingHand && style.replacesPointingHand))
        if replace {
            // Render at a bucketed pixel density so zoom transitions do not re-render every frame.
            let pixels = (screen.backingScaleFactor * scale * 2).rounded(.up) / 2
            let key = "\(style.rawValue)@\(pixels)"
            if let cached = artCache[key] { return cached }
            if artCache.count > 48 { artCache.removeAll() }
            let art = CursorArt.render(style, scale: pixels)
            artCache[key] = art
            return art
        }
        return snapshot.map { CursorImage(image: $0.image, size: $0.size, hotSpot: $0.hotSpot) }
    }

    private func zoomScale(on id: CGDirectDisplayID) -> CGFloat {
        zoomMapping?.displayID == id ? zoomMapping!.scale : 1
    }

    private func mapped(_ local: CGPoint, on id: CGDirectDisplayID) -> CGPoint {
        guard let zoomMapping, zoomMapping.displayID == id else { return local }
        return zoomMapping.map(local)
    }

    private func canvas(for screen: NSScreen, id: CGDirectDisplayID) -> CursorCanvasWindow {
        if let existing = canvases[id] { return existing }
        let canvas = CursorCanvasWindow(screen: screen)
        canvases[id] = canvas
        return canvas
    }

    // MARK: - Display link

    private func startLink(on screen: NSScreen? = nil) {
        stopLink()
        guard let screen = screen ?? Self.screen(containing: CGPoint(x: cursorLocation().x, y: cursorLocation().y))
            ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        lastTimestamp = CACurrentMediaTime()
        self.link = link
        linkDisplay = screen.displayID
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        linkDisplay = nil
    }

    // MARK: - Geometry

    private static func screen(id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    /// Global CG point (top-left origin) → display-local point.
    private static func local(cg point: CGPoint, display: CGDirectDisplayID) -> CGPoint {
        let bounds = CGDisplayBounds(display)
        return CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.screens.min { distance(point, $0.frame) < distance(point, $1.frame) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    /// Global AppKit coordinates → display-local points with a top-left origin.
    private static func local(_ p: CGPoint, in screen: NSScreen) -> CGPoint {
        CGPoint(x: p.x - screen.frame.minX, y: screen.frame.maxY - p.y)
    }
}

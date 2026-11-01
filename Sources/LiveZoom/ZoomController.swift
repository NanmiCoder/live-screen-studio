import AppKit
import QuartzCore
import ZoomCore

/// Ties capture, overlay and camera together, driven by the zoomed screen's display link.
/// The cursor is drawn by CursorPresenter, which this controller drives frame by frame while zoomed.
final class ZoomController: NSObject {
    private enum State {
        case idle
        /// Waiting for a fresh capture frame before the overlay appears.
        case starting
        case active
        /// Back at 1×; the overlay goes away on the next frame.
        case finishing
    }

    /// Low-rate capture between zooms so the next zoom starts instantly.
    static let idleFPS = 2
    static let idleCaptureTimeout: TimeInterval = 300

    /// Every zoom starts here; wheel adjustments only last until the next zoom-out, so the level is predictable on air.
    var zoomLevel: CGFloat
    var followPreset: FollowPreset {
        didSet { camera?.config.follow = followPreset }
    }
    var minZoom: CGFloat = 1.25

    /// Called when drawing becomes possible (zoomed in) or stops being possible (zooming out or idle).
    var onDrawingAvailable: ((Bool) -> Void)?
    private(set) var isDrawingAvailable = false {
        didSet { if oldValue != isDrawingAvailable { onDrawingAvailable?(isDrawingAvailable) } }
    }
    /// Called with where the cursor may go while zoomed in (global CG coordinates, edges included), or nil.
    var onCursorBounds: ((CGRect?) -> Void)?
    /// Zooming out is always a deliberate click: while zoomed in, the cursor is held on the zoomed display and
    /// away from the Dock's edge, instead of zooming out when it gets there.
    private(set) var cursorBounds: CGRect? {
        didSet { if oldValue != cursorBounds { onCursorBounds?(cursorBounds) } }
    }
    /// While a stroke is being drawn the camera holds still, so the content under the pen does not slide away.
    /// The draw tap owns its release; session button state can miss a swallowed press.
    var isDrawing = false {
        didSet { camera?.followPaused = isDrawing }
    }

    // Test hooks: the demo drives a virtual cursor.
    var cursorLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var currentCursorLocation: NSPoint { presenter.drawingCursorLocation ?? cursorLocation() }
    /// Diagnostics: the camera and the capture frame number shown, once per display frame.
    var onFrame: ((ZoomCamera, Int) -> Void)?

    private let presenter: CursorPresenter
    private let capturer = ScreenCapturer()
    private var overlays: [CGDirectDisplayID: OverlayWindow] = [:]
    private var state = State.idle
    private var screen: NSScreen?
    private var overlay: OverlayWindow?
    private var camera: ZoomCamera?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var requestTime: CFTimeInterval = 0
    private var requestSequence = 0
    private var pendingFactor: CGFloat = 1
    private var zoomAgainWhenFinished = false
    private var offScreenSince: CFTimeInterval?
    /// Keeps the displayed IOSurfaces from being reused by ScreenCaptureKit while on screen.
    private var heldFrames: [ScreenCapturer.Frame] = []
    private var idleStopWork: DispatchWorkItem?

    init(zoomLevel: CGFloat, followPreset: FollowPreset, presenter: CursorPresenter) {
        self.zoomLevel = zoomLevel
        self.followPreset = followPreset
        self.presenter = presenter
        super.init()
        capturer.onStop = { [weak self] error in
            log("capture stopped: \(error.localizedDescription)")
            self?.reset()
        }
    }

    var isZooming: Bool { state != .idle }

    func toggle() {
        switch state {
        case .idle:
            start(factor: 1)
        case .starting:
            cancelStart()
        case .active:
            guard let camera, let screen else { return }
            let now = CACurrentMediaTime()
            let mouse = currentCursorLocation
            let local = Self.local(mouse, in: screen)
            if cursorBounds == nil, !NSMouseInRect(mouse, screen.frame, false) {
                // The cursor is on another display while this one zooms out: zoom there once this one is done.
                zoomAgainWhenFinished = true
            } else if camera.phase == .zoomingOut {
                camera.zoomIn(to: zoomLevel, cursor: local, now: now)
            } else {
                camera.zoomOut(cursor: local, now: now)
            }
        case .finishing:
            zoomAgainWhenFinished = true
        }
    }

    func adjustZoom(steps: CGFloat) {
        let factor = exp(0.1 * steps)
        switch state {
        case .idle:
            if steps > 0 { start(factor: 1) }
        case .starting:
            pendingFactor *= factor
        case .active:
            guard let camera, camera.phase == .zoomingIn || camera.phase == .zoomed else { return }
            camera.adjustZoom(by: factor)
        case .finishing:
            break
        }
    }

    /// Looks up the line of text under the cursor in the picture on screen, while zoomed in; calls back on the
    /// main thread with it in display-local content points, or nil.
    func lineOfText(_ completion: @escaping (CGRect?) -> Void) {
        guard state == .active, let camera, camera.phase == .zoomingIn || camera.phase == .zoomed, let screen,
              let frame = heldFrames.last else { return completion(nil) }
        var cursor = Self.local(currentCursorLocation, in: screen)
        cursor.x = min(max(cursor.x, 0), screen.frame.width)
        cursor.y = min(max(cursor.y, 0), screen.frame.height)
        TextFinder.line(in: frame, at: cursor, visible: camera.viewport, display: screen.frame.size,
                        completion: completion)
    }

    /// Drops everything immediately, e.g. when displays change or the app quits.
    func reset() {
        stopDisplayLink()
        for window in overlays.values { window.orderOut(nil) }
        overlays.removeAll()
        isDrawingAvailable = false
        cursorBounds = nil
        isDrawing = false
        presenter.clearStrokes(animated: false)
        presenter.endZoom()
        overlay = nil
        camera = nil
        heldFrames = []
        state = .idle
        zoomAgainWhenFinished = false
        idleStopWork?.cancel()
        Task { @MainActor in await capturer.stop() }
    }

    // MARK: - Lifecycle

    private func start(factor: CGFloat) {
        guard let screen = screenUnderCursor(), let displayID = screen.displayID else { return }
        state = .starting
        self.screen = screen
        pendingFactor = factor
        // Create the overlay before capture starts: ScreenCaptureKit only lists (and so only excludes) apps with windows.
        _ = overlay(for: screen, displayID: displayID)
        idleStopWork?.cancel()
        let requested = CACurrentMediaTime()
        Task { @MainActor in
            do {
                let fps = ScreenCapturer.refreshRate(of: displayID)
                if capturer.isRunning, capturer.displayID == displayID {
                    await capturer.setFrameRate(fps)
                } else {
                    try await capturer.start(displayID: displayID, fps: fps)
                    log(String(format: "capture started in %.0f ms", (CACurrentMediaTime() - requested) * 1000))
                }
            } catch is CancellationError {
                return
            } catch {
                log("capture failed: \(error.localizedDescription)")
                if state == .starting { state = .idle }
                return
            }
            guard state == .starting, self.screen === screen else { return }
            requestTime = CACurrentMediaTime()
            requestSequence = capturer.latestFrame?.sequence ?? 0
            startDisplayLink(on: screen)
        }
    }

    private func cancelStart() {
        stopDisplayLink()
        state = .idle
        // A capture still starting would otherwise keep running at full rate (or, if started again, twice).
        MainActor.assumeIsolated { capturer.cancelPendingStart() }
        lowerCaptureRate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(now - lastTimestamp, 1.0 / 240), 1.0 / 20)
        lastTimestamp = now
        switch state {
        case .idle: stopDisplayLink()
        case .starting: tickStarting(now: now, dt: dt)
        case .active: tickActive(now: now, dt: dt)
        case .finishing: finish()
        }
    }

    private func tickStarting(now: CFTimeInterval, dt: Double) {
        guard let screen, let displayID = screen.displayID else { return cancelStart() }
        let waited = CACurrentMediaTime() - requestTime
        // A new frame means the capture is fresh; with a static screen none may arrive, so fall back after a moment.
        guard capturer.latestFrame != nil,
              (capturer.latestFrame?.sequence ?? 0) > requestSequence || waited > 0.07 else {
            if waited > 1 {
                log("no frames from capture")
                cancelStart()
            }
            return
        }

        var config = ZoomCamera.Config()
        config.follow = followPreset
        config.minZoom = minZoom
        let camera = ZoomCamera(display: screen.frame.size, config: config)
        camera.zoomIn(to: zoomLevel * pendingFactor, cursor: Self.local(currentCursorLocation, in: screen), now: now)
        let overlay = overlay(for: screen, displayID: displayID)
        self.camera = camera
        self.overlay = overlay
        heldFrames = []
        // First frame at 1×: identical to the real screen, so the switch is invisible. Content and cursor
        // are committed together so they never land on screen a frame apart.
        CATransaction.begin()
        render()
        overlay.orderFrontRegardless()
        presenter.beginZoom()
        presenter.zoomFrame(now: now, dt: dt, mapping: mapping(for: camera, displayID: displayID))
        CATransaction.commit()
        state = .active
        log(String(format: "zoom in after %.0f ms", waited * 1000))
    }

    private func tickActive(now: CFTimeInterval, dt: Double) {
        guard let screen, let displayID = screen.displayID, let camera else { return reset() }
        let mouse = currentCursorLocation
        // The input tap keeps the cursor on this display while zoomed in, but it can overshoot an edge for a
        // moment before being put back: treat that as the edge. Only if it stays elsewhere (no input tap, or
        // another app moved it) is this display left behind.
        if NSMouseInRect(mouse, screen.frame, false) {
            offScreenSince = nil
        } else if offScreenSince == nil {
            offScreenSince = now
        }
        let gone = offScreenSince.map { now - $0 > 0.5 } ?? false
        // When something else takes over the cursor (e.g. a pinned Dock, the screenshot crosshair), the system
        // cursor shows at its real, unzoomed position, which no longer matches the zoomed picture.
        let systemCursorShowing = presenter.isSystemCursorRevealed
        if gone || systemCursorShowing, camera.phase == .zoomingIn || camera.phase == .zoomed {
            log("zooming out: \(gone ? "the cursor left the display" : "the system cursor is showing")")
            camera.zoomOut(cursor: Self.local(mouse, in: screen), now: now)
        }
        var cursor = Self.local(mouse, in: screen)
        cursor.x = min(max(cursor.x, 0), screen.frame.width)
        cursor.y = min(max(cursor.y, 0), screen.frame.height)
        camera.update(cursor: cursor, now: now, dt: dt)
        let zoomedIn = camera.phase == .zoomingIn || camera.phase == .zoomed
        if isDrawingAvailable, !zoomedIn {
            // Strokes shrink with the content as it zooms out, then fade.
            isDrawing = false
            presenter.clearStrokes(animated: true)
        }
        isDrawingAvailable = zoomedIn
        if zoomedIn != (cursorBounds != nil) {
            cursorBounds = zoomedIn ? Self.cursorBounds(on: screen, displayID: displayID) : nil
        }
        CATransaction.begin()
        render()
        presenter.zoomFrame(now: now, dt: dt, mapping: mapping(for: camera, displayID: displayID))
        CATransaction.commit()
        onFrame?(camera, heldFrames.last?.sequence ?? 0)
        // Back at 1×: this frame matches the real screen; the overlay goes away on the next one.
        if camera.phase == .idle { state = .finishing }
    }

    private func finish() {
        isDrawingAvailable = false
        cursorBounds = nil
        overlay?.orderOut(nil)
        // Let go of the last captured frame (about 57 MB on a 5K display).
        overlay?.clear()
        stopDisplayLink()
        presenter.endZoom()
        overlay = nil
        camera = nil
        heldFrames = []
        state = .idle
        lowerCaptureRate()
        if zoomAgainWhenFinished {
            zoomAgainWhenFinished = false
            start(factor: 1)
        }
    }

    private func render() {
        guard let camera, let overlay else { return }
        if let frame = capturer.latestFrame, frame.sequence != heldFrames.last?.sequence {
            heldFrames.append(frame)
            if heldFrames.count > 2 { heldFrames.removeFirst() }
        }
        overlay.render(surface: heldFrames.last?.surface, viewport: shownViewport(camera))
    }

    /// The part of the display on screen. While the zoom holds still it is snapped to whole output pixels, so a
    /// pan shifts the magnified picture as it is instead of resampling (and shimmering) its text every frame.
    private func shownViewport(_ camera: ZoomCamera) -> CGRect {
        guard camera.phase == .zoomed, camera.zoom == camera.targetZoom, let screen else { return camera.viewport }
        return ViewportMath.pixelAligned(camera.viewport, zoom: camera.zoom, pixelsPerPoint: screen.backingScaleFactor,
                                         display: camera.display)
    }

    private func mapping(for camera: ZoomCamera, displayID: CGDirectDisplayID) -> CursorPresenter.ZoomMapping {
        // The cursor and ink use the same (possibly snapped) viewport as the picture, so they stay on the content.
        let origin = shownViewport(camera).origin
        let zoom = camera.zoom
        return CursorPresenter.ZoomMapping(displayID: displayID,
                                           map: { CGPoint(x: ($0.x - origin.x) * zoom, y: ($0.y - origin.y) * zoom) },
                                           scale: zoom, origin: origin, holdsCursor: cursorBounds != nil)
    }

    private func overlay(for screen: NSScreen, displayID: CGDirectDisplayID) -> OverlayWindow {
        if let existing = overlays[displayID] { return existing }
        let window = OverlayWindow(screen: screen)
        overlays[displayID] = window
        return window
    }

    // MARK: - Capture rate

    private func lowerCaptureRate() {
        Task { @MainActor in await capturer.setFrameRate(Self.idleFPS) }
        idleStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .idle else { return }
            Task { @MainActor in await self.capturer.stop() }
        }
        idleStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleCaptureTimeout, execute: work)
    }

    // MARK: - Display link

    private func startDisplayLink(on screen: NSScreen) {
        stopDisplayLink()
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        lastTimestamp = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Geometry

    private func screenUnderCursor() -> NSScreen? {
        let mouse = currentCursorLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// Where the cursor may go while zoomed in: the whole display except a strip along the Dock's edge (the
    /// Dock itself when it is always shown), since over the Dock the system cursor cannot be hidden.
    private static func cursorBounds(on screen: NSScreen, displayID: CGDirectDisplayID) -> CGRect {
        let display = CGDisplayBounds(displayID)
        var left = display.minX, right = display.maxX - 0.5
        let top = display.minY
        var bottom = display.maxY - 0.5
        // An auto-hiding Dock appears when the cursor reaches the very edge; a few points keep it away.
        let strip: CGFloat = 3
        let frame = screen.frame, visible = screen.visibleFrame
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": left += max(visible.minX - frame.minX, strip)
        case "right": right -= max(frame.maxX - visible.maxX, strip)
        default: bottom -= max(visible.minY - frame.minY, strip)
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Global AppKit coordinates → display-local points with a top-left origin.
    private static func local(_ mouse: NSPoint, in screen: NSScreen) -> CGPoint {
        CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

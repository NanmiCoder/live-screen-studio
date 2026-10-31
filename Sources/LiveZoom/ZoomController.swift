import AppKit
import QuartzCore
import ZoomCore

/// Ties capture, overlay, cursor and camera together, driven by the zoomed screen's display link.
final class ZoomController: NSObject {
    private enum State {
        case idle
        /// Waiting for a fresh capture frame before the overlay appears.
        case starting
        case active
        /// Back at 1× with the system cursor restored; the overlay goes away on the next frame.
        case finishing
    }

    static let activeFPS = 60
    /// Low-rate capture between zooms so the next zoom starts instantly.
    static let idleFPS = 2
    static let idleCaptureTimeout: TimeInterval = 300

    /// Remembered zoom level; wheel adjustments carry over to the next zoom.
    var zoomLevel: CGFloat
    var followPreset: FollowPreset {
        didSet { camera?.config.follow = followPreset }
    }
    var minZoom: CGFloat = 1.25

    // Test hooks: the demo drives a virtual cursor and leaves the real one alone.
    var cursorLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var managesSystemCursor = true
    var onFrame: ((ZoomCamera) -> Void)?

    private let capturer = ScreenCapturer()
    private let cursor = CursorRenderer()
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
    private var shownFrames = 0
    /// Keeps the displayed IOSurfaces from being reused by ScreenCaptureKit while on screen.
    private var heldFrames: [ScreenCapturer.Frame] = []
    private var idleStopWork: DispatchWorkItem?

    init(zoomLevel: CGFloat, followPreset: FollowPreset) {
        self.zoomLevel = zoomLevel
        self.followPreset = followPreset
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
            let local = Self.local(cursorLocation(), in: screen)
            if camera.phase == .zoomingOut {
                camera.zoomIn(to: zoomLevel, cursor: local, now: now)
            } else {
                camera.zoomOut(cursor: local, now: now)
            }
        case .finishing:
            break
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
            guard let camera, let screen, camera.phase == .zoomingIn || camera.phase == .zoomed else { return }
            camera.adjustZoom(by: factor, cursor: Self.local(cursorLocation(), in: screen))
            zoomLevel = camera.targetZoom
        case .finishing:
            break
        }
    }

    /// Drops everything immediately, e.g. when displays change or the app quits.
    func reset() {
        stopDisplayLink()
        for window in overlays.values { window.orderOut(nil) }
        overlays.removeAll()
        cursor.showSystemCursor()
        overlay = nil
        camera = nil
        heldFrames = []
        state = .idle
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
                if capturer.isRunning, capturer.displayID == displayID {
                    await capturer.setFrameRate(Self.activeFPS)
                } else {
                    try await capturer.start(displayID: displayID, fps: Self.activeFPS)
                    log(String(format: "capture started in %.0f ms", (CACurrentMediaTime() - requested) * 1000))
                }
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
        lowerCaptureRate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(now - lastTimestamp, 1.0 / 240), 1.0 / 20)
        lastTimestamp = now
        switch state {
        case .idle: stopDisplayLink()
        case .starting: tickStarting(now: now)
        case .active: tickActive(now: now, dt: dt)
        case .finishing: finish()
        }
    }

    private func tickStarting(now: CFTimeInterval) {
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
        camera.zoomIn(to: zoomLevel * pendingFactor, cursor: Self.local(cursorLocation(), in: screen), now: now)
        zoomLevel = camera.targetZoom
        let overlay = overlay(for: screen, displayID: displayID)
        self.camera = camera
        self.overlay = overlay
        heldFrames = []
        shownFrames = 0
        cursor.refresh()
        // First frame at 1×: identical to the real screen, so the switch is invisible.
        render(cursor: Self.local(cursorLocation(), in: screen), cursorVisible: true)
        overlay.orderFrontRegardless()
        state = .active
        log(String(format: "zoom in after %.0f ms", waited * 1000))
    }

    private func tickActive(now: CFTimeInterval, dt: Double) {
        guard let screen, let camera else { return reset() }
        let mouse = cursorLocation()
        let inside = NSMouseInRect(mouse, screen.frame, false)
        let local = Self.local(mouse, in: screen)
        if !inside, camera.phase == .zoomingIn || camera.phase == .zoomed {
            camera.zoomOut(cursor: local, now: now)
        }
        camera.update(cursor: local, now: now, dt: dt)
        shownFrames += 1

        if camera.phase == .idle {
            // Last frame at 1×; the real cursor sits exactly under the drawn one.
            render(cursor: local, cursorVisible: inside)
            cursor.showSystemCursor()
            state = .finishing
            return
        }
        // Hide the real cursor once the overlay is surely on screen.
        if !inside {
            cursor.showSystemCursor()
        } else if shownFrames >= 2, managesSystemCursor {
            cursor.hideSystemCursor()
        }
        if shownFrames % 3 == 0, managesSystemCursor { cursor.refresh() }
        render(cursor: local, cursorVisible: inside)
        onFrame?(camera)
    }

    private func finish() {
        overlay?.orderOut(nil)
        stopDisplayLink()
        overlay = nil
        camera = nil
        heldFrames = []
        state = .idle
        lowerCaptureRate()
    }

    private func render(cursor local: CGPoint, cursorVisible: Bool) {
        guard let camera, let overlay else { return }
        if let frame = capturer.latestFrame, frame.sequence != heldFrames.last?.sequence {
            heldFrames.append(frame)
            if heldFrames.count > 2 { heldFrames.removeFirst() }
        }
        var cursorFrame: CGRect?
        if cursorVisible, let snapshot = cursor.snapshot {
            let p = camera.screenPoint(for: local)
            let z = camera.zoom
            cursorFrame = CGRect(x: p.x - snapshot.hotSpot.x * z, y: p.y - snapshot.hotSpot.y * z,
                                 width: snapshot.size.width * z, height: snapshot.size.height * z)
        }
        overlay.render(surface: heldFrames.last?.surface, viewport: camera.viewport,
                       cursorImage: cursor.snapshot?.image, cursorFrame: cursorFrame)
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
        let mouse = cursorLocation()
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
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

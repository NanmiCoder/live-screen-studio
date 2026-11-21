import CoreGraphics
import XCTest
@testable import ZoomCore

final class CameraTests: XCTestCase {
    let display = CGSize(width: 2304, height: 1536)
    let frame = 1.0 / 60

    private func run(_ camera: ZoomCamera, cursor: CGPoint, from start: TimeInterval, seconds: Double,
                     each: ((TimeInterval) -> Void)? = nil) -> TimeInterval {
        var t = start
        while t < start + seconds {
            t += frame
            camera.update(cursor: cursor, now: t, dt: frame)
            each?(t)
        }
        return t
    }

    private func assertInsideDisplay(_ camera: ZoomCamera, file: StaticString = #filePath, line: UInt = #line) {
        let r = camera.viewport
        let eps: CGFloat = 0.001
        XCTAssertGreaterThanOrEqual(r.minX, -eps, file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.minY, -eps, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxX, display.width + eps, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY, display.height + eps, file: file, line: line)
    }

    private func calmCamera() -> ZoomCamera {
        var config = ZoomCamera.Config()
        config.follow = .calm
        return ZoomCamera(display: display, config: config)
    }

    func testClampKeepsViewportInsideDisplay() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1000 {
            let zoom = CGFloat.random(in: 1...4, using: &rng)
            let c = CGPoint(x: .random(in: -500...3000, using: &rng), y: .random(in: -500...2000, using: &rng))
            let clamped = ViewportMath.clampCenter(c, zoom: zoom, display: display)
            let r = ViewportMath.rect(center: clamped, zoom: zoom, display: display)
            XCTAssertGreaterThanOrEqual(r.minX, -0.001)
            XCTAssertGreaterThanOrEqual(r.minY, -0.001)
            XCTAssertLessThanOrEqual(r.maxX, display.width + 0.001)
            XCTAssertLessThanOrEqual(r.maxY, display.height + 0.001)
        }
    }

    func testZoomInKeepsContentUnderCursorInPlace() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 1200, y: 800)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        XCTAssertEqual(camera.phase, .zoomingIn)
        _ = run(camera, cursor: cursor, from: 0, seconds: 0.7) { _ in
            let p = camera.screenPoint(for: cursor)
            XCTAssertEqual(p.x, cursor.x, accuracy: 0.01)
            XCTAssertEqual(p.y, cursor.y, accuracy: 0.01)
        }
        XCTAssertEqual(camera.phase, .zoomed)
        XCTAssertEqual(camera.zoom, 2, accuracy: 1e-9)
    }

    func testZoomInNearEdgeStaysInsideDisplay() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 10, y: 1530)
        camera.zoomIn(to: 3, cursor: cursor, now: 0)
        _ = run(camera, cursor: cursor, from: 0, seconds: 1) { _ in self.assertInsideDisplay(camera) }
        XCTAssertTrue(camera.viewport.insetBy(dx: -0.01, dy: -0.01).contains(cursor))
    }

    func testTransitionHandsOverToFollowWithoutJump() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 300, y: 200)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        var last = camera.center
        var lastStep: CGFloat = 0
        var maxAcceleration: CGFloat = 0
        _ = run(camera, cursor: cursor, from: 0, seconds: 1.5) { _ in
            let step = hypot(camera.center.x - last.x, camera.center.y - last.y)
            maxAcceleration = max(maxAcceleration, abs(step - lastStep))
            last = camera.center
            lastStep = step
        }
        XCTAssertEqual(camera.phase, .zoomed)
        XCTAssertTrue(camera.isSettled)
        let settled = camera.center
        _ = run(camera, cursor: cursor, from: 1.5, seconds: 1)
        XCTAssertEqual(camera.center.x, settled.x, accuracy: 0.001)
        XCTAssertEqual(camera.center.y, settled.y, accuracy: 0.001)
        XCTAssertLessThan(maxAcceleration, 15)
    }

    func testEdgePushHoldsViewportStillInsideAndGlides1To1AtEdge() {
        var config = ZoomCamera.Config()
        config.follow = .edge
        let camera = ZoomCamera(display: display, config: config)
        let start = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 1.75, cursor: start, now: 0)
        var t = run(camera, cursor: start, from: 0, seconds: 0.6)
        XCTAssertTrue(camera.isSettled)
        let settled = camera.center

        // Moving inside the 84% central region must not budge the camera at all (Apple ⌥⌘+ feel).
        for offset in [CGPoint(x: 450, y: 0), CGPoint(x: -450, y: 280), CGPoint(x: 200, y: -280)] {
            let inside = CGPoint(x: start.x + offset.x, y: start.y + offset.y)
            t = run(camera, cursor: inside, from: t, seconds: 0.25)
            XCTAssertEqual(camera.center.x, settled.x, accuracy: 0.001)
            XCTAssertEqual(camera.center.y, settled.y, accuracy: 0.001)
        }

        // Pushing steadily past the 8% right edge rim must glide smoothly with zero teleport ratchet.
        let rimX = camera.viewport.maxX - camera.viewport.width * FollowPreset.edge.margin
        var lastCenter = camera.center
        var steadySpeeds: [CGFloat] = []
        let panStart = t
        for i in 1...45 {
            t += frame
            let cursor = CGPoint(x: rimX + 300 * CGFloat(t - panStart), y: start.y)
            camera.update(cursor: cursor, now: t, dt: frame)
            let speed = hypot(camera.center.x - lastCenter.x, camera.center.y - lastCenter.y) * camera.zoom / CGFloat(frame)
            if i >= 20 { steadySpeeds.append(speed) }
            lastCenter = camera.center
        }
        let minSteady = steadySpeeds.min() ?? 0
        let maxSteady = steadySpeeds.max() ?? 0
        XCTAssertGreaterThan(minSteady, 450, "Steady edge push must maintain continuous glide")
        XCTAssertLessThan(maxSteady - minSteady, 40, "Steady edge push must not surge/brake like a ratchet")

        // Stopping the cursor must settle cleanly right at the 8% edge rim.
        let stopCursor = CGPoint(x: rimX + 300 * CGFloat(t - panStart), y: start.y)
        _ = run(camera, cursor: stopCursor, from: t, seconds: 1.0)
        XCTAssertTrue(camera.isSettled)
        XCTAssertEqual((camera.viewport.maxX - stopCursor.x) / camera.viewport.width, FollowPreset.edge.margin, accuracy: 0.01)
    }

    func testProportionalFollowHasZeroDeadzoneAndSmoothVelocity() {
        var config = ZoomCamera.Config()
        config.follow = .continuous
        let camera = ZoomCamera(display: display, config: config)
        let start = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 1.75, cursor: start, now: 0)
        var t = run(camera, cursor: start, from: 0, seconds: 0.6)
        XCTAssertTrue(camera.isSettled)

        // Move the cursor steadily at 350 pt/s for 1.5 seconds: camera must respond on frame 1 (no deadzone)
        // and settle into smooth, non-ratcheting velocity with zero sudden drops to 0.
        var lastCenter = camera.center
        var steadySpeeds: [CGFloat] = []
        let panStart = t
        for i in 1...90 {
            t += frame
            let cursor = CGPoint(x: start.x + 350 * CGFloat(t - panStart), y: start.y)
            camera.update(cursor: cursor, now: t, dt: frame)
            let speed = hypot(camera.center.x - lastCenter.x, camera.center.y - lastCenter.y) * camera.zoom / CGFloat(frame)
            if i == 1 {
                XCTAssertGreaterThan(speed, 0, "Proportional follow must respond immediately with zero deadzone")
            }
            if i >= 55 { steadySpeeds.append(speed) }
            lastCenter = camera.center
        }
        XCTAssertFalse(camera.isSettled)
        let minSteady = steadySpeeds.min() ?? 0
        let maxSteady = steadySpeeds.max() ?? 0
        XCTAssertGreaterThan(minSteady, 200, "Constant hand pan must never stall to 0")
        XCTAssertLessThan(maxSteady - minSteady, 25, "Constant hand pan must not surge/brake like a ratchet")
    }

    func testCursorInsideSafeZoneDoesNotMoveCalmCamera() {
        let camera = calmCamera()
        let start = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: start, now: 0)
        var t = run(camera, cursor: start, from: 0, seconds: 0.8)
        let settled = camera.center
        // Viewport is 1152x768; calm margin 0.30 gives safe half-extent 230.4x153.6.
        for offset in [CGPoint(x: 180, y: 0), CGPoint(x: -200, y: 120), CGPoint(x: 0, y: -140)] {
            let cursor = CGPoint(x: start.x + offset.x, y: start.y + offset.y)
            t = run(camera, cursor: cursor, from: t, seconds: 0.4)
            XCTAssertEqual(camera.center.x, settled.x, accuracy: 0.001)
            XCTAssertEqual(camera.center.y, settled.y, accuracy: 0.001)
        }
    }

    func testFollowInsideViewportUsesBaseSpeed() {
        let camera = calmCamera()
        camera.zoomIn(to: 2, cursor: CGPoint(x: 1152, y: 768), now: 0)
        var t = run(camera, cursor: CGPoint(x: 1152, y: 768), from: 0, seconds: 0.8)
        let cursor = CGPoint(x: 1700, y: 768)
        var last = camera.center
        var maxVisualSpeed: CGFloat = 0
        t = run(camera, cursor: cursor, from: t, seconds: 2) { _ in
            let step = hypot(camera.center.x - last.x, camera.center.y - last.y)
            maxVisualSpeed = max(maxVisualSpeed, step * camera.zoom / CGFloat(self.frame))
            last = camera.center
        }
        XCTAssertLessThanOrEqual(maxVisualSpeed, FollowPreset.calm.maxVisualSpeed + 0.5)
        XCTAssertGreaterThan(maxVisualSpeed, 0)
        _ = t
    }

    func testFlungCursorComesBackIntoViewQuickly() {
        let camera = calmCamera()
        camera.zoomIn(to: 2, cursor: CGPoint(x: 400, y: 400), now: 0)
        var t = run(camera, cursor: CGPoint(x: 400, y: 400), from: 0, seconds: 0.8)
        let far = CGPoint(x: 2200, y: 1400)
        var last = camera.center
        var maxVisualSpeed: CGFloat = 0
        var visibleAfter: Double?
        let start = t
        t = run(camera, cursor: far, from: t, seconds: 3) { now in
            let step = hypot(camera.center.x - last.x, camera.center.y - last.y)
            maxVisualSpeed = max(maxVisualSpeed, step * camera.zoom / CGFloat(self.frame))
            last = camera.center
            if visibleAfter == nil, camera.viewport.contains(far) { visibleAfter = now - start }
        }
        let limit = FollowPreset.calm.maxVisualSpeed * camera.config.catchUpLimit
        XCTAssertLessThanOrEqual(maxVisualSpeed, limit + 0.5)
        XCTAssertLessThan(try XCTUnwrap(visibleAfter), 1.0)
        let settled = ViewportMath.applySafeZone(center: camera.center, cursor: far, zoom: camera.zoom,
                                                 display: display, margin: FollowPreset.calm.margin)
        XCTAssertEqual(ViewportMath.clampCenter(settled, zoom: camera.zoom, display: display).x, camera.center.x, accuracy: 0.5)
    }

    func testCalmFollowHasZeroTeleportRatchetAndSettlesCleanly() {
        let camera = calmCamera()
        let start = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: start, now: 0)
        var t = run(camera, cursor: start, from: 0, seconds: 0.8)
        // Cross the calm safe zone (margin == settleMargin == 0.30) by 100pt and verify organic ease-out to rest.
        let crossing = CGPoint(x: 1480, y: 768)
        var maxDrop: CGFloat = 0
        var last = camera.center
        var lastSpeed: CGFloat = 0
        t = run(camera, cursor: crossing, from: t, seconds: 2.5) { _ in
            let speed = hypot(camera.center.x - last.x, camera.center.y - last.y) * camera.zoom / CGFloat(self.frame)
            maxDrop = max(maxDrop, lastSpeed - speed)
            lastSpeed = speed
            last = camera.center
        }
        XCTAssertTrue(camera.isSettled)
        // No brick-wall 60 pt/s -> 0 stop.
        XCTAssertLessThan(maxDrop, 45)
        let vp = camera.viewport
        XCTAssertEqual((vp.maxX - crossing.x) / vp.width, FollowPreset.calm.margin, accuracy: 0.01)
    }

    func testPausedFollowHoldsTheCamera() {
        let camera = ZoomCamera(display: display)
        camera.zoomIn(to: 2, cursor: CGPoint(x: 1152, y: 768), now: 0)
        var t = run(camera, cursor: CGPoint(x: 1152, y: 768), from: 0, seconds: 0.8)
        let held = camera.center
        camera.followPaused = true
        t = run(camera, cursor: CGPoint(x: 1720, y: 1100), from: t, seconds: 0.5)
        XCTAssertEqual(camera.center, held)
        camera.followPaused = false
        _ = run(camera, cursor: CGPoint(x: 1720, y: 1100), from: t, seconds: 1.5)
        XCTAssertNotEqual(camera.center, held)
    }

    func testWheelDuringZoomInIsDeferredWithoutJumps() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        var lastLog = log(camera.zoom)
        var maxStep: CGFloat = 0
        var t = 0.0
        for i in 0..<180 {
            t += frame
            if (12...16).contains(i) { camera.adjustZoom(by: 1.1) }
            camera.update(cursor: cursor, now: t, dt: frame)
            maxStep = max(maxStep, abs(log(camera.zoom) - lastLog))
            lastLog = log(camera.zoom)
        }
        XCTAssertLessThan(maxStep, 0.09)
        XCTAssertEqual(camera.zoom, 2 * pow(1.1, 5), accuracy: 1e-6)
    }

    func testCatchUpEndsWithoutAbruptBraking() {
        let camera = calmCamera()
        camera.zoomIn(to: 2, cursor: CGPoint(x: 400, y: 400), now: 0)
        var t = run(camera, cursor: CGPoint(x: 400, y: 400), from: 0, seconds: 0.8)
        var last = camera.center
        var lastSpeed: CGFloat = 0
        var maxDrop: CGFloat = 0
        t = run(camera, cursor: CGPoint(x: 2200, y: 1400), from: t, seconds: 3) { _ in
            let speed = hypot(camera.center.x - last.x, camera.center.y - last.y) * camera.zoom / CGFloat(self.frame)
            maxDrop = max(maxDrop, lastSpeed - speed)
            lastSpeed = speed
            last = camera.center
        }
        XCTAssertLessThan(maxDrop, 340)
        _ = t
    }

    func testWheelZoomLandsWithoutSubPixelTail() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        let t = run(camera, cursor: cursor, from: 0, seconds: 0.8)
        camera.adjustZoom(by: 1.1)
        var lastZoom = camera.zoom
        var tinyFrames = 0
        _ = run(camera, cursor: cursor, from: t, seconds: 2) { _ in
            let edgeMove = abs(log(camera.zoom) - log(lastZoom)) * self.display.width
            if edgeMove > 0, edgeMove < 0.5 { tinyFrames += 1 }
            lastZoom = camera.zoom
        }
        XCTAssertLessThanOrEqual(tinyFrames, 1)
        XCTAssertEqual(camera.zoom, 2.2, accuracy: 1e-9)
    }

    func testZoomOutReturnsExactlyToIdentity() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 1800, y: 300)
        camera.zoomIn(to: 2.5, cursor: cursor, now: 0)
        var t = run(camera, cursor: cursor, from: 0, seconds: 0.8)
        camera.zoomOut(cursor: cursor, now: t)
        XCTAssertEqual(camera.phase, .zoomingOut)
        t = run(camera, cursor: cursor, from: t, seconds: 0.5) { _ in self.assertInsideDisplay(camera) }
        XCTAssertEqual(camera.phase, .idle)
        XCTAssertEqual(camera.zoom, 1)
        XCTAssertEqual(camera.center, CGPoint(x: display.width / 2, y: display.height / 2))
        XCTAssertEqual(camera.viewport, CGRect(origin: .zero, size: display))
    }

    func testReversingMidTransitionIsContinuous() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 700, y: 900)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        var t = run(camera, cursor: cursor, from: 0, seconds: 0.18)
        let zoomBefore = camera.zoom, centerBefore = camera.center
        camera.zoomOut(cursor: cursor, now: t)
        t += frame
        camera.update(cursor: cursor, now: t, dt: frame)
        XCTAssertEqual(camera.zoom, zoomBefore, accuracy: 0.02)
        XCTAssertEqual(camera.center.x, centerBefore.x, accuracy: 3)
        XCTAssertEqual(camera.center.y, centerBefore.y, accuracy: 3)
        _ = run(camera, cursor: cursor, from: t, seconds: 0.5)
        XCTAssertEqual(camera.phase, .idle)
    }

    func testWheelAdjustKeepsCursorContentFixed() {
        let camera = calmCamera()
        let cursor = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        var t = run(camera, cursor: cursor, from: 0, seconds: 0.8)
        let before = camera.screenPoint(for: cursor)
        camera.adjustZoom(by: 1.5)
        t = run(camera, cursor: cursor, from: t, seconds: 1) { _ in
            let p = camera.screenPoint(for: cursor)
            XCTAssertEqual(p.x, before.x, accuracy: 0.5)
            XCTAssertEqual(p.y, before.y, accuracy: 0.5)
        }
        XCTAssertEqual(camera.zoom, 3, accuracy: 1e-6)
        camera.adjustZoom(by: 10)
        _ = run(camera, cursor: cursor, from: t, seconds: 1)
        XCTAssertEqual(camera.zoom, camera.config.maxZoom, accuracy: 1e-6)
    }

    func testSmoothDampNeverOvershoots() {
        var velocity = CGVector.zero
        var p = CGPoint.zero
        let target = CGPoint(x: 100, y: -50)
        for _ in 0..<600 {
            p = SmoothDamp.step(current: p, target: target, velocity: &velocity, smoothTime: 0.3, maxSpeed: 10_000, dt: frame)
            XCTAssertLessThanOrEqual(p.x, target.x + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, target.y - 1e-9)
        }
        XCTAssertEqual(p.x, target.x, accuracy: 0.01)
        XCTAssertEqual(p.y, target.y, accuracy: 0.01)
    }

    func testPixelAlignedPanningShowsShiftedCopies() {
        let display = CGSize(width: 2304, height: 1536)
        for zoom: CGFloat in [1.5, 2, 1.75] {
            let size = ViewportMath.size(display: display, zoom: zoom)
            for x in stride(from: 100.0, to: 101.0, by: 0.037) {
                let aligned = ViewportMath.pixelAligned(CGRect(origin: CGPoint(x: x, y: 333.3), size: size), zoom: zoom,
                                                        pixelsPerPoint: 2, display: display)
                let pixels = aligned.minX * zoom * 2
                XCTAssertEqual(pixels, pixels.rounded(), accuracy: 1e-6)
                let rows = aligned.minY * zoom * 2
                XCTAssertEqual(rows, rows.rounded(), accuracy: 1e-6)
                XCTAssertLessThanOrEqual(abs(aligned.minX - x) * zoom * 2, 0.5 + 1e-9)
            }
            let right = ViewportMath.pixelAligned(CGRect(origin: CGPoint(x: display.width - size.width, y: 0), size: size),
                                                  zoom: zoom, pixelsPerPoint: 2, display: display)
            XCTAssertLessThanOrEqual(right.maxX, display.width + 1e-9)
            XCTAssertGreaterThan(right.maxX, display.width - 1 / (zoom * 2) - 1e-9)
            let left = ViewportMath.pixelAligned(CGRect(origin: .zero, size: size), zoom: zoom, pixelsPerPoint: 2,
                                                 display: display)
            XCTAssertEqual(left.origin, .zero)
        }
    }
}

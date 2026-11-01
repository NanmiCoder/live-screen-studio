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
        // The cursor is still visible after zooming in.
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
        // After the transition the camera stays put: the end point already satisfies the follow rule.
        let settled = camera.center
        _ = run(camera, cursor: cursor, from: 1.5, seconds: 1)
        XCTAssertEqual(camera.center.x, settled.x, accuracy: 0.001)
        XCTAssertEqual(camera.center.y, settled.y, accuracy: 0.001)
        // Speed changes gradually frame to frame: no jumps, including at the hand-over.
        XCTAssertLessThan(maxAcceleration, 10)
    }

    func testCursorInsideSafeZoneDoesNotMoveCamera() {
        let camera = ZoomCamera(display: display)
        let start = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: start, now: 0)
        var t = run(camera, cursor: start, from: 0, seconds: 1)
        let settled = camera.center
        // The viewport is 1152x768; with a 25% margin the safe half-extent is 288x192.
        for offset in [CGPoint(x: 200, y: 0), CGPoint(x: -250, y: 150), CGPoint(x: 0, y: -180)] {
            let cursor = CGPoint(x: start.x + offset.x, y: start.y + offset.y)
            t = run(camera, cursor: cursor, from: t, seconds: 0.5)
            XCTAssertEqual(camera.center.x, settled.x, accuracy: 0.001)
            XCTAssertEqual(camera.center.y, settled.y, accuracy: 0.001)
        }
    }

    func testFollowInsideViewportUsesBaseSpeed() {
        let camera = ZoomCamera(display: display)
        camera.zoomIn(to: 2, cursor: CGPoint(x: 1152, y: 768), now: 0)
        var t = run(camera, cursor: CGPoint(x: 1152, y: 768), from: 0, seconds: 1)
        // Viewport is 1152x768 centred on the display: x 576...1728. This cursor is outside the
        // safe zone but still visible, so no catch-up boost applies.
        let cursor = CGPoint(x: 1700, y: 768)
        var last = camera.center
        var maxVisualSpeed: CGFloat = 0
        t = run(camera, cursor: cursor, from: t, seconds: 3) { _ in
            let step = hypot(camera.center.x - last.x, camera.center.y - last.y)
            maxVisualSpeed = max(maxVisualSpeed, step * camera.zoom / CGFloat(self.frame))
            last = camera.center
        }
        XCTAssertLessThanOrEqual(maxVisualSpeed, FollowPreset.calm.maxVisualSpeed + 0.5)
        XCTAssertGreaterThan(maxVisualSpeed, 0)
        _ = t
    }

    func testFlungCursorComesBackIntoViewQuickly() {
        let camera = ZoomCamera(display: display)
        camera.zoomIn(to: 2, cursor: CGPoint(x: 400, y: 400), now: 0)
        var t = run(camera, cursor: CGPoint(x: 400, y: 400), from: 0, seconds: 1)
        let far = CGPoint(x: 2200, y: 1400)
        var last = camera.center
        var maxVisualSpeed: CGFloat = 0
        var visibleAfter: Double?
        let start = t
        t = run(camera, cursor: far, from: t, seconds: 4) { now in
            let step = hypot(camera.center.x - last.x, camera.center.y - last.y)
            maxVisualSpeed = max(maxVisualSpeed, step * camera.zoom / CGFloat(self.frame))
            last = camera.center
            if visibleAfter == nil, camera.viewport.contains(far) { visibleAfter = now - start }
        }
        let limit = FollowPreset.calm.maxVisualSpeed * camera.config.catchUpLimit
        XCTAssertLessThanOrEqual(maxVisualSpeed, limit + 0.5)
        // A jump across the whole display diagonal; without the boost this takes about 3 s.
        XCTAssertLessThan(try XCTUnwrap(visibleAfter), 1.5)
        // Ends up inside the safe zone, not just barely visible.
        let settled = ViewportMath.applySafeZone(center: camera.center, cursor: far, zoom: camera.zoom,
                                                 display: display, margin: FollowPreset.calm.margin)
        XCTAssertEqual(ViewportMath.clampCenter(settled, zoom: camera.zoom, display: display).x, camera.center.x, accuracy: 0.5)
    }

    func testFollowMakesOneDecisiveMoveThenRests() {
        let camera = ZoomCamera(display: display)
        let start = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: start, now: 0)
        var t = run(camera, cursor: start, from: 0, seconds: 1)
        // Viewport x 576...1728, calm safe zone x 864...1440. Cross it slightly to the right.
        let crossing = CGPoint(x: 1460, y: 768)
        var moving = 0
        var subPixelFrames = 0
        var last = camera.center
        t = run(camera, cursor: crossing, from: t, seconds: 4) { _ in
            let step = hypot(camera.center.x - last.x, camera.center.y - last.y) * camera.zoom
            if step > 0 { moving += 1 }
            if step > 0, step < 0.5 { subPixelFrames += 1 }
            last = camera.center
        }
        // No long tail of sub-pixel creeping (only the final landing frame may be shorter).
        XCTAssertLessThanOrEqual(subPixelFrames, 1)
        // The cursor now sits at the settle margin from the right edge, inside the safe zone.
        let vp = camera.viewport
        XCTAssertEqual((vp.maxX - crossing.x) / vp.width, FollowPreset.calm.settleMargin, accuracy: 0.01)
        // The camera came fully to rest (no sub-pixel creeping).
        XCTAssertLessThan(moving, 150)
        let rested = camera.center
        // Small wobbles near where the cursor is now do not move the camera again.
        for dx in [CGFloat(-60), 60, -30, 30] {
            t = run(camera, cursor: CGPoint(x: crossing.x + dx, y: 768), from: t, seconds: 0.3)
        }
        XCTAssertEqual(camera.center, rested)
    }

    func testPausedFollowHoldsTheCamera() {
        let camera = ZoomCamera(display: display)
        camera.zoomIn(to: 2, cursor: CGPoint(x: 1152, y: 768), now: 0)
        var t = run(camera, cursor: CGPoint(x: 1152, y: 768), from: 0, seconds: 1)
        let held = camera.center
        camera.followPaused = true
        t = run(camera, cursor: CGPoint(x: 1720, y: 1100), from: t, seconds: 1)
        XCTAssertEqual(camera.center, held)
        camera.followPaused = false
        _ = run(camera, cursor: CGPoint(x: 1720, y: 1100), from: t, seconds: 2)
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
            // A free-spinning wheel: several notches arriving during the transition.
            if (12...16).contains(i) { camera.adjustZoom(by: 1.1) }
            camera.update(cursor: cursor, now: t, dt: frame)
            maxStep = max(maxStep, abs(log(camera.zoom) - lastLog))
            lastLog = log(camera.zoom)
        }
        // No single frame zooms more than the eased transition itself does at its peak.
        XCTAssertLessThan(maxStep, 0.07)
        XCTAssertEqual(camera.zoom, 2 * pow(1.1, 5), accuracy: 1e-6)
    }

    func testCatchUpEndsWithoutAbruptBraking() {
        let camera = ZoomCamera(display: display)
        camera.zoomIn(to: 2, cursor: CGPoint(x: 400, y: 400), now: 0)
        var t = run(camera, cursor: CGPoint(x: 400, y: 400), from: 0, seconds: 1)
        var last = camera.center
        var lastSpeed: CGFloat = 0
        var maxDrop: CGFloat = 0
        t = run(camera, cursor: CGPoint(x: 2200, y: 1400), from: t, seconds: 4) { _ in
            let speed = hypot(camera.center.x - last.x, camera.center.y - last.y) * camera.zoom / CGFloat(self.frame)
            maxDrop = max(maxDrop, lastSpeed - speed)
            lastSpeed = speed
            last = camera.center
        }
        // Speed may fall at most ~150 pt/s from one frame to the next (no emergency stop).
        XCTAssertLessThan(maxDrop, 150)
        _ = t
    }

    func testWheelZoomLandsWithoutSubPixelTail() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        let t = run(camera, cursor: cursor, from: 0, seconds: 1)
        camera.adjustZoom(by: 1.1)
        var lastZoom = camera.zoom
        var tinyFrames = 0
        _ = run(camera, cursor: cursor, from: t, seconds: 2) { _ in
            // How far the far edge of the screen moved this frame, in points.
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
        var t = run(camera, cursor: cursor, from: 0, seconds: 1)
        camera.zoomOut(cursor: cursor, now: t)
        XCTAssertEqual(camera.phase, .zoomingOut)
        t = run(camera, cursor: cursor, from: t, seconds: 0.6) { _ in self.assertInsideDisplay(camera) }
        XCTAssertEqual(camera.phase, .idle)
        XCTAssertEqual(camera.zoom, 1)
        XCTAssertEqual(camera.center, CGPoint(x: display.width / 2, y: display.height / 2))
        XCTAssertEqual(camera.viewport, CGRect(origin: .zero, size: display))
    }

    func testReversingMidTransitionIsContinuous() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 700, y: 900)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        var t = run(camera, cursor: cursor, from: 0, seconds: 0.25)
        let zoomBefore = camera.zoom, centerBefore = camera.center
        camera.zoomOut(cursor: cursor, now: t)
        t += frame
        camera.update(cursor: cursor, now: t, dt: frame)
        XCTAssertEqual(camera.zoom, zoomBefore, accuracy: 0.01)
        XCTAssertEqual(camera.center.x, centerBefore.x, accuracy: 2)
        XCTAssertEqual(camera.center.y, centerBefore.y, accuracy: 2)
        _ = run(camera, cursor: cursor, from: t, seconds: 0.6)
        XCTAssertEqual(camera.phase, .idle)
    }

    func testWheelAdjustKeepsCursorContentFixed() {
        let camera = ZoomCamera(display: display)
        let cursor = CGPoint(x: 1152, y: 768)
        camera.zoomIn(to: 2, cursor: cursor, now: 0)
        var t = run(camera, cursor: cursor, from: 0, seconds: 1)
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
}

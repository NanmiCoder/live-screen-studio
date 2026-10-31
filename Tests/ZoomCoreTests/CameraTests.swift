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

    func testFollowIsSpeedLimitedAndEventuallyShowsCursor() {
        var config = ZoomCamera.Config()
        config.follow = .calm
        let camera = ZoomCamera(display: display, config: config)
        camera.zoomIn(to: 2, cursor: CGPoint(x: 400, y: 400), now: 0)
        var t = run(camera, cursor: CGPoint(x: 400, y: 400), from: 0, seconds: 1)
        let far = CGPoint(x: 2200, y: 1400)
        var last = camera.center
        var maxVisualSpeed: CGFloat = 0
        t = run(camera, cursor: far, from: t, seconds: 4) { _ in
            let step = hypot(camera.center.x - last.x, camera.center.y - last.y)
            maxVisualSpeed = max(maxVisualSpeed, step * camera.zoom / CGFloat(self.frame))
            last = camera.center
        }
        XCTAssertLessThanOrEqual(maxVisualSpeed, FollowPreset.calm.maxVisualSpeed + 0.5)
        XCTAssertGreaterThan(maxVisualSpeed, FollowPreset.calm.maxVisualSpeed * 0.5)
        XCTAssertTrue(camera.viewport.contains(far))
        _ = t
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
        camera.adjustZoom(by: 1.5, cursor: cursor)
        t = run(camera, cursor: cursor, from: t, seconds: 1) { _ in
            let p = camera.screenPoint(for: cursor)
            XCTAssertEqual(p.x, before.x, accuracy: 0.5)
            XCTAssertEqual(p.y, before.y, accuracy: 0.5)
        }
        XCTAssertEqual(camera.zoom, 3, accuracy: 1e-6)
        camera.adjustZoom(by: 10, cursor: cursor)
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

import CoreGraphics
import XCTest
@testable import CursorKit

final class CursorKitTests: XCTestCase {
    private func alpha(of image: CGImage, atPoint p: CGPoint, scale: CGFloat) -> UInt8 {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let x = Int(p.x * scale), y = Int(p.y * scale)
        // Bitmap rows start at the top for data access.
        let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return pixels[(y * image.width + x) * 4 + 3]
    }

    func testEveryCustomStyleRendersWithHotspotOnTheShape() throws {
        for style in CursorStyle.allCases where style != .system {
            let art = try XCTUnwrap(CursorArt.render(style, scale: 4), "\(style)")
            XCTAssertEqual(CGFloat(art.image.width), art.size.width * 4, accuracy: 1, "\(style)")
            XCTAssertTrue(CGRect(origin: .zero, size: art.size).contains(art.hotSpot), "\(style)")
            // Just inside the tip (or the centre of the dot) is painted.
            let probe = CGPoint(x: art.hotSpot.x + 1, y: art.hotSpot.y + 2.5)
            XCTAssertGreaterThan(alpha(of: art.image, atPoint: probe, scale: 4), 200, "\(style)")
            // The far corner stays transparent.
            XCTAssertEqual(alpha(of: art.image, atPoint: CGPoint(x: art.size.width - 0.3, y: 0.3), scale: 4), 0, "\(style)")
        }
        XCTAssertNil(CursorArt.render(.system, scale: 2))
    }

    func testMotionFollowsExactlyWithoutSmoothing() {
        var motion = CursorMotion(position: .zero, now: 0)
        motion.update(input: CGPoint(x: 300, y: 40), buttonsDown: false, now: 1.0 / 60, dt: 1.0 / 60)
        XCTAssertEqual(motion.position, CGPoint(x: 300, y: 40))
    }

    func testSmoothingTrailsThenSettlesWithoutOvershoot() {
        var motion = CursorMotion(position: .zero, now: 0)
        motion.smoothTime = 0.05
        let target = CGPoint(x: 200, y: 0)
        var t = 0.0
        motion.update(input: target, buttonsDown: false, now: t + 1.0 / 60, dt: 1.0 / 60)
        XCTAssertLessThan(motion.position.x, 200)
        for _ in 0..<60 {
            t += 1.0 / 60
            motion.update(input: target, buttonsDown: false, now: t, dt: 1.0 / 60)
            XCTAssertLessThanOrEqual(motion.position.x, 200)
        }
        XCTAssertEqual(motion.position.x, 200, accuracy: 0.5)
    }

    func testIdleCursorFadesOutAndReturnsOnMove() {
        var motion = CursorMotion(position: .zero, now: 0)
        motion.idleDelay = 2
        var t = 0.0
        while t < 3 {
            t += 1.0 / 60
            motion.update(input: .zero, buttonsDown: false, now: t, dt: 1.0 / 60)
            if t < 2 { XCTAssertEqual(motion.opacity, 1) }
        }
        XCTAssertEqual(motion.opacity, 0)
        for _ in 0..<10 {
            t += 1.0 / 60
            motion.update(input: CGPoint(x: 5, y: 5), buttonsDown: false, now: t, dt: 1.0 / 60)
        }
        XCTAssertEqual(motion.opacity, 1)
    }

    func testHoldingAButtonKeepsTheCursorVisible() {
        var motion = CursorMotion(position: .zero, now: 0)
        motion.idleDelay = 1
        var t = 0.0
        while t < 3 {
            t += 1.0 / 60
            motion.update(input: .zero, buttonsDown: true, now: t, dt: 1.0 / 60)
        }
        XCTAssertEqual(motion.opacity, 1)
    }

    func testClickEffectsGrowFadeAndEnd() {
        for effect in [ClickEffect.ripple, .halo] {
            var lastRadius: CGFloat = 0
            var lastOpacity: CGFloat = 1
            var age = 0.0
            while let look = effect.appearance(age: age) {
                XCTAssertGreaterThanOrEqual(look.radius, lastRadius)
                XCTAssertLessThanOrEqual(look.opacity, lastOpacity)
                lastRadius = look.radius
                lastOpacity = look.opacity
                age += 1.0 / 60
            }
            XCTAssertEqual(age, effect.duration, accuracy: 1.0 / 30)
        }
        XCTAssertNil(ClickEffect.none.appearance(age: 0))
    }
}

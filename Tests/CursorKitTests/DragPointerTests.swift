import CoreGraphics
import XCTest
@testable import CursorKit

final class DragPointerTests: XCTestCase {
    func testSwallowedSamplesMoveWithoutSystemCursorUpdates() {
        let start = CGPoint(x: 300, y: 200)
        var pointer = DragPointer(at: start, bounds: nil)
        let samples = [CGPoint(x: 302, y: 201), CGPoint(x: 320, y: 210), CGPoint(x: 370, y: 250)]
        for sample in samples {
            pointer.move(to: sample, bounds: nil)
            XCTAssertEqual(pointer.location, sample)
        }
        XCTAssertNotEqual(pointer.location, start)
    }

    func testDraggingPastAnEdgeDoesNotDelayReversingDirection() {
        let bounds = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        var pointer = DragPointer(at: CGPoint(x: -10, y: -10), bounds: bounds)
        pointer.move(to: CGPoint(x: 50, y: 80), bounds: bounds)
        XCTAssertEqual(pointer.location, .zero)
        pointer.move(to: CGPoint(x: 150, y: 180), bounds: bounds)
        XCTAssertEqual(pointer.location, .zero)
        pointer.move(to: CGPoint(x: 147, y: 176), bounds: bounds)
        XCTAssertEqual(pointer.location, CGPoint(x: -3, y: -4))
    }

    func testAllEdgesKeepThePenOnItsDisplay() {
        let bounds = CGRect(x: 1920, y: -1080, width: 1920, height: 1080)
        for sample in [CGPoint(x: 5000, y: 100), CGPoint(x: 1800, y: -1200)] {
            var pointer = DragPointer(at: CGPoint(x: 3000, y: -500), bounds: bounds)
            pointer.move(to: sample, bounds: bounds)
            XCTAssertGreaterThanOrEqual(pointer.location.x, bounds.minX)
            XCTAssertLessThanOrEqual(pointer.location.x, bounds.maxX)
            XCTAssertGreaterThanOrEqual(pointer.location.y, bounds.minY)
            XCTAssertLessThanOrEqual(pointer.location.y, bounds.maxY)
        }
    }

    func testRepeatedSamplesAndANewGestureDoNotReuseOldMovement() {
        let start = CGPoint(x: -500, y: 200)
        var pointer = DragPointer(at: start, bounds: nil)
        pointer.move(to: CGPoint(x: -400, y: 300), bounds: nil)
        pointer.move(to: CGPoint(x: -400, y: 300), bounds: nil)
        XCTAssertEqual(pointer.location, CGPoint(x: -400, y: 300))
        pointer = DragPointer(at: start, bounds: nil)
        pointer.move(to: CGPoint(x: -499, y: 198), bounds: nil)
        XCTAssertEqual(pointer.location, CGPoint(x: -499, y: 198))
    }

    func testPressOutsideBoundsCanMoveBackImmediately() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        var pointer = DragPointer(at: CGPoint(x: 103, y: 50), bounds: bounds)
        XCTAssertEqual(pointer.location, CGPoint(x: 100, y: 50))
        pointer.move(to: CGPoint(x: 102, y: 50), bounds: bounds)
        XCTAssertEqual(pointer.location, CGPoint(x: 99, y: 50))
    }
}

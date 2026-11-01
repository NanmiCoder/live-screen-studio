import CoreGraphics
import XCTest
@testable import CursorKit

final class AnnotationTests: XCTestCase {
    // Rows as the text recognizer reports them for a terminal (y down): one row split at a few spaces,
    // another row right below it, and a second column far to the right.
    private let segments = [
        CGRect(x: 40, y: 100, width: 600, height: 30),
        CGRect(x: 680, y: 101, width: 320, height: 29),
        CGRect(x: 40, y: 140, width: 900, height: 30),
        CGRect(x: 1600, y: 100, width: 400, height: 30),
    ]

    func testLineJoinsSegmentsOfTheRowAndStopsAtAWideGap() throws {
        let line = try XCTUnwrap(TextLines.line(at: CGPoint(x: 300, y: 115), in: segments))
        XCTAssertEqual(line, CGRect(x: 40, y: 100, width: 960, height: 30))
    }

    func testPointerAfterTheEndOfALineStillPicksIt() throws {
        let line = try XCTUnwrap(TextLines.line(at: CGPoint(x: 1050, y: 112), in: segments))
        XCTAssertEqual(line.minY, 100)
        XCTAssertEqual(line.maxX, 1000)
    }

    func testBetweenTwoRowsPicksTheNearerOne() throws {
        // 132 is 2 below the first row and 8 above the second.
        let line = try XCTUnwrap(TextLines.line(at: CGPoint(x: 300, y: 132), in: segments))
        XCTAssertEqual(line.minY, 100)
    }

    func testARowEndingShortOfThePointDoesNotHideTheRowUnderIt() throws {
        // The point sits on the bottom edge of a short row that ends far to its left, and just above a row that
        // runs under it: the row under it is the one meant.
        let rows = [CGRect(x: 137, y: 192, width: 140, height: 17), CGRect(x: 128, y: 213, width: 753, height: 21)]
        let line = try XCTUnwrap(TextLines.line(at: CGPoint(x: 518, y: 209), in: rows))
        XCTAssertEqual(line.minY, 213)
    }

    func testLineNumbersBetweenTwoPanesDoNotJoinThem() throws {
        // Left pane text, then the right pane's line number in smaller type, then the right pane's code.
        let row = [CGRect(x: 128, y: 213, width: 753, height: 21), CGRect(x: 913, y: 215, width: 10, height: 13),
                   CGRect(x: 947, y: 213, width: 373, height: 17)]
        let line = try XCTUnwrap(TextLines.line(at: CGPoint(x: 518, y: 220), in: row))
        XCTAssertEqual(line, row[0])
    }

    func testNoLineAwayFromText() {
        XCTAssertNil(TextLines.line(at: CGPoint(x: 300, y: 260), in: segments))
        XCTAssertNil(TextLines.line(at: CGPoint(x: 1300, y: 115), in: segments))
        XCTAssertNil(TextLines.line(at: CGPoint(x: 300, y: 115), in: []))
    }

    func testArrowHeadPointsAlongTheEndOfTheStroke() throws {
        let points = (0...20).map { CGPoint(x: CGFloat($0) * 10, y: 50) }
        let (a, b) = try XCTUnwrap(ArrowHead.barbs(for: points, length: 20))
        // Both barbs trail behind the tip (200, 50), one on each side.
        XCTAssertLessThan(a.x, 200)
        XCTAssertLessThan(b.x, 200)
        XCTAssertEqual(a.y - 50, -(b.y - 50), accuracy: 0.001)
        XCTAssertEqual(hypot(a.x - 200, a.y - 50), 20, accuracy: 0.001)
    }

    func testArrowHeadIgnoresJitterAtTheTip() throws {
        // A long stroke to the right ending in a 2 pt wobble upward.
        var points = (0...20).map { CGPoint(x: CGFloat($0) * 10, y: 50) }
        points.append(CGPoint(x: 200, y: 48))
        let (a, b) = try XCTUnwrap(ArrowHead.barbs(for: points, length: 24))
        XCTAssertLessThan(max(a.x, b.x), 200)
    }

    func testNoArrowHeadForADot() {
        XCTAssertNil(ArrowHead.barbs(for: [CGPoint(x: 5, y: 5)], length: 20))
        XCTAssertNil(ArrowHead.barbs(for: [CGPoint(x: 5, y: 5), CGPoint(x: 6, y: 5)], length: 20))
    }
}

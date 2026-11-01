import CoreGraphics
import Foundation

/// How strokes drawn while zoomed in look.
public enum InkStyle: String, CaseIterable, Sendable {
    case marker
    case neon
    case highlighter
    case arrow
    case dashed

    public var title: String {
        switch self {
        case .marker: "马克笔"
        case .neon: "霓虹"
        case .highlighter: "荧光笔"
        case .arrow: "箭头"
        case .dashed: "流动虚线"
        }
    }
}

/// Marks placed with a shortcut on the line of text under the cursor.
public enum HighlightKind: String, CaseIterable, Sendable {
    case box
    case underline
    case fill
    case spotlight

    public var title: String {
        switch self {
        case .box: "框住这一行"
        case .underline: "给这一行划线"
        case .fill: "荧光笔涂这一行"
        case .spotlight: "聚光灯"
        }
    }
}

public enum TextLines {
    /// The line of text at `point`, built from text segments found on screen (same coordinates, y down): the
    /// segment under the point plus neighbours on the same row in the same size of type, so words the text
    /// recognizer split at a few spaces still make one line, while a narrower column next to it (line numbers,
    /// another pane) is left out. Nil when the point is not on a line of text.
    public static func line(at point: CGPoint, in segments: [CGRect]) -> CGRect? {
        // Segments the point is on or close to: pointing just below or between lines still counts, and so does
        // pointing a little past the end of a line. Of those, the nearest row wins.
        let near = segments.filter {
            point.y >= $0.minY - $0.height * 0.8 && point.y <= $0.maxY + $0.height * 0.8
                && horizontalGap(point, $0) <= $0.height * 4
        }
        guard let seed = near.min(by: { score(point, $0) < score(point, $1) }) else { return nil }
        var line = seed
        var rest = segments.filter {
            $0 != seed && verticalOverlap($0, seed) >= 0.5 * min($0.height, seed.height)
                && min($0.height, seed.height) >= 0.7 * max($0.height, seed.height)
        }
        var grew = true
        while grew {
            grew = false
            for index in rest.indices.reversed() {
                let r = rest[index]
                let gap = max(r.minX - line.maxX, line.minX - r.maxX, 0)
                if gap <= seed.height * 1.5 {
                    line = line.union(r)
                    rest.remove(at: index)
                    grew = true
                }
            }
        }
        return line
    }

    /// Prefers the row the point is inside of, then the segment closest to it horizontally.
    private static func score(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let vertical = max(r.minY - p.y, p.y - r.maxY, 0)
        return vertical * 1000 + horizontalGap(p, r)
    }

    private static func horizontalGap(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        max(r.minX - p.x, p.x - r.maxX, 0)
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(min(a.maxY, b.maxY) - max(a.minY, b.minY), 0)
    }
}

public enum ArrowHead {
    /// The two barb ends of an arrowhead at the last point of a stroke, pointing along its last `length` or so,
    /// so a little jitter at the end of the stroke does not swing the head around. Nil for a stroke that is
    /// still too short to have a direction.
    public static func barbs(for points: [CGPoint], length: CGFloat, angle: CGFloat = .pi / 6.5) -> (CGPoint, CGPoint)? {
        guard let tip = points.last, points.count >= 2 else { return nil }
        // Walk back from the tip until the stroke has covered about the head's length.
        var back = points[points.count - 2]
        for p in points.dropLast().reversed() {
            back = p
            if hypot(tip.x - p.x, tip.y - p.y) >= length { break }
        }
        let dx = tip.x - back.x, dy = tip.y - back.y
        let distance = hypot(dx, dy)
        guard distance >= length * 0.25 else { return nil }
        let heading = atan2(dy, dx)
        func barb(_ side: CGFloat) -> CGPoint {
            let a = heading + .pi + side * angle
            return CGPoint(x: tip.x + cos(a) * length, y: tip.y + sin(a) * length)
        }
        return (barb(1), barb(-1))
    }
}

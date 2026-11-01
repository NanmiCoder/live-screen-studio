import AppKit
import CursorKit
import QuartzCore

/// How LiveZoom's ink looks: the style of strokes, the color and the width on screen when drawn.
struct InkLook {
    var style: InkStyle
    var color: NSColor
    var width: CGFloat
}

/// One stroke or highlight on the zoomed display. Its layers use display-local content points (y down), so they
/// move and scale with the zoomed content; line widths are fixed for the zoom it was made at.
final class Annotation {
    let layer = CALayer()
    let isSpotlight: Bool
    private let look: InkLook
    /// Content points per screen point when it was made.
    private let unit: CGFloat
    private var points: [CGPoint] = []
    private var lines: [CAShapeLayer] = []
    private var head: CAShapeLayer?

    /// A freehand stroke, extended with `extend(to:straight:)`.
    init(strokeFrom start: CGPoint, look: InkLook, zoom: CGFloat) {
        self.look = look
        unit = 1 / zoom
        isSpotlight = false
        lines = Self.lineLayers(look.style, look.color, width: look.width * unit)
        lines.forEach(layer.addSublayer)
        if look.style == .arrow {
            let head = Self.shape(width: look.width * unit, color: look.color)
            layer.addSublayer(head)
            self.head = head
        }
        points = [start]
        updatePath()
    }

    func extend(to p: CGPoint, straight: Bool) {
        if straight {
            points = [points[0], p]
        } else if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 0.75 * unit {
            points.append(p)
        } else {
            return
        }
        updatePath()
    }

    /// A highlight on `line`, the bounds of a line of text; `display` is the size of the content, which the
    /// spotlight dims.
    init(highlight kind: HighlightKind, line: CGRect, display: CGSize, look: InkLook, zoom: CGFloat) {
        self.look = look
        unit = 1 / zoom
        isSpotlight = kind == .spotlight
        let h = line.height
        // Close around the text, so the box stays clear of the lines above and below.
        let around = line.insetBy(dx: -h * 0.35, dy: -h * 0.12)
        let corner = min(around.height * 0.25, 8 * unit)
        // Boxes and underlines take the stroke style where it fits a line (neon, dashes); otherwise a plain line.
        let lineStyle: InkStyle = [.neon, .dashed].contains(look.style) ? look.style : .marker
        // Thinner than a stroke: a line of text is small, and a heavy outline (or neon glow) would cover its
        // neighbours.
        let width = max(look.width * 0.45, 2) * unit

        switch kind {
        case .box:
            let path = CGPath(roundedRect: around, cornerWidth: corner, cornerHeight: corner, transform: nil)
            lines = Self.lineLayers(lineStyle, look.color, width: width)
            lines.forEach { $0.path = path; layer.addSublayer($0) }
            Self.drawOn(lines, duration: 0.45)
        case .underline:
            let y = line.maxY + h * 0.18
            let path = CGMutablePath()
            path.move(to: CGPoint(x: line.minX, y: y))
            path.addLine(to: CGPoint(x: line.maxX, y: y))
            lines = Self.lineLayers(lineStyle, look.color, width: width)
            lines.forEach { $0.path = path; layer.addSublayer($0) }
            Self.drawOn(lines, duration: 0.35)
        case .fill:
            // A highlighter pass as tall as the line, left to right.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: line.minX - h * 0.15, y: line.midY))
            path.addLine(to: CGPoint(x: line.maxX + h * 0.15, y: line.midY))
            let pass = Self.shape(width: h * 1.25, color: look.color.withAlphaComponent(0.35), cap: .butt)
            pass.path = path
            lines = [pass]
            layer.addSublayer(pass)
            Self.drawOn(lines, duration: 0.35)
        case .spotlight:
            let hole = CGPath(roundedRect: around, cornerWidth: corner, cornerHeight: corner, transform: nil)
            let dim = CAShapeLayer()
            let path = CGMutablePath()
            // Well past the display, so no edge shows however the content is zoomed.
            path.addRect(CGRect(origin: .zero, size: display).insetBy(dx: -display.width, dy: -display.height))
            path.addPath(hole)
            dim.path = path
            dim.fillRule = .evenOdd
            dim.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
            let edge = Self.shape(width: 1.5 * unit, color: look.color.withAlphaComponent(0.85))
            edge.path = hole
            layer.addSublayer(dim)
            layer.addSublayer(edge)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            layer.add(fade, forKey: "fadeIn")
        }
    }

    private func updatePath() {
        let path = Self.smoothPath(points)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for line in lines { line.path = path }
        if let head {
            let length = max(look.width * 3.2, 14) * unit
            if let (a, b) = ArrowHead.barbs(for: points, length: length), let tip = points.last {
                let chevron = CGMutablePath()
                chevron.move(to: a)
                chevron.addLine(to: tip)
                chevron.addLine(to: b)
                head.path = chevron
            } else {
                head.path = nil
            }
        }
        CATransaction.commit()
    }

    // MARK: - Layers

    private static func shape(width: CGFloat, color: NSColor, cap: CAShapeLayerLineCap = .round) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = width
        shape.lineCap = cap
        shape.lineJoin = .round
        return shape
    }

    /// The layers a line is drawn with, all sharing one path.
    private static func lineLayers(_ style: InkStyle, _ color: NSColor, width w: CGFloat) -> [CAShapeLayer] {
        switch style {
        case .marker, .arrow:
            return [shape(width: w, color: color)]
        case .neon:
            // Soft glow around a bright core.
            let core = color.blended(withFraction: 0.7, of: .white) ?? .white
            return [shape(width: w * 3.6, color: color.withAlphaComponent(0.14)),
                    shape(width: w * 2, color: color.withAlphaComponent(0.32)),
                    shape(width: w, color: color),
                    shape(width: w * 0.38, color: core)]
        case .highlighter:
            return [shape(width: w * 3.6, color: color.withAlphaComponent(0.38), cap: .butt)]
        case .dashed:
            let dashes = shape(width: w, color: color)
            dashes.lineDashPattern = [NSNumber(value: Double(w * 2.4)), NSNumber(value: Double(w * 2.2))]
            let march = CABasicAnimation(keyPath: "lineDashPhase")
            march.fromValue = 0
            march.toValue = -w * 4.6
            march.duration = 0.6
            march.repeatCount = .infinity
            dashes.add(march, forKey: "march")
            return [dashes]
        }
    }

    private static func drawOn(_ shapes: [CAShapeLayer], duration: Double) {
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for shape in shapes { shape.add(animation, forKey: "drawOn") }
    }

    /// Quadratic curves through the midpoints, so mouse samples read as a smooth pen line.
    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            // A single point still shows as a dot.
            path.addLine(to: points.count == 2 ? points[1] : CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

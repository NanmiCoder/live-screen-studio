import CoreGraphics
import Foundation

public struct CursorImage {
    public let image: CGImage
    /// In points at 1× cursor size.
    public let size: CGSize
    /// From the top-left corner, in points.
    public let hotSpot: CGPoint

    public init(image: CGImage, size: CGSize, hotSpot: CGPoint) {
        self.image = image
        self.size = size
        self.hotSpot = hotSpot
    }
}

/// Vector drawings for the custom cursor styles.
public enum CursorArt {
    /// Renders `style` at `scale` pixels per point; nil for `.system`, which uses the real cursor image.
    public static func render(_ style: CursorStyle, scale: CGFloat) -> CursorImage? {
        switch style {
        case .system:
            return nil
        case .classic:
            return draw(padding: 5, content: CGSize(width: 12, height: 19.5), scale: scale) { ctx in
                shape(ctx, arrow, fill: .solid(rgb(0.07, 0.07, 0.08)), stroke: rgb(1, 1, 1), lineWidth: 1.5, scale: scale)
            }
        case .light:
            return draw(padding: 5, content: CGSize(width: 12, height: 19.5), scale: scale) { ctx in
                shape(ctx, arrow, fill: .solid(rgb(1, 1, 1)), stroke: rgb(0.1, 0.1, 0.12), lineWidth: 1.2, scale: scale)
            }
        case .ocean:
            return draw(padding: 5, content: CGSize(width: 12, height: 19.5), scale: scale) { ctx in
                shape(ctx, arrow, fill: .gradient(rgb(0.18, 0.5, 0.93), rgb(0.34, 0.8, 0.95)), stroke: rgb(1, 1, 1),
                      lineWidth: 1.6, scale: scale)
            }
        case .sunset:
            return draw(padding: 5, content: CGSize(width: 12, height: 19.5), scale: scale) { ctx in
                shape(ctx, arrow, fill: .gradient(rgb(1, 0.48, 0.09), rgb(1, 0.24, 0.47)), stroke: rgb(1, 1, 1),
                      lineWidth: 1.6, scale: scale)
            }
        case .mint:
            return draw(padding: 5, content: CGSize(width: 11, height: 15.5), scale: scale) { ctx in
                shape(ctx, pointer, fill: .gradient(rgb(0, 0.72, 0.58), rgb(0.33, 0.94, 0.77)), stroke: rgb(1, 1, 1),
                      lineWidth: 1.6, scale: scale)
            }
        case .dot:
            let r: CGFloat = 7.5
            let image = draw(padding: 5, content: CGSize(width: r * 2, height: r * 2), scale: scale) { ctx in
                let circle = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: r * 2, height: r * 2), transform: nil)
                shape(ctx, circle, fill: .solid(rgb(0.1, 0.1, 0.12, 0.88)), stroke: rgb(1, 1, 1), lineWidth: 2, scale: scale)
            }
            // The click point is the centre of the dot.
            return image.map { CursorImage(image: $0.image, size: $0.size, hotSpot: CGPoint(x: 5 + r, y: 5 + r)) }
        case .spotlight:
            let halo: CGFloat = 17
            return draw(padding: halo, content: CGSize(width: 12, height: 19.5), scale: scale) { ctx in
                ctx.setFillColor(rgb(1, 0.84, 0.04, 0.42))
                ctx.fillEllipse(in: CGRect(x: -halo, y: -halo, width: halo * 2, height: halo * 2))
                shape(ctx, arrow, fill: .solid(rgb(0.07, 0.07, 0.08)), stroke: rgb(1, 1, 1), lineWidth: 1.5, scale: scale)
            }
        }
    }

    // MARK: - Shapes (points, tip at the origin, y down)

    static let arrow: CGPath = {
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 3.9, y: 12.8), CGPoint(x: 6.6, y: 19.0),
            CGPoint(x: 9.3, y: 17.8), CGPoint(x: 6.7, y: 11.8), CGPoint(x: 11.8, y: 11.8),
        ])
        path.closeSubpath()
        return path
    }()

    /// Rounded triangle pointer.
    static let pointer: CGPath = roundedPolygon(
        [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15.5), CGPoint(x: 4.4, y: 11.4), CGPoint(x: 10.9, y: 11.4)],
        radius: 1.4
    )

    // MARK: - Drawing

    private enum Fill {
        case solid(CGColor)
        case gradient(CGColor, CGColor)
    }

    /// Creates a canvas with `padding` around `content`, origin moved to the content's top-left (the hotspot).
    private static func draw(padding: CGFloat, content: CGSize, scale: CGFloat,
                             _ body: (CGContext) -> Void) -> CursorImage? {
        let size = CGSize(width: content.width + padding * 2, height: content.height + padding * 2)
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: padding, y: padding)
        body(ctx)
        guard let image = ctx.makeImage() else { return nil }
        return CursorImage(image: image, size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale),
                           hotSpot: CGPoint(x: padding, y: padding))
    }

    private static func shape(_ ctx: CGContext, _ path: CGPath, fill: Fill, stroke: CGColor, lineWidth: CGFloat,
                              scale: CGFloat) {
        ctx.saveGState()
        // Shadow offsets are in device space, where y points up.
        ctx.setShadow(offset: CGSize(width: 0, height: -1.1 * scale), blur: 2.6 * scale, color: rgb(0, 0, 0, 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(lineWidth * 2)
        ctx.setStrokeColor(stroke)
        ctx.addPath(path)
        ctx.strokePath()
        switch fill {
        case .solid(let color):
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath()
        case .gradient(let from, let to):
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let box = path.boundingBox
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from, to] as CFArray,
                                         locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.minY),
                                       end: CGPoint(x: box.maxX, y: box.maxY), options: [])
            }
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        let mid = { (a: CGPoint, b: CGPoint) in CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[n - 1], points[0]))
        for i in 0..<n {
            path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius)
        }
        path.closeSubpath()
        return path
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

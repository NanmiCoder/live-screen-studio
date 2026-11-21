import AppKit
import CursorKit
import QuartzCore

/// Unified, click-through overlay window for one display: renders the zoomed GPU surface, annotation strokes,
/// click marks and cursor inside ONE `NSWindow` / `CAContext` so every layer commits atomically with zero tearing.
/// OBS display capture picks it up like any other window.
final class CursorCanvasWindow: NSWindow {
    struct Mark {
        /// Display-local, top-left origin.
        let center: CGPoint
        let look: ClickAppearance
        let color: NSColor
    }

    private let zoomSurface: ZoomSurfaceRenderer
    private let cursorLayer = CALayer()
    private let marksLayer = CALayer()
    /// Annotation strokes in display-local content points (y down); `setStrokeTransform` maps them on screen.
    let strokesLayer = CALayer()
    private var markLayers: [CAShapeLayer] = []
    private let displayHeight: CGFloat

    init(screen: NSScreen) {
        displayHeight = screen.frame.height
        zoomSurface = ZoomSurfaceRenderer(screen: screen)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = CALayer()
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.layer = root
        view.wantsLayer = true
        contentView = view
        marksLayer.frame = view.bounds
        strokesLayer.anchorPoint = .zero
        strokesLayer.frame = view.bounds
        cursorLayer.contentsGravity = .resize
        cursorLayer.minificationFilter = .linear
        cursorLayer.magnificationFilter = .linear
        cursorLayer.isHidden = true
        root.addSublayer(zoomSurface.layer)
        root.addSublayer(strokesLayer)
        root.addSublayer(marksLayer)
        root.addSublayer(cursorLayer)
        setFrame(screen.frame, display: false)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Renders the zoomed surface inside this window's single `CATransaction`.
    func renderZoom(surface: IOSurface?, sequence: Int, viewport: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomSurface.render(surface: surface, sequence: sequence, viewport: viewport)
        CATransaction.commit()
    }

    /// Hides the zoomed surface and releases any retained IOSurface / MTLTexture.
    func clearZoom() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomSurface.clear()
        CATransaction.commit()
    }

    /// Content point p appears at (p - origin) * zoom on screen; layer space has y up.
    func setStrokeTransform(origin: CGPoint, zoom: CGFloat) {
        let transform = CGAffineTransform(a: zoom, b: 0, c: 0, d: -zoom, tx: -zoom * origin.x,
                                          ty: displayHeight + zoom * origin.y)
        guard CATransform3DGetAffineTransform(strokesLayer.sublayerTransform) != transform else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokesLayer.sublayerTransform = CATransform3DMakeAffineTransform(transform)
        CATransaction.commit()
    }

    private var lastCursor: (image: CGImage?, frame: CGRect?, opacity: CGFloat)?
    private var hadMarks = false

    /// - Parameter cursorFrame: Top-left origin, display-local; nil hides the cursor on this display.
    func render(cursorImage: CGImage?, cursorFrame: CGRect?, opacity: CGFloat, marks: [Mark]) {
        // Commit only when something changed, so an idle cursor costs the compositor nothing.
        if marks.isEmpty, !hadMarks, let last = lastCursor, last.image === cursorImage, last.frame == cursorFrame,
           last.opacity == opacity {
            return
        }
        lastCursor = (cursorImage, cursorFrame, opacity)
        hadMarks = !marks.isEmpty
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let cursorImage, let cursorFrame, opacity > 0 {
            if (cursorLayer.contents as AnyObject?) !== cursorImage { cursorLayer.contents = cursorImage }
            cursorLayer.frame = CGRect(x: cursorFrame.minX, y: displayHeight - cursorFrame.maxY,
                                       width: cursorFrame.width, height: cursorFrame.height)
            cursorLayer.opacity = Float(opacity)
            cursorLayer.isHidden = false
        } else {
            cursorLayer.isHidden = true
        }

        while markLayers.count < marks.count {
            let layer = CAShapeLayer()
            marksLayer.addSublayer(layer)
            markLayers.append(layer)
        }
        for (index, layer) in markLayers.enumerated() {
            guard index < marks.count else {
                layer.isHidden = true
                continue
            }
            let mark = marks[index]
            let r = mark.look.radius
            let center = CGPoint(x: mark.center.x, y: displayHeight - mark.center.y)
            layer.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2),
                                transform: nil)
            let color = mark.color.withAlphaComponent(mark.look.opacity).cgColor
            layer.fillColor = mark.look.filled ? color : nil
            layer.strokeColor = mark.look.filled ? nil : color
            layer.lineWidth = mark.look.lineWidth
            layer.isHidden = false
        }
        CATransaction.commit()
    }
}

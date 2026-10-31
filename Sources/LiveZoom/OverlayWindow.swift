import AppKit
import QuartzCore

/// Full-screen, click-through window showing the zoomed capture and a redrawn cursor.
/// It stays capturable, so OBS display capture picks it up like any other window.
final class OverlayWindow: NSWindow {
    private let imageLayer = CALayer()
    private let cursorLayer = CALayer()
    private let displaySize: CGSize

    init(screen: NSScreen) {
        displaySize = screen.frame.size
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        let view = NSView(frame: CGRect(origin: .zero, size: displaySize))
        view.layer = root
        view.wantsLayer = true
        contentView = view

        imageLayer.frame = CGRect(origin: .zero, size: displaySize)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        cursorLayer.contentsGravity = .resize
        cursorLayer.minificationFilter = .trilinear
        cursorLayer.magnificationFilter = .linear
        root.addSublayer(imageLayer)
        root.addSublayer(cursorLayer)
        setFrame(screen.frame, display: false)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// - Parameters:
    ///   - viewport: Visible part of the display, top-left origin, in points.
    ///   - cursorFrame: Where to draw the cursor on the overlay, top-left origin; nil hides it.
    func render(surface: IOSurface?, viewport: CGRect, cursorImage: CGImage?, cursorFrame: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface, (imageLayer.contents as AnyObject?) !== surface {
            imageLayer.contents = surface
        }
        // contentsRect uses a bottom-left origin.
        imageLayer.contentsRect = CGRect(
            x: viewport.minX / displaySize.width,
            y: 1 - viewport.maxY / displaySize.height,
            width: viewport.width / displaySize.width,
            height: viewport.height / displaySize.height
        )
        if let cursorImage, let cursorFrame {
            if (cursorLayer.contents as AnyObject?) !== cursorImage { cursorLayer.contents = cursorImage }
            cursorLayer.frame = CGRect(x: cursorFrame.minX, y: displaySize.height - cursorFrame.maxY,
                                       width: cursorFrame.width, height: cursorFrame.height)
            cursorLayer.isHidden = false
        } else {
            cursorLayer.isHidden = true
        }
        CATransaction.commit()
    }
}

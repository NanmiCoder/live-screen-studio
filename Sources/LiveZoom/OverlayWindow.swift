import AppKit
import QuartzCore

/// Full-screen, click-through window showing the zoomed capture.
/// It stays capturable, so OBS display capture picks it up like any other window.
final class OverlayWindow: NSWindow {
    private let imageLayer = CALayer()
    private let displaySize: CGSize

    init(screen: NSScreen) {
        displaySize = screen.frame.size
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .black
        // macOS can mark windows below a fully opaque window as occluded (seen for windows of the same app), and
        // occluded browsers stop painting, which would stall the zoomed view. 99.9% opacity rules that out.
        isOpaque = false
        alphaValue = 0.999
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
        root.addSublayer(imageLayer)
        setFrame(screen.frame, display: false)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
    }

    /// - Parameter viewport: Visible part of the display, top-left origin, in points.
    func render(surface: IOSurface?, viewport: CGRect) {
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
        CATransaction.commit()
    }
}

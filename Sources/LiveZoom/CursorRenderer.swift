import AppKit

/// The real system cursor: hides it (also from the background) and reports what it currently looks like.
final class CursorRenderer {
    enum Kind {
        case arrow, pointingHand, other
    }

    struct Snapshot {
        let image: CGImage
        /// In points, at 1×.
        let size: CGSize
        /// From the top-left corner, in points.
        let hotSpot: CGPoint
        let kind: Kind
    }

    /// Whether LiveZoom wants the system cursor hidden; see `enforceHidden()`.
    private(set) var isSystemCursorHidden = false
    /// True while the system cursor stays visible despite hiding it (the Dock takes over the cursor while the
    /// pointer is over it). The drawn cursor steps aside then, so there is never a second cursor. Measured in
    /// time rather than frames: a hide takes a moment to show, and frames are only 8 ms apart at 120 Hz.
    var isRevealed: Bool {
        guard let visibleSince else { return false }
        return CACurrentMediaTime() - visibleSince >= 0.025
    }
    private var visibleSince: CFTimeInterval?
    private var revealLogged = false
    private var lastHideAttempt: CFTimeInterval = 0
    private(set) var snapshot: Snapshot?
    private var fingerprint: Int?
    private let arrowFingerprint: Int?
    private let pointingHandFingerprint: Int?

    init() {
        Self.allowCursorControlInBackground()
        arrowFingerprint = Self.largestImage(of: NSCursor.arrow).map { Self.fingerprint(of: $0, hotSpot: NSCursor.arrow.hotSpot) }
        pointingHandFingerprint = Self.largestImage(of: NSCursor.pointingHand)
            .map { Self.fingerprint(of: $0, hotSpot: NSCursor.pointingHand.hotSpot) }
    }

    func hideSystemCursor() {
        isSystemCursorHidden = true
        enforceHidden()
    }

    /// Hides the cursor again if something revealed it: macOS resets a background app's hide state, e.g. once
    /// the pointer has been over the Dock. Runs every frame; the visibility check is a shared-memory read.
    func enforceHidden() {
        guard isSystemCursorHidden, Self.cursorIsVisible() else {
            visibleSince = nil
            revealLogged = false
            return
        }
        let now = CACurrentMediaTime()
        if visibleSince == nil { visibleSince = now }
        revealedFrames += 1
        if isRevealed, !revealLogged {
            revealLogged = true
            log("system cursor cannot be hidden here; showing it instead of ours")
        }
        // Re-hide at once; only back off when it keeps failing (over the Dock).
        guard !isRevealed || now - lastHideAttempt > 0.1 else { return }
        lastHideAttempt = now
        CGDisplayHideCursor(CGMainDisplayID())
    }

    /// Diagnostics: frames in which the system cursor was visible although it should have been hidden.
    private(set) var revealedFrames = 0

    /// Changes whenever the cursor the system shows changes (another app set an I-beam, a hand, …).
    /// Reading it is cheap, so it tells when to re-read the image and re-hide without polling the image itself.
    static let cursorSeed: (() -> Int32)? = {
        typealias Fn = @convention(c) () -> Int32
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGSCurrentCursorSeed") else { return nil }
        let fn = unsafeBitCast(symbol, to: Fn.self)
        return { fn() }
    }()

    func showSystemCursor() {
        guard isSystemCursorHidden else { return }
        isSystemCursorHidden = false
        visibleSince = nil
        // Hide calls are counted (extra shows clamp at zero), so show until it is visible again.
        for _ in 0..<512 where !Self.cursorIsVisible() {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    /// Shows the system cursor no matter what this instance believes; safe from any thread. Used when the main
    /// thread hangs, so the user is never left without a cursor. The next frame hides it again if appropriate.
    static func forceShowSystemCursor() {
        for _ in 0..<512 where !cursorIsVisible() {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    /// CGCursorIsVisible is unavailable to Swift but still exported and accurate.
    private static let cursorIsVisible: () -> Bool = {
        typealias Fn = @convention(c) () -> Int32
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGCursorIsVisible") else { return { true } }
        let fn = unsafeBitCast(symbol, to: Fn.self)
        return { fn() != 0 }
    }()

    /// Re-reads the system cursor (arrow, I-beam, hand, …) and keeps the snapshot current.
    func refresh() {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        guard let image = Self.largestImage(of: cursor) else { return }
        let key = Self.fingerprint(of: image, hotSpot: cursor.hotSpot)
        guard key != fingerprint else { return }
        let kind: Kind = key == arrowFingerprint ? .arrow : key == pointingHandFingerprint ? .pointingHand : .other
        snapshot = Snapshot(image: image, size: cursor.image.size, hotSpot: cursor.hotSpot, kind: kind)
        fingerprint = key
    }

    /// The largest representation stays sharp when the cursor is drawn zoomed in.
    private static func largestImage(of cursor: NSCursor) -> CGImage? {
        guard let rep = cursor.image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        return rep.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Hash of the rendered pixels: tells apart cursors that share a size and hotspot (arrow vs. copy-arrow).
    private static func fingerprint(of image: CGImage, hotSpot: CGPoint) -> Int {
        var hasher = Hasher()
        hasher.combine(hotSpot.x)
        hasher.combine(hotSpot.y)
        hasher.combine(image.width)
        hasher.combine(image.height)
        if let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                               bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let data = ctx.data {
                hasher.combine(bytes: UnsafeRawBufferPointer(start: data, count: image.width * image.height * 4))
            }
        }
        return hasher.finalize()
    }

    /// CGDisplayHideCursor only works for the frontmost app unless this connection property is set.
    private static func allowCursorControlInBackground() {
        typealias MainConnectionFn = @convention(c) () -> Int32
        typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = dlopen(nil, RTLD_NOW)
        guard let connectionSymbol = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty") else {
            log("background cursor control unavailable")
            return
        }
        let connection = unsafeBitCast(connectionSymbol, to: MainConnectionFn.self)()
        let result = unsafeBitCast(setSymbol, to: SetPropertyFn.self)(
            connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if result != 0 { log("SetsCursorInBackground failed: \(result)") }
    }
}

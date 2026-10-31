import AppKit

/// Hides the system cursor while zoomed and supplies the current cursor image for the overlay.
final class CursorRenderer {
    struct Snapshot {
        let image: CGImage
        /// In points, at 1×.
        let size: CGSize
        /// From the top-left corner, in points.
        let hotSpot: CGPoint
    }

    private(set) var isSystemCursorHidden = false
    private(set) var snapshot: Snapshot?
    private var fingerprint: Int?

    init() {
        Self.allowCursorControlInBackground()
    }

    func hideSystemCursor() {
        guard !isSystemCursorHidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        isSystemCursorHidden = true
    }

    func showSystemCursor() {
        guard isSystemCursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        isSystemCursorHidden = false
    }

    /// Re-reads the system cursor (arrow, I-beam, hand, …) and keeps the snapshot current.
    func refresh() {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        var smallRect = CGRect(origin: .zero, size: image.size)
        guard let small = image.cgImage(forProposedRect: &smallRect, context: nil, hints: nil) else { return }
        let key = Self.fingerprint(of: small, hotSpot: cursor.hotSpot)
        guard key != fingerprint else { return }

        // The largest representation stays sharp when the cursor is drawn zoomed in.
        var large = small
        if let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) {
            var rect = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
            large = rep.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? small
        }
        snapshot = Snapshot(image: large, size: image.size, hotSpot: cursor.hotSpot)
        fingerprint = key
    }

    private static func fingerprint(of image: CGImage, hotSpot: CGPoint) -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        hasher.combine(hotSpot.x)
        hasher.combine(hotSpot.y)
        if let data = image.dataProvider?.data as Data? { hasher.combine(data) }
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

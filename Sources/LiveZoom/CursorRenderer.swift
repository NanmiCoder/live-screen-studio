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

    private struct CursorGeometry: Equatable {
        let width: Int
        let height: Int
        let hotSpot: CGPoint
    }

    /// Whether LiveZoom wants the system cursor hidden; see `enforceHidden()`.
    private(set) var isSystemCursorHidden = false
    /// Active `CGDisplayHideCursor` count issued by this process, kept bounded at 1 and always balanced on show.
    private var hideCount = 0
    /// True while the system cursor stays visible despite hiding it (the Dock takes over the cursor while the
    /// pointer is over it). The drawn cursor steps aside then, so there is never a second cursor. Measured in
    /// time rather than frames: WindowServer hide IPC can take a couple of frames, especially at 60 Hz.
    var isRevealed: Bool {
        guard let visibleSince else { return false }
        return CACurrentMediaTime() - visibleSince >= 0.06
    }
    private var visibleSince: CFTimeInterval?
    private var revealLogged = false
    private var lastHideAttempt: CFTimeInterval = 0
    private(set) var snapshot: Snapshot?
    private var fingerprint: Int?
    private let arrowFingerprint: Int?
    private let pointingHandFingerprint: Int?
    private let arrowGeometry: CursorGeometry?
    private let pointingHandGeometry: CursorGeometry?
    /// O(1) lookup for already-seen WindowServer cursor seeds so hovering between arrow / I-beam / hand never
    /// touches `NSCursor.currentSystem` or allocates a `CGContext` on the render thread.
    private var seedCache: [Int32: Snapshot] = [:]
    private let hashQueue = DispatchQueue(label: "com.relakkes.livezoom.cursor-hash", qos: .userInteractive)
    private var hashGeneration = 0

    init() {
        Self.allowCursorControlInBackground()
        if let arrowImage = Self.largestImage(of: NSCursor.arrow) {
            let hs = NSCursor.arrow.hotSpot
            arrowFingerprint = Self.fingerprint(of: arrowImage, hotSpot: hs)
            arrowGeometry = CursorGeometry(width: arrowImage.width, height: arrowImage.height, hotSpot: hs)
        } else {
            arrowFingerprint = nil
            arrowGeometry = nil
        }
        if let handImage = Self.largestImage(of: NSCursor.pointingHand) {
            let hs = NSCursor.pointingHand.hotSpot
            pointingHandFingerprint = Self.fingerprint(of: handImage, hotSpot: hs)
            pointingHandGeometry = CursorGeometry(width: handImage.width, height: handImage.height, hotSpot: hs)
        } else {
            pointingHandFingerprint = nil
            pointingHandGeometry = nil
        }
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
        // Let the first hide settle before retrying (avoiding rapid IPC spam on 120 Hz frames), and back off
        // further when the cursor stays revealed (over the Dock). Never call Show inside enforceHidden: that
        // undoes the hide we just requested and makes WindowServer fight every frame.
        let retryInterval: CFTimeInterval = isRevealed ? 0.2 : 0.04
        guard hideCount == 0 || now - lastHideAttempt >= retryInterval else { return }
        lastHideAttempt = now
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
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
        guard isSystemCursorHidden || hideCount > 0 else { return }
        isSystemCursorHidden = false
        visibleSince = nil
        revealLogged = false
        // Always balance our hide count even if `CGCursorIsVisible()` is currently true (e.g. while the Dock
        // temporarily overrides visibility); otherwise WindowServer hides the real cursor once that override ends.
        let shows = max(hideCount, 1)
        for _ in 0..<shows {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        hideCount = 0
        // Defense-in-depth if any hide still has not settled.
        for _ in 0..<32 where !Self.cursorIsVisible() {
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

    /// Re-reads the system cursor (arrow, I-beam, hand, …) without stalling the display-link render frame.
    /// Known seeds resolve in O(1) from cache; unseen cursors whose geometry cannot match arrow/hand resolve
    /// immediately; only ambiguous geometry hashes pixels on a background queue.
    func refresh(seed: Int32? = nil, synchronous: Bool = false) {
        if let seed, let cached = seedCache[seed] {
            hashGeneration += 1
            snapshot = cached
            return
        }
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        guard let image = Self.largestImage(of: cursor) else { return }
        let size = cursor.image.size
        let hotSpot = cursor.hotSpot
        let geometry = CursorGeometry(width: image.width, height: image.height, hotSpot: hotSpot)

        let matchesArrow = geometry == arrowGeometry
        let matchesHand = geometry == pointingHandGeometry
        if !matchesArrow, !matchesHand {
            // Fast path: geometry rules out arrow & pointingHand with zero pixel hashing.
            hashGeneration += 1
            let resolved = Snapshot(image: image, size: size, hotSpot: hotSpot, kind: .other)
            snapshot = resolved
            storeCache(resolved, for: seed)
            return
        }

        if synchronous || snapshot == nil {
            hashGeneration += 1
            let key = Self.fingerprint(of: image, hotSpot: hotSpot)
            let kind = classify(key)
            let resolved = Snapshot(image: image, size: size, hotSpot: hotSpot, kind: kind)
            snapshot = resolved
            fingerprint = key
            storeCache(resolved, for: seed)
            return
        }

        // Provisional immediate update using geometry hint, then exact pixel-hash verification off the main thread.
        let provisionalKind: Kind = matchesArrow ? .arrow : .pointingHand
        snapshot = Snapshot(image: image, size: size, hotSpot: hotSpot, kind: provisionalKind)
        hashGeneration += 1
        let gen = hashGeneration
        let arrowFP = arrowFingerprint
        let handFP = pointingHandFingerprint
        hashQueue.async { [weak self] in
            let key = Self.fingerprint(of: image, hotSpot: hotSpot)
            let kind: Kind = key == arrowFP ? .arrow : key == handFP ? .pointingHand : .other
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let resolved = Snapshot(image: image, size: size, hotSpot: hotSpot, kind: kind)
                self.storeCache(resolved, for: seed)
                guard self.hashGeneration == gen else { return }
                self.snapshot = resolved
                self.fingerprint = key
            }
        }
    }

    private func classify(_ key: Int) -> Kind {
        key == arrowFingerprint ? .arrow : key == pointingHandFingerprint ? .pointingHand : .other
    }

    private func storeCache(_ snapshot: Snapshot, for seed: Int32?) {
        guard let seed else { return }
        if seedCache.count >= 32 { seedCache.removeAll(keepingCapacity: true) }
        seedCache[seed] = snapshot
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

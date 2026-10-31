import CoreGraphics
import Foundation

/// Viewport geometry. Points are display-local, in points, origin at the top-left.
public enum ViewportMath {
    public static func size(display: CGSize, zoom: CGFloat) -> CGSize {
        CGSize(width: display.width / zoom, height: display.height / zoom)
    }

    /// Keeps the viewport inside the display so no area outside it is ever shown.
    public static func clampCenter(_ center: CGPoint, zoom: CGFloat, display: CGSize) -> CGPoint {
        let half = size(display: display, zoom: zoom)
        let minX = half.width / 2, maxX = display.width - half.width / 2
        let minY = half.height / 2, maxY = display.height - half.height / 2
        return CGPoint(x: min(max(center.x, minX), maxX), y: min(max(center.y, minY), maxY))
    }

    public static func rect(center: CGPoint, zoom: CGFloat, display: CGSize) -> CGRect {
        let s = size(display: display, zoom: zoom)
        return CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height)
    }

    /// Where display point `p` appears on the zoomed overlay.
    public static func screenPoint(for p: CGPoint, center: CGPoint, zoom: CGFloat, display: CGSize) -> CGPoint {
        let origin = rect(center: center, zoom: zoom, display: display).origin
        return CGPoint(x: (p.x - origin.x) * zoom, y: (p.y - origin.y) * zoom)
    }

    /// Viewport center at `zoom` that shows `anchor` at `screenPoint` on the overlay.
    public static func anchoredCenter(anchor: CGPoint, screenPoint: CGPoint, zoom: CGFloat, display: CGSize) -> CGPoint {
        CGPoint(x: anchor.x + (display.width / 2 - screenPoint.x) / zoom,
                y: anchor.y + (display.height / 2 - screenPoint.y) / zoom)
    }

    /// Smallest move of `center` that brings `cursor` back inside the safe zone.
    public static func applySafeZone(center: CGPoint, cursor: CGPoint, zoom: CGFloat, display: CGSize, margin: CGFloat) -> CGPoint {
        let s = size(display: display, zoom: zoom)
        let hx = s.width * (0.5 - margin), hy = s.height * (0.5 - margin)
        var c = center
        if cursor.x > c.x + hx { c.x = cursor.x - hx } else if cursor.x < c.x - hx { c.x = cursor.x + hx }
        if cursor.y > c.y + hy { c.y = cursor.y - hy } else if cursor.y < c.y - hy { c.y = cursor.y + hy }
        return c
    }
}

/// Zoom camera for one display: eased zoom transitions plus speed-limited cursor following.
public final class ZoomCamera {
    public enum Phase: Equatable, Sendable {
        case idle, zoomingIn, zoomed, zoomingOut
    }

    public struct Config: Sendable {
        public var follow: FollowPreset = .calm
        public var zoomInDuration: Double = 0.55
        public var zoomOutDuration: Double = 0.45
        public var minZoom: CGFloat = 1.25
        public var maxZoom: CGFloat = 4
        /// Time constant of wheel zoom adjustments.
        public var zoomAdjustTime: Double = 0.08

        public init() {}
    }

    private struct Transition {
        var start: TimeInterval
        var duration: Double
        var fromZoom: CGFloat
        var toZoom: CGFloat
        var anchor: CGPoint
        var anchorScreen: CGPoint
        var toCenter: CGPoint
    }

    public var config: Config
    public let display: CGSize
    public private(set) var phase: Phase = .idle
    public private(set) var zoom: CGFloat = 1
    public private(set) var center: CGPoint
    /// Zoom level the camera is heading to.
    public private(set) var targetZoom: CGFloat = 1

    private var targetCenter: CGPoint
    private var velocity = CGVector.zero
    private var transition: Transition?

    public init(display: CGSize, config: Config = Config()) {
        self.display = display
        self.config = config
        center = CGPoint(x: display.width / 2, y: display.height / 2)
        targetCenter = center
    }

    public var isActive: Bool { phase != .idle }

    public var viewport: CGRect {
        ViewportMath.rect(center: center, zoom: zoom, display: display)
    }

    public func screenPoint(for p: CGPoint) -> CGPoint {
        ViewportMath.screenPoint(for: p, center: center, zoom: zoom, display: display)
    }

    public func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, config.minZoom), config.maxZoom)
    }

    public func zoomIn(to level: CGFloat, cursor: CGPoint, now: TimeInterval) {
        let cursor = clampToDisplay(cursor)
        let z = clampZoom(level)
        let anchorScreen = screenPoint(for: cursor)
        let fixed = ViewportMath.anchoredCenter(anchor: cursor, screenPoint: anchorScreen, zoom: z, display: display)
        let to = settledCenter(fixed, cursor: cursor, zoom: z)
        begin(.zoomingIn, toZoom: z, toCenter: to, anchor: cursor, anchorScreen: anchorScreen,
              duration: config.zoomInDuration, now: now)
    }

    public func zoomOut(cursor: CGPoint, now: TimeInterval) {
        guard phase != .idle else { return }
        let cursor = clampToDisplay(cursor)
        let to = CGPoint(x: display.width / 2, y: display.height / 2)
        begin(.zoomingOut, toZoom: 1, toCenter: to, anchor: cursor, anchorScreen: screenPoint(for: cursor),
              duration: config.zoomOutDuration, now: now)
    }

    /// Multiplies the zoom level while keeping the content under the cursor in place.
    public func adjustZoom(by factor: CGFloat, cursor: CGPoint) {
        let cursor = clampToDisplay(cursor)
        switch phase {
        case .idle, .zoomingOut:
            return
        case .zoomingIn:
            guard var t = transition else { return }
            t.toZoom = clampZoom(t.toZoom * factor)
            let fixed = ViewportMath.anchoredCenter(anchor: t.anchor, screenPoint: t.anchorScreen, zoom: t.toZoom, display: display)
            t.toCenter = settledCenter(fixed, cursor: cursor, zoom: t.toZoom)
            transition = t
            targetZoom = t.toZoom
        case .zoomed:
            targetZoom = clampZoom(targetZoom * factor)
        }
    }

    public func update(cursor: CGPoint, now: TimeInterval, dt: Double) {
        let cursor = clampToDisplay(cursor)
        switch phase {
        case .idle:
            return
        case .zoomingIn, .zoomingOut:
            advanceTransition(now: now)
        case .zoomed:
            follow(cursor: cursor, dt: dt)
        }
    }

    // MARK: - Private

    private func begin(_ phase: Phase, toZoom: CGFloat, toCenter: CGPoint, anchor: CGPoint, anchorScreen: CGPoint,
                       duration: Double, now: TimeInterval) {
        transition = Transition(start: now, duration: duration, fromZoom: zoom, toZoom: toZoom,
                                anchor: anchor, anchorScreen: anchorScreen, toCenter: toCenter)
        self.phase = phase
        targetZoom = toZoom
        velocity = .zero
    }

    private func advanceTransition(now: TimeInterval) {
        guard let t = transition else { return }
        let progress = min(max((now - t.start) / t.duration, 0), 1)
        let e = CGFloat(Easing.easeInOutCubic(progress))
        // Interpolate in log space so the zoom speed looks constant.
        zoom = exp(log(t.fromZoom) + (log(t.toZoom) - log(t.fromZoom)) * e)
        let fixedNow = ViewportMath.anchoredCenter(anchor: t.anchor, screenPoint: t.anchorScreen, zoom: zoom, display: display)
        let fixedEnd = ViewportMath.anchoredCenter(anchor: t.anchor, screenPoint: t.anchorScreen, zoom: t.toZoom, display: display)
        let blended = CGPoint(x: fixedNow.x + (t.toCenter.x - fixedEnd.x) * e,
                              y: fixedNow.y + (t.toCenter.y - fixedEnd.y) * e)
        center = ViewportMath.clampCenter(blended, zoom: zoom, display: display)

        guard progress >= 1 else { return }
        transition = nil
        zoom = t.toZoom
        center = ViewportMath.clampCenter(t.toCenter, zoom: zoom, display: display)
        targetCenter = center
        velocity = .zero
        phase = phase == .zoomingOut ? .idle : .zoomed
    }

    private func follow(cursor: CGPoint, dt: Double) {
        if zoom != targetZoom {
            let k = CGFloat(1 - exp(-dt / config.zoomAdjustTime))
            var newZoom = exp(log(zoom) + (log(targetZoom) - log(zoom)) * k)
            if abs(newZoom - targetZoom) < 0.0005 { newZoom = targetZoom }
            let ratio = zoom / newZoom
            center = CGPoint(x: cursor.x + (center.x - cursor.x) * ratio, y: cursor.y + (center.y - cursor.y) * ratio)
            targetCenter = CGPoint(x: cursor.x + (targetCenter.x - cursor.x) * ratio,
                                   y: cursor.y + (targetCenter.y - cursor.y) * ratio)
            zoom = newZoom
            center = ViewportMath.clampCenter(center, zoom: zoom, display: display)
        }
        targetCenter = settledCenter(targetCenter, cursor: cursor, zoom: zoom)
        center = SmoothDamp.step(current: center, target: targetCenter, velocity: &velocity,
                                 smoothTime: config.follow.smoothTime,
                                 maxSpeed: config.follow.maxVisualSpeed / zoom, dt: dt)
        center = ViewportMath.clampCenter(center, zoom: zoom, display: display)
    }

    private func settledCenter(_ center: CGPoint, cursor: CGPoint, zoom: CGFloat) -> CGPoint {
        let safe = ViewportMath.applySafeZone(center: center, cursor: cursor, zoom: zoom, display: display,
                                              margin: config.follow.margin)
        return ViewportMath.clampCenter(safe, zoom: zoom, display: display)
    }

    private func clampToDisplay(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), display.width), y: min(max(p.y, 0), display.height))
    }
}

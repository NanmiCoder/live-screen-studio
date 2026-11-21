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

    /// Continuous 1:1 proportional mapping across the display: at equilibrium `screenPoint(cursor) == cursor`,
    /// so the cursor can reach every edge smoothly with zero deadzone and zero ratcheting.
    public static func proportionalCenter(cursor: CGPoint, zoom: CGFloat, display: CGSize) -> CGPoint {
        let half = size(display: display, zoom: zoom)
        let minX = half.width / 2, maxX = display.width - half.width / 2
        let minY = half.height / 2, maxY = display.height - half.height / 2
        let tx = display.width > 0 ? min(max(cursor.x / display.width, 0), 1) : 0.5
        let ty = display.height > 0 ? min(max(cursor.y / display.height, 0), 1) : 0.5
        return CGPoint(x: minX + tx * (maxX - minX), y: minY + ty * (maxY - minY))
    }

    /// `viewport` moved by less than one output pixel so that its origin falls on whole output pixels (at
    /// `pixelsPerPoint`). Applied when the camera is at rest so static magnified text is razor-sharp.
    public static func pixelAligned(_ viewport: CGRect, zoom: CGFloat, pixelsPerPoint: CGFloat, display: CGSize) -> CGRect {
        let step = 1 / (zoom * pixelsPerPoint)
        func align(_ value: CGFloat, max limit: CGFloat) -> CGFloat {
            min((value / step).rounded() * step, (limit / step).rounded(.down) * step)
        }
        var aligned = viewport
        aligned.origin = CGPoint(x: max(align(viewport.minX, max: display.width - viewport.width), 0),
                                 y: max(align(viewport.minY, max: display.height - viewport.height), 0))
        return aligned
    }

    /// Leaves `center` alone while `cursor` is inside the safe zone (`margin` from each edge). Once the cursor
    /// crosses it, shifts smoothly so the cursor sits `settleMargin` from that edge.
    public static func applySafeZone(center: CGPoint, cursor: CGPoint, zoom: CGFloat, display: CGSize, margin: CGFloat,
                                     settleMargin: CGFloat? = nil) -> CGPoint {
        let s = size(display: display, zoom: zoom)
        let settle = max(settleMargin ?? margin, margin)
        let hx = s.width * (0.5 - margin), hy = s.height * (0.5 - margin)
        let sx = s.width * (0.5 - settle), sy = s.height * (0.5 - settle)
        var c = center
        if cursor.x > c.x + hx { c.x = cursor.x - sx } else if cursor.x < c.x - hx { c.x = cursor.x + sx }
        if cursor.y > c.y + hy { c.y = cursor.y - sy } else if cursor.y < c.y - hy { c.y = cursor.y + sy }
        return c
    }
}

/// Zoom camera for one display: eased zoom transitions plus critically damped silky cursor following.
public final class ZoomCamera {
    public enum Phase: Equatable, Sendable {
        case idle, zoomingIn, zoomed, zoomingOut
    }

    public struct Config: Sendable {
        public var follow: FollowPreset = .edge
        public var zoomInDuration: Double = 0.40
        public var zoomOutDuration: Double = 0.34
        public var minZoom: CGFloat = 1.25
        public var maxZoom: CGFloat = 4
        /// Time constant of wheel zoom adjustments.
        public var zoomAdjustTime: Double = 0.12
        /// Speed multiplier ceiling while the cursor is outside the visible viewport, so a fast
        /// fling never leaves the cursor off screen for long.
        public var catchUpLimit: CGFloat = 3

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
    /// Holds the camera still (e.g. while drawing) so the content under the pen does not slide away.
    public var followPaused = false {
        didSet { if followPaused { velocity = .zero } }
    }
    public private(set) var phase: Phase = .idle
    public private(set) var zoom: CGFloat = 1
    public private(set) var center: CGPoint
    /// Zoom level the camera is heading to.
    public private(set) var targetZoom: CGFloat = 1

    private var targetCenter: CGPoint
    private var velocity = CGVector.zero
    private var transition: Transition?
    /// Wheel adjustments made during a zoom-in transition; applied smoothly once it finishes, because
    /// retargeting an eased transition mid-way makes the zoom jump.
    private var pendingZoomFactor: CGFloat = 1
    /// Smoothed catch-up multiplier, so the speed limit never drops abruptly when the cursor comes back into view.
    private var boost: CGFloat = 1

    public init(display: CGSize, config: Config = Config()) {
        self.display = display
        self.config = config
        center = CGPoint(x: display.width / 2, y: display.height / 2)
        targetCenter = center
    }

    public var isActive: Bool { phase != .idle }

    /// True when zoom and pan have both come completely to rest.
    public var isSettled: Bool {
        phase == .zoomed && zoom == targetZoom && velocity == .zero && center == targetCenter
    }

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
        let to = followTarget(from: fixed, cursor: cursor, zoom: z)
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

    /// Multiplies the zoom level. The change is applied gradually around the live cursor position, keeping the
    /// content under it in place (see `follow`).
    public func adjustZoom(by factor: CGFloat) {
        switch phase {
        case .idle, .zoomingOut:
            return
        case .zoomingIn:
            guard let t = transition else { return }
            pendingZoomFactor *= factor
            targetZoom = clampZoom(t.toZoom * pendingZoomFactor)
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
            advanceTransition(cursor: cursor, now: now, dt: dt)
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
        pendingZoomFactor = 1
        velocity = .zero
        boost = 1
    }

    private func advanceTransition(cursor: CGPoint, now: TimeInterval, dt: Double) {
        guard var t = transition else { return }
        // If the user starts moving the mouse during zoom-in, smoothly steer the destination center toward
        // the live cursor so panning responds immediately instead of feeling locked out during the transition.
        if phase == .zoomingIn, !followPaused {
            let liveTarget = followTarget(from: t.toCenter, cursor: cursor, zoom: t.toZoom)
            if hypot(liveTarget.x - t.toCenter.x, liveTarget.y - t.toCenter.y) > 0.01 {
                let blend = CGFloat(1 - exp(-dt / max(config.follow.smoothTime, 0.06)))
                t.toCenter = CGPoint(
                    x: t.toCenter.x + (liveTarget.x - t.toCenter.x) * blend,
                    y: t.toCenter.y + (liveTarget.y - t.toCenter.y) * blend
                )
                transition = t
            }
        }

        let previous = center
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
        // Carry over actual end velocity into `.zoomed` so active motion hands off seamlessly without a stop.
        if phase == .zoomingIn, dt > 0 {
            let v = CGVector(dx: (center.x - previous.x) / CGFloat(dt), dy: (center.y - previous.y) / CGFloat(dt))
            velocity = hypot(v.dx, v.dy) > 0.5 ? v : .zero
        } else {
            velocity = .zero
        }
        boost = 1
        targetZoom = phase == .zoomingOut ? 1 : clampZoom(t.toZoom * pendingZoomFactor)
        pendingZoomFactor = 1
        phase = phase == .zoomingOut ? .idle : .zoomed
    }

    private func follow(cursor: CGPoint, dt: Double) {
        if zoom != targetZoom {
            let k = CGFloat(1 - exp(-dt / config.zoomAdjustTime))
            let remaining = log(targetZoom) - log(zoom)
            let minStep = 1 / display.width
            let step = abs(remaining * k) >= minStep ? remaining * k : (remaining < 0 ? -1 : 1) * min(abs(remaining), minStep)
            let newZoom = abs(remaining - step) < 1e-9 ? targetZoom : exp(log(zoom) + step)
            let ratio = zoom / newZoom
            center = CGPoint(x: cursor.x + (center.x - cursor.x) * ratio, y: cursor.y + (center.y - cursor.y) * ratio)
            targetCenter = CGPoint(x: cursor.x + (targetCenter.x - cursor.x) * ratio,
                                   y: cursor.y + (targetCenter.y - cursor.y) * ratio)
            zoom = newZoom
            center = ViewportMath.clampCenter(center, zoom: zoom, display: display)
        }
        guard !followPaused else {
            targetCenter = center
            velocity = .zero
            return
        }
        targetCenter = followTarget(from: targetCenter, cursor: cursor, zoom: zoom)
        let wantedBoost = catchUpBoost(cursor: cursor)
        let boostTime = wantedBoost > boost ? 0.08 : 0.30
        boost += (wantedBoost - boost) * CGFloat(1 - exp(-dt / boostTime))

        center = SmoothDamp.step(current: center, target: targetCenter, velocity: &velocity,
                                 smoothTime: config.follow.smoothTime,
                                 maxSpeed: config.follow.maxVisualSpeed * boost / zoom, dt: dt)
        center = ViewportMath.clampCenter(center, zoom: zoom, display: display)

        // Pure organic ease-out to rest: settle cleanly once motion is imperceptible (< 0.08 screen pt).
        let remaining = hypot(targetCenter.x - center.x, targetCenter.y - center.y) * zoom
        let visualSpeed = hypot(velocity.dx, velocity.dy) * zoom
        if remaining < 0.08, visualSpeed < 1.5 {
            center = targetCenter
            velocity = .zero
        }
    }

    /// 1 while the cursor is visible; grows with its distance outside the viewport (in half-viewports).
    private func catchUpBoost(cursor: CGPoint) -> CGFloat {
        let vp = viewport
        let dx = max(vp.minX - cursor.x, 0, cursor.x - vp.maxX)
        let dy = max(vp.minY - cursor.y, 0, cursor.y - vp.maxY)
        let outside = hypot(dx, dy) / (min(vp.width, vp.height) / 2)
        return min(1 + 2 * outside, config.catchUpLimit)
    }

    private func followTarget(from currentTarget: CGPoint, cursor: CGPoint, zoom: CGFloat) -> CGPoint {
        switch config.follow.mode {
        case .proportional:
            return ViewportMath.clampCenter(
                ViewportMath.proportionalCenter(cursor: cursor, zoom: zoom, display: display),
                zoom: zoom,
                display: display
            )
        case .safeZone:
            let safe = ViewportMath.applySafeZone(center: currentTarget, cursor: cursor, zoom: zoom, display: display,
                                                  margin: config.follow.margin, settleMargin: config.follow.settleMargin)
            return ViewportMath.clampCenter(safe, zoom: zoom, display: display)
        }
    }

    private func clampToDisplay(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), display.width), y: min(max(p.y, 0), display.height))
    }
}

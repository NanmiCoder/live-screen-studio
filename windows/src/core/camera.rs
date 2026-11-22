use crate::core::easing::ease_in_out_cubic;
use crate::core::follow_preset::{FollowMode, FollowPreset};
use crate::core::geometry::{Point, Rect, Size, Vector};
use crate::core::smooth_damp::smooth_damp_step;

/// Viewport geometry. Points are display-local, in points/pixels, origin at top-left.
pub struct ViewportMath;

impl ViewportMath {
    /// Origin of the integer source rectangle used by the Windows magnifier control.
    pub fn magnifier_origin(viewport: Rect, display: Size) -> Point {
        Point::new(
            viewport
                .x
                .round()
                .clamp(0.0, display.width - viewport.width.ceil()),
            viewport
                .y
                .round()
                .clamp(0.0, display.height - viewport.height.ceil()),
        )
    }

    #[inline]
    pub fn size(display: Size, zoom: f64) -> Size {
        Size::new(display.width / zoom, display.height / zoom)
    }

    /// Keeps the viewport inside the display so no area outside it is ever shown.
    #[inline]
    pub fn clamp_center(center: Point, zoom: f64, display: Size) -> Point {
        let half = Self::size(display, zoom);
        let min_x = half.width * 0.5;
        let max_x = display.width - half.width * 0.5;
        let min_y = half.height * 0.5;
        let max_y = display.height - half.height * 0.5;
        Point::new(center.x.clamp(min_x, max_x), center.y.clamp(min_y, max_y))
    }

    #[inline]
    pub fn rect(center: Point, zoom: f64, display: Size) -> Rect {
        let s = Self::size(display, zoom);
        Rect::new(
            center.x - s.width * 0.5,
            center.y - s.height * 0.5,
            s.width,
            s.height,
        )
    }

    /// Where display point `p` appears on the zoomed overlay.
    #[inline]
    pub fn screen_point(p: Point, center: Point, zoom: f64, display: Size) -> Point {
        let origin = Self::rect(center, zoom, display).origin();
        Point::new((p.x - origin.x) * zoom, (p.y - origin.y) * zoom)
    }

    /// Viewport center at `zoom` that shows `anchor` at `screen_point` on the overlay.
    #[inline]
    pub fn anchored_center(anchor: Point, screen_point: Point, zoom: f64, display: Size) -> Point {
        Point::new(
            anchor.x + (display.width * 0.5 - screen_point.x) / zoom,
            anchor.y + (display.height * 0.5 - screen_point.y) / zoom,
        )
    }

    /// Continuous 1:1 proportional mapping across the display.
    #[inline]
    pub fn proportional_center(cursor: Point, zoom: f64, display: Size) -> Point {
        let half = Self::size(display, zoom);
        let min_x = half.width * 0.5;
        let max_x = display.width - half.width * 0.5;
        let min_y = half.height * 0.5;
        let max_y = display.height - half.height * 0.5;
        let tx = if display.width > 0.0 {
            (cursor.x / display.width).clamp(0.0, 1.0)
        } else {
            0.5
        };
        let ty = if display.height > 0.0 {
            (cursor.y / display.height).clamp(0.0, 1.0)
        } else {
            0.5
        };
        Point::new(min_x + tx * (max_x - min_x), min_y + ty * (max_y - min_y))
    }

    /// Shifts `viewport` by less than one output pixel so its origin falls on whole output pixels.
    #[inline]
    pub fn pixel_aligned(viewport: Rect, zoom: f64, pixels_per_point: f64, display: Size) -> Rect {
        let step = 1.0 / (zoom * pixels_per_point);
        let align = |value: f64, limit: f64| -> f64 {
            let rounded = (value / step).round() * step;
            let floored_limit = (limit / step).floor() * step;
            rounded.min(floored_limit)
        };
        let mut aligned = viewport;
        aligned.x = align(viewport.min_x(), display.width - viewport.width).max(0.0);
        aligned.y = align(viewport.min_y(), display.height - viewport.height).max(0.0);
        aligned
    }

    /// Leaves `center` alone while `cursor` is inside the safe zone (`margin` from each edge).
    #[inline]
    pub fn apply_safe_zone(
        center: Point,
        cursor: Point,
        zoom: f64,
        display: Size,
        margin: f64,
        settle_margin: Option<f64>,
    ) -> Point {
        let s = Self::size(display, zoom);
        let settle = settle_margin.unwrap_or(margin).max(margin);
        let hx = s.width * (0.5 - margin);
        let hy = s.height * (0.5 - margin);
        let sx = s.width * (0.5 - settle);
        let sy = s.height * (0.5 - settle);
        let mut c = center;
        if cursor.x > c.x + hx {
            c.x = cursor.x - sx;
        } else if cursor.x < c.x - hx {
            c.x = cursor.x + sx;
        }
        if cursor.y > c.y + hy {
            c.y = cursor.y - sy;
        } else if cursor.y < c.y - hy {
            c.y = cursor.y + sy;
        }
        c
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CameraPhase {
    Idle,
    ZoomingIn,
    Zoomed,
    ZoomingOut,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CameraConfig {
    pub follow: FollowPreset,
    pub zoom_in_duration: f64,
    pub zoom_out_duration: f64,
    pub min_zoom: f64,
    pub max_zoom: f64,
    pub zoom_adjust_time: f64,
    pub catch_up_limit: f64,
}

impl Default for CameraConfig {
    fn default() -> Self {
        Self {
            follow: FollowPreset::CONTINUOUS,
            zoom_in_duration: 0.40,
            zoom_out_duration: 0.34,
            min_zoom: 1.25,
            max_zoom: 4.0,
            zoom_adjust_time: 0.12,
            catch_up_limit: 3.0,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Transition {
    start: f64,
    duration: f64,
    from_zoom: f64,
    to_zoom: f64,
    anchor: Point,
    anchor_screen: Point,
    to_center: Point,
}

/// Zoom camera for one display with eased zoom transitions and configurable cursor following.
#[derive(Debug, Clone)]
pub struct ZoomCamera {
    pub config: CameraConfig,
    pub display: Size,
    follow_paused: bool,
    phase: CameraPhase,
    zoom: f64,
    center: Point,
    target_zoom: f64,
    target_center: Point,
    velocity: Vector,
    transition: Option<Transition>,
    last_update: Option<f64>,
    pending_zoom_factor: f64,
    boost: f64,
}

impl ZoomCamera {
    pub fn new(display: Size, config: CameraConfig) -> Self {
        let center = Point::new(display.width * 0.5, display.height * 0.5);
        Self {
            config,
            display,
            follow_paused: false,
            phase: CameraPhase::Idle,
            zoom: 1.0,
            center,
            target_zoom: 1.0,
            target_center: center,
            velocity: Vector::ZERO,
            transition: None,
            last_update: None,
            pending_zoom_factor: 1.0,
            boost: 1.0,
        }
    }

    pub fn set_follow_paused(&mut self, paused: bool) {
        self.follow_paused = paused;
        if paused {
            self.target_center = self.center;
            self.velocity = Vector::ZERO;
            self.boost = 1.0;
        }
    }

    pub fn follow_paused(&self) -> bool {
        self.follow_paused
    }

    #[inline]
    pub fn phase(&self) -> CameraPhase {
        self.phase
    }

    #[inline]
    pub fn zoom(&self) -> f64 {
        self.zoom
    }

    #[inline]
    pub fn center(&self) -> Point {
        self.center
    }

    #[inline]
    pub fn target_zoom(&self) -> f64 {
        self.target_zoom
    }

    #[inline]
    pub fn is_active(&self) -> bool {
        self.phase != CameraPhase::Idle
    }

    #[inline]
    pub fn is_settled(&self) -> bool {
        self.phase == CameraPhase::Zoomed
            && self.zoom == self.target_zoom
            && self.velocity == Vector::ZERO
            && self.center == self.target_center
    }

    #[inline]
    pub fn viewport(&self) -> Rect {
        ViewportMath::rect(self.center, self.zoom, self.display)
    }

    #[inline]
    pub fn screen_point(&self, p: Point) -> Point {
        ViewportMath::screen_point(p, self.center, self.zoom, self.display)
    }

    #[inline]
    pub fn clamp_zoom(&self, z: f64) -> f64 {
        z.clamp(self.config.min_zoom, self.config.max_zoom)
    }

    pub fn zoom_in(&mut self, level: f64, cursor: Point, now: f64) {
        let cursor = self.clamp_to_display(cursor);
        let z = self.clamp_zoom(level);
        let anchor_screen = self.screen_point(cursor);
        let fixed = ViewportMath::anchored_center(cursor, anchor_screen, z, self.display);
        let to = self.follow_target(fixed, cursor, z);
        self.begin(
            CameraPhase::ZoomingIn,
            z,
            to,
            cursor,
            anchor_screen,
            self.config.zoom_in_duration,
            now,
        );
    }

    pub fn zoom_out(&mut self, cursor: Point, now: f64) {
        if self.phase == CameraPhase::Idle {
            return;
        }
        let cursor = self.clamp_to_display(cursor);
        let to = Point::new(self.display.width * 0.5, self.display.height * 0.5);
        let anchor_screen = self.screen_point(cursor);
        self.begin(
            CameraPhase::ZoomingOut,
            1.0,
            to,
            cursor,
            anchor_screen,
            self.config.zoom_out_duration,
            now,
        );
    }

    pub fn adjust_zoom(&mut self, factor: f64) {
        if self.follow_paused {
            return;
        }
        match self.phase {
            CameraPhase::Idle | CameraPhase::ZoomingOut => {}
            CameraPhase::ZoomingIn => {
                if let Some(t) = self.transition {
                    self.pending_zoom_factor *= factor;
                    self.target_zoom = self.clamp_zoom(t.to_zoom * self.pending_zoom_factor);
                }
            }
            CameraPhase::Zoomed => {
                self.target_zoom = self.clamp_zoom(self.target_zoom * factor);
            }
        }
    }

    pub fn update(&mut self, cursor: Point, now: f64, dt: f64) {
        let previous_update = self.last_update.replace(now);
        if self.follow_paused {
            // Keep animation progress at the last rendered pose throughout the stroke.
            if let (Some(t), Some(previous)) = (&mut self.transition, previous_update) {
                t.start += (now - previous.max(t.start)).max(0.0);
            }
            return;
        }
        let cursor = self.clamp_to_display(cursor);
        match self.phase {
            CameraPhase::Idle => {}
            CameraPhase::ZoomingIn | CameraPhase::ZoomingOut => {
                self.advance_transition(cursor, now, dt);
            }
            CameraPhase::Zoomed => {
                self.follow(cursor, dt);
            }
        }
    }

    /// Preserve the cursor hotspot when motion outruns smooth follow. Check the
    /// integer source origin and f32 scale the compositor actually receives.
    /// Call only when the viewport may move.
    pub fn keep_cursor_visible(&mut self, cursor: Point) {
        let zoom = self.zoom as f32 as f64;
        let viewport = ViewportMath::rect(self.center, zoom, self.display);
        let origin = ViewportMath::magnifier_origin(viewport, self.display);
        let reveal = |point: f64, start: f64, extent: f64| {
            if point < start {
                point.floor()
            } else if point >= start + extent {
                (point + 1.0 - extent).ceil()
            } else {
                start
            }
        };
        let x = reveal(cursor.x, origin.x, viewport.width);
        let y = reveal(cursor.y, origin.y, viewport.height);
        if x != origin.x {
            self.center.x = x + viewport.width * 0.5;
            self.velocity.dx = 0.0;
        }
        if y != origin.y {
            self.center.y = y + viewport.height * 0.5;
            self.velocity.dy = 0.0;
        }
        if x != origin.x || y != origin.y {
            self.center = ViewportMath::clamp_center(self.center, zoom, self.display);
            self.target_center = self.follow_target(self.center, cursor, zoom);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn begin(
        &mut self,
        phase: CameraPhase,
        to_zoom: f64,
        to_center: Point,
        anchor: Point,
        anchor_screen: Point,
        duration: f64,
        now: f64,
    ) {
        self.transition = Some(Transition {
            start: now,
            duration,
            from_zoom: self.zoom,
            to_zoom,
            anchor,
            anchor_screen,
            to_center,
        });
        self.last_update = Some(now);
        self.phase = phase;
        self.target_zoom = to_zoom;
        self.pending_zoom_factor = 1.0;
        self.velocity = Vector::ZERO;
        self.boost = 1.0;
    }

    fn advance_transition(&mut self, cursor: Point, now: f64, dt: f64) {
        let Some(mut t) = self.transition else {
            return;
        };
        let direct = self.config.follow.is_direct();
        let proportional = direct && self.config.follow.mode == FollowMode::Proportional;
        if self.phase == CameraPhase::ZoomingIn && !direct {
            let live_target = self.follow_target(t.to_center, cursor, t.to_zoom);
            if live_target.distance_to(t.to_center) > 0.01 {
                let blend = 1.0 - (-dt / self.config.follow.smooth_time.max(0.06)).exp();
                t.to_center = Point::new(
                    t.to_center.x + (live_target.x - t.to_center.x) * blend,
                    t.to_center.y + (live_target.y - t.to_center.y) * blend,
                );
                self.transition = Some(t);
            }
        }

        let previous = self.center;
        let previous_zoom = self.zoom;
        let progress = ((now - t.start) / t.duration).clamp(0.0, 1.0);
        let e = ease_in_out_cubic(progress);
        self.zoom = if progress < 1.0 {
            (t.from_zoom.ln() + (t.to_zoom.ln() - t.from_zoom.ln()) * e).exp()
        } else {
            t.to_zoom
        };
        self.center = if proportional {
            let tracked = ViewportMath::proportional_center(cursor, self.zoom, self.display);
            // Ease any initial offset away when an animation reverses between cursor samples.
            let weight = (1.0 - e) / t.from_zoom;
            let center = Point::new(
                tracked.x + (t.anchor.x - t.anchor_screen.x) * weight,
                tracked.y + (t.anchor.y - t.anchor_screen.y) * weight,
            );
            ViewportMath::clamp_center(center, self.zoom, self.display)
        } else if direct && self.phase == CameraPhase::ZoomingIn {
            // Rescale the last viewport around the anchor, retaining the rim pan already applied.
            let anchor_screen =
                ViewportMath::screen_point(t.anchor, previous, previous_zoom, self.display);
            let center =
                ViewportMath::anchored_center(t.anchor, anchor_screen, self.zoom, self.display);
            self.follow_target(center, cursor, self.zoom)
        } else {
            let center = if progress < 1.0 {
                let fixed_now = ViewportMath::anchored_center(
                    t.anchor,
                    t.anchor_screen,
                    self.zoom,
                    self.display,
                );
                let fixed_end = ViewportMath::anchored_center(
                    t.anchor,
                    t.anchor_screen,
                    t.to_zoom,
                    self.display,
                );
                Point::new(
                    fixed_now.x + (t.to_center.x - fixed_end.x) * e,
                    fixed_now.y + (t.to_center.y - fixed_end.y) * e,
                )
            } else {
                t.to_center
            };
            ViewportMath::clamp_center(center, self.zoom, self.display)
        };

        if progress < 1.0 {
            return;
        }
        self.transition = None;
        self.target_center = self.center;
        if !direct && self.phase == CameraPhase::ZoomingIn && dt > 0.0 {
            let v = Vector::new(
                (self.center.x - previous.x) / dt,
                (self.center.y - previous.y) / dt,
            );
            self.velocity = if v.length() > 0.5 { v } else { Vector::ZERO };
        } else {
            self.velocity = Vector::ZERO;
        }
        self.boost = 1.0;
        self.target_zoom = if self.phase == CameraPhase::ZoomingOut {
            1.0
        } else {
            self.clamp_zoom(t.to_zoom * self.pending_zoom_factor)
        };
        self.pending_zoom_factor = 1.0;
        self.phase = if self.phase == CameraPhase::ZoomingOut {
            CameraPhase::Idle
        } else {
            CameraPhase::Zoomed
        };
    }

    fn follow(&mut self, cursor: Point, dt: f64) {
        if self.zoom != self.target_zoom {
            let k = 1.0 - (-dt / self.config.zoom_adjust_time).exp();
            let remaining = self.target_zoom.ln() - self.zoom.ln();
            let min_step = 1.0 / self.display.width;
            let step = if (remaining * k).abs() >= min_step {
                remaining * k
            } else {
                (if remaining < 0.0 { -1.0 } else { 1.0 }) * remaining.abs().min(min_step)
            };
            let new_zoom = if (remaining - step).abs() < 1e-9 {
                self.target_zoom
            } else {
                (self.zoom.ln() + step).exp()
            };
            let ratio = self.zoom / new_zoom;
            self.center = Point::new(
                cursor.x + (self.center.x - cursor.x) * ratio,
                cursor.y + (self.center.y - cursor.y) * ratio,
            );
            self.target_center = Point::new(
                cursor.x + (self.target_center.x - cursor.x) * ratio,
                cursor.y + (self.target_center.y - cursor.y) * ratio,
            );
            self.zoom = new_zoom;
            self.center = ViewportMath::clamp_center(self.center, self.zoom, self.display);
        }
        if self.config.follow.is_direct() {
            self.center = self.follow_target(self.center, cursor, self.zoom);
            self.target_center = self.center;
            self.velocity = Vector::ZERO;
            return;
        }
        self.target_center = self.follow_target(self.target_center, cursor, self.zoom);
        let wanted_boost = self.catch_up_boost(cursor);
        let boost_time = if wanted_boost > self.boost { 0.08 } else { 0.30 };
        self.boost += (wanted_boost - self.boost) * (1.0 - (-dt / boost_time).exp());

        self.center = smooth_damp_step(
            self.center,
            self.target_center,
            &mut self.velocity,
            self.config.follow.smooth_time,
            self.config.follow.max_visual_speed * self.boost / self.zoom,
            dt,
        );
        self.center = ViewportMath::clamp_center(self.center, self.zoom, self.display);

        let remaining = self.target_center.distance_to(self.center) * self.zoom;
        let visual_speed = self.velocity.length() * self.zoom;
        if remaining < 0.08 && visual_speed < 1.5 {
            self.center = self.target_center;
            self.velocity = Vector::ZERO;
        }
    }

    fn catch_up_boost(&self, cursor: Point) -> f64 {
        let vp = self.viewport();
        let dx = (vp.min_x() - cursor.x).max(0.0).max(cursor.x - vp.max_x());
        let dy = (vp.min_y() - cursor.y).max(0.0).max(cursor.y - vp.max_y());
        let outside = dx.hypot(dy) / (vp.width.min(vp.height) * 0.5);
        (1.0 + 2.0 * outside).min(self.config.catch_up_limit)
    }

    fn follow_target(&self, current_target: Point, cursor: Point, zoom: f64) -> Point {
        match self.config.follow.mode {
            FollowMode::Proportional => ViewportMath::clamp_center(
                ViewportMath::proportional_center(cursor, zoom, self.display),
                zoom,
                self.display,
            ),
            FollowMode::SafeZone => {
                let safe = ViewportMath::apply_safe_zone(
                    current_target,
                    cursor,
                    zoom,
                    self.display,
                    self.config.follow.margin,
                    Some(self.config.follow.settle_margin),
                );
                ViewportMath::clamp_center(safe, zoom, self.display)
            }
        }
    }

    #[inline]
    fn clamp_to_display(&self, p: Point) -> Point {
        Point::new(
            p.x.clamp(0.0, self.display.width),
            p.y.clamp(0.0, self.display.height),
        )
    }
}

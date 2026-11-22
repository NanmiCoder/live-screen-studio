use serde::{Deserialize, Serialize};

use crate::core::geometry::{Point, Vector};
use crate::core::smooth_damp::smooth_damp_step;

/// 8 pointer styles matching macOS LiveZoom.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CursorStyle {
    System,
    Classic,
    Light,
    Ocean,
    Sunset,
    Mint,
    Dot,
    Spotlight,
}

impl CursorStyle {
    pub const ALL: [Self; 8] = [
        Self::System,
        Self::Classic,
        Self::Light,
        Self::Ocean,
        Self::Sunset,
        Self::Mint,
        Self::Dot,
        Self::Spotlight,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::System => "系统原生",
            Self::Classic => "经典黑",
            Self::Light => "经典白",
            Self::Ocean => "海蓝",
            Self::Sunset => "日落",
            Self::Mint => "薄荷",
            Self::Dot => "圆点",
            Self::Spotlight => "聚光",
        }
    }

    #[inline]
    pub fn replaces_pointing_hand(self) -> bool {
        self == Self::Dot
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClickEffect {
    None,
    Ripple,
    Halo,
}

impl ClickEffect {
    pub fn duration(self) -> f64 {
        match self {
            Self::None => 0.0,
            Self::Ripple => 0.5,
            Self::Halo => 0.45,
        }
    }

    pub fn appearance(self, age: f64) -> Option<ClickAppearance> {
        if self == Self::None || age < 0.0 || age >= self.duration() {
            return None;
        }
        let t = age / self.duration();
        let eased = 1.0 - (1.0 - t).powi(3);
        let fade = 1.0 - t;
        match self {
            Self::None => None,
            Self::Ripple => Some(ClickAppearance {
                radius: 5.0 + 23.0 * eased,
                line_width: 3.0 - 1.8 * eased,
                opacity: 0.9 * fade,
                filled: false,
            }),
            Self::Halo => Some(ClickAppearance {
                radius: 9.0 + 13.0 * eased,
                line_width: 0.0,
                opacity: 0.5 * fade,
                filled: true,
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClickAppearance {
    pub radius: f64,
    pub line_width: f64,
    pub opacity: f64,
    pub filled: bool,
}

/// Optional cursor smoothing and idle fade-out.
#[derive(Debug, Clone)]
pub struct CursorMotion {
    pub smooth_time: f64,
    pub idle_delay: Option<f64>,
    pub fade_out_duration: f64,
    pub fade_in_duration: f64,
    position: Point,
    opacity: f64,
    velocity: Vector,
    last_input: Point,
    last_activity: f64,
}

impl CursorMotion {
    pub fn new(position: Point, now: f64) -> Self {
        Self {
            smooth_time: 0.0,
            idle_delay: None,
            fade_out_duration: 0.35,
            fade_in_duration: 0.08,
            position,
            opacity: 1.0,
            velocity: Vector::ZERO,
            last_input: position,
            last_activity: now,
        }
    }

    #[inline]
    pub fn position(&self) -> Point {
        self.position
    }

    #[inline]
    pub fn opacity(&self) -> f64 {
        self.opacity
    }

    pub fn update(&mut self, input: Point, buttons_down: bool, now: f64, dt: f64) {
        if input != self.last_input || buttons_down {
            self.last_input = input;
            self.last_activity = now;
        }
        if self.smooth_time > 0.0 {
            self.position = smooth_damp_step(
                self.position,
                input,
                &mut self.velocity,
                self.smooth_time,
                f64::MAX * 1e-6,
                dt,
            );
        } else {
            self.position = input;
            self.velocity = Vector::ZERO;
        }
        let hidden = self
            .idle_delay
            .map(|delay| now - self.last_activity >= delay)
            .unwrap_or(false);
        if hidden {
            self.opacity = (self.opacity - dt / self.fade_out_duration).max(0.0);
        } else {
            self.opacity = (self.opacity + dt / self.fade_in_duration).min(1.0);
        }
    }

    pub fn jump(&mut self, point: Point, now: f64) {
        self.position = point;
        self.last_input = point;
        self.last_activity = now;
        self.velocity = Vector::ZERO;
        self.opacity = 1.0;
    }
}

use serde::{Deserialize, Serialize};

/// How the zoomed viewport chases the cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FollowMode {
    /// Maps the cursor continuously across the display (zero deadzone, 1:1 hand-eye feel).
    Proportional,
    /// Holds the camera still inside a central zone and follows once the cursor crosses it.
    SafeZone,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct FollowPreset {
    pub mode: FollowMode,
    /// Safe-zone margin on each edge, as a fraction of viewport size.
    pub margin: f64,
    /// Where the cursor ends up from the edge after following (`== margin` avoids staircase ratcheting).
    pub settle_margin: f64,
    /// Critically damped spring time constant in seconds. Zero follows the target directly.
    pub smooth_time: f64,
    /// Maximum damped pan speed as seen on screen, in points per second.
    pub max_visual_speed: f64,
}

impl FollowPreset {
    /// Holds the central 84% still and tracks cursor displacement immediately at the 8% rim.
    pub const EDGE: Self = Self {
        mode: FollowMode::SafeZone,
        margin: 0.08,
        settle_margin: 0.08,
        smooth_time: 0.0,
        max_visual_speed: 0.0,
    };

    /// Quiet central zone (44% of viewport) with gentle, motion-sickness-free speed for live walkthroughs.
    pub const CALM: Self = Self {
        mode: FollowMode::SafeZone,
        margin: 0.28,
        settle_margin: 0.28,
        smooth_time: 0.22,
        max_visual_speed: 1500.0,
    };

    /// Continuous proportional follow with the zoomed hotspot at the physical cursor.
    pub const CONTINUOUS: Self = Self {
        mode: FollowMode::Proportional,
        margin: 0.0,
        settle_margin: 0.0,
        smooth_time: 0.0,
        max_visual_speed: 0.0,
    };

    pub(crate) fn is_direct(self) -> bool {
        self.smooth_time == 0.0
    }
}

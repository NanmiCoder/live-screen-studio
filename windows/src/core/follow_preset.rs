use serde::{Deserialize, Serialize};

/// How the zoomed viewport chases the cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FollowMode {
    /// Maps the cursor continuously across the display (zero deadzone, 1:1 hand-eye feel).
    Proportional,
    /// Holds the camera still inside a central quiet zone and glides smoothly once the cursor crosses it.
    SafeZone,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct FollowPreset {
    pub mode: FollowMode,
    /// Safe-zone margin on each edge, as a fraction of viewport size.
    pub margin: f64,
    /// Where the cursor ends up from the edge after following (`== margin` avoids staircase ratcheting).
    pub settle_margin: f64,
    /// Critically damped spring time constant in seconds.
    pub smooth_time: f64,
    /// Maximum pan speed as seen on screen, in points per second.
    pub max_visual_speed: f64,
}

impl FollowPreset {
    /// Edge push style: 84% of viewport stays rock-solid still; pushing past the 8% rim glides 1:1 smoothly.
    pub const EDGE: Self = Self {
        mode: FollowMode::SafeZone,
        margin: 0.08,
        settle_margin: 0.08,
        smooth_time: 0.085,
        max_visual_speed: 2000.0,
    };

    /// Quiet central zone (44% of viewport) with gentle, motion-sickness-free speed for live walkthroughs.
    pub const CALM: Self = Self {
        mode: FollowMode::SafeZone,
        margin: 0.28,
        settle_margin: 0.28,
        smooth_time: 0.22,
        max_visual_speed: 1500.0,
    };

    /// Continuous proportional follow with gentle damping and speed cap.
    pub const CONTINUOUS: Self = Self {
        mode: FollowMode::Proportional,
        margin: 0.0,
        settle_margin: 0.0,
        smooth_time: 0.24,
        max_visual_speed: 1800.0,
    };
}

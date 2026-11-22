use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::core::annotation::{HighlightKind, InkStyle};
use crate::core::cursor::{ClickEffect, CursorStyle};
use crate::core::follow_preset::FollowPreset;
use crate::core::geometry::ColorRgba;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FollowStyle {
    Edge,
    Calm,
    Continuous,
}

impl FollowStyle {
    pub fn preset(self) -> FollowPreset {
        match self {
            Self::Edge => FollowPreset::EDGE,
            Self::Calm => FollowPreset::CALM,
            Self::Continuous => FollowPreset::CONTINUOUS,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CloseWindowBehavior {
    KeepInTray,
    QuitApp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TriggerButton {
    Middle,
    Back,
    Forward,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClickColor {
    Blue,
    Yellow,
    Red,
    Green,
    White,
}

impl ClickColor {
    pub fn rgba(self) -> ColorRgba {
        match self {
            Self::Blue => ColorRgba::new(0.20, 0.55, 1.00, 1.0),
            Self::Yellow => ColorRgba::new(1.00, 0.80, 0.10, 1.0),
            Self::Red => ColorRgba::new(1.00, 0.30, 0.30, 1.0),
            Self::Green => ColorRgba::new(0.20, 0.85, 0.50, 1.0),
            Self::White => ColorRgba::new(1.00, 1.00, 1.00, 1.0),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InkColor {
    Red,
    Yellow,
    Green,
    Blue,
    Pink,
    White,
}

impl InkColor {
    pub fn rgba(self) -> ColorRgba {
        match self {
            Self::Red => ColorRgba::new(1.00, 0.23, 0.19, 1.0),
            Self::Yellow => ColorRgba::new(1.00, 0.82, 0.10, 1.0),
            Self::Green => ColorRgba::new(0.20, 0.88, 0.50, 1.0),
            Self::Blue => ColorRgba::new(0.25, 0.60, 1.00, 1.0),
            Self::Pink => ColorRgba::new(1.00, 0.33, 0.72, 1.0),
            Self::White => ColorRgba::new(1.00, 1.00, 1.00, 1.0),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct KeyCombo {
    pub vk: u32,
    pub modifiers: u32,
}

impl KeyCombo {
    pub const MOD_CTRL: u32 = 1 << 0;
    pub const MOD_ALT: u32 = 1 << 1;
    pub const MOD_SHIFT: u32 = 1 << 2;
    pub const MOD_MASK: u32 = Self::MOD_CTRL | Self::MOD_ALT | Self::MOD_SHIFT;

    #[inline]
    pub const fn new(vk: u32, modifiers: u32) -> Self {
        Self {
            vk,
            modifiers: modifiers & Self::MOD_MASK,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shortcut {
    pub vk: u32,
    pub modifiers: u32,
    pub display: String,
}

impl Shortcut {
    /// Default undo shortcut on Windows: `Ctrl+Z` (`VK_Z = 0x5A`).
    pub fn default_undo() -> Self {
        Self {
            vk: 0x5A,
            modifiers: KeyCombo::MOD_CTRL,
            display: "Ctrl+Z".to_string(),
        }
    }

    pub fn combo(&self) -> KeyCombo {
        KeyCombo::new(self.vk, self.modifiers)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    pub enabled: bool,
    pub default_zoom: f64,
    pub trigger: TriggerButton,
    pub follow_style: FollowStyle,
    pub draw_while_zoomed: bool,

    pub ink_style: InkStyle,
    pub ink_color: InkColor,
    pub stroke_width: f64,
    pub shortcuts: HashMap<HighlightKind, Shortcut>,
    pub undo_shortcut: Option<Shortcut>,

    pub cursor_style: CursorStyle,
    pub cursor_size: f64,
    pub click_effect: ClickEffect,
    pub click_color: ClickColor,
    pub smooth_cursor: bool,
    pub hide_idle_cursor: bool,
    pub idle_delay: f64,
    pub custom_cursor_always: bool,

    pub close_window_behavior: CloseWindowBehavior,
    pub launch_at_login: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            default_zoom: 2.0,
            trigger: TriggerButton::Middle,
            follow_style: FollowStyle::Edge,
            draw_while_zoomed: true,
            ink_style: InkStyle::Marker,
            ink_color: InkColor::Red,
            stroke_width: 5.0,
            shortcuts: HashMap::new(),
            undo_shortcut: Some(Shortcut::default_undo()),
            cursor_style: CursorStyle::Classic,
            cursor_size: 1.2,
            click_effect: ClickEffect::Ripple,
            click_color: ClickColor::Blue,
            smooth_cursor: false,
            hide_idle_cursor: false,
            idle_delay: 3.0,
            custom_cursor_always: true,
            close_window_behavior: CloseWindowBehavior::KeepInTray,
            launch_at_login: false,
        }
    }
}

impl AppSettings {
    pub fn config_path() -> Option<PathBuf> {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .map(|p| p.join("LiveZoom").join("settings.json"))
    }

    pub fn load() -> Self {
        let Some(path) = Self::config_path() else {
            return Self::default();
        };
        let Ok(raw) = fs::read_to_string(path) else {
            return Self::default();
        };
        serde_json::from_str(&raw).unwrap_or_default()
    }

    pub fn save(&self) {
        let Some(path) = Self::config_path() else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = fs::write(path, json);
        }
    }

    /// Sets or clears one highlight shortcut; returns displaced action title if another action owned the same combo.
    pub fn set_shortcut(&mut self, kind: HighlightKind, shortcut: Option<Shortcut>) -> Option<String> {
        let mut displaced = None;
        if let Some(ref sc) = shortcut {
            let combo = sc.combo();
            let conflict = self
                .shortcuts
                .iter()
                .find(|(&other, existing)| other != kind && existing.combo() == combo)
                .map(|(&other, _)| other);
            if let Some(other) = conflict {
                self.shortcuts.remove(&other);
                displaced = Some(other.title().to_string());
            }
            if self.undo_shortcut.as_ref().map(Shortcut::combo) == Some(combo) {
                self.undo_shortcut = None;
                displaced = Some("画线撤销".to_string());
            }
            self.shortcuts.insert(kind, sc.clone());
        } else {
            self.shortcuts.remove(&kind);
        }
        displaced
    }

    pub fn set_undo_shortcut(&mut self, shortcut: Option<Shortcut>) -> Option<String> {
        let mut displaced = None;
        if let Some(ref sc) = shortcut {
            let combo = sc.combo();
            let conflict = self
                .shortcuts
                .iter()
                .find(|(_, existing)| existing.combo() == combo)
                .map(|(&kind, _)| kind);
            if let Some(kind) = conflict {
                self.shortcuts.remove(&kind);
                displaced = Some(kind.title().to_string());
            }
        }
        self.undo_shortcut = shortcut;
        displaced
    }
}

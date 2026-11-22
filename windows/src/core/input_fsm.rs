use std::collections::{HashMap, HashSet};

use crate::core::annotation::HighlightKind;
use crate::core::cursor::DragPointer;
use crate::core::geometry::{Point, Rect};
use crate::core::settings::{KeyCombo, TriggerButton};

/// Semantic actions emitted by the platform-independent input gesture state machine.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputAction {
    ToggleZoom,
    CancelZoom,
    AdjustZoom(f64),
    Click(Point),
    DrawingPointer(Option<Point>),
    StrokeBegan(Point),
    StrokeMoved { point: Point, straight: bool },
    StrokeEnded(Option<Point>),
    UndoStroke,
    ClearStrokes,
    Highlight(HighlightKind),
    /// Ask the OS layer to replay a swallowed left-mouse-down (optionally stripping Ctrl first).
    ReplayLeftDown {
        point: Point,
        strip_ctrl: bool,
    },
    /// Completes a replayed drag in the same input queue as its button-down.
    ReplayLeftUp(Point),
    /// Ask the OS layer to replay a swallowed left click (down + up).
    ReplayLeftClick {
        down_point: Point,
        up_point: Point,
    },
    /// Sync the real OS cursor to the pen tip after a swallowed stroke ends.
    MoveOsCursor(Point),
}

/// Decision for the OS low-level hook callback.
#[derive(Debug, Clone, PartialEq)]
pub struct HookOutcome {
    pub swallow: bool,
    pub actions: Vec<InputAction>,
}

impl HookOutcome {
    pub fn pass() -> Self {
        Self {
            swallow: false,
            actions: Vec::new(),
        }
    }

    pub fn swallow(actions: Vec<InputAction>) -> Self {
        Self {
            swallow: true,
            actions,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Modifiers {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
}

impl Modifiers {
    pub const NONE: Self = Self {
        ctrl: false,
        alt: false,
        shift: false,
    };

    pub fn to_bits(self) -> u32 {
        let mut bits = 0;
        if self.ctrl {
            bits |= KeyCombo::MOD_CTRL;
        }
        if self.alt {
            bits |= KeyCombo::MOD_ALT;
        }
        if self.shift {
            bits |= KeyCombo::MOD_SHIFT;
        }
        bits
    }
}

#[derive(Debug, Clone, Copy)]
enum DrawGesture {
    Idle,
    Pending { down_point: Point, ctrl: bool },
    Drawing,
    Finishing,
    Passthrough,
}

const DEFAULT_DRAG_THRESHOLD_PX: f64 = 4.0;
const VK_ESCAPE: u32 = 0x1B;

/// Pure gesture state machine mirroring macOS `InputTap.swift`.
pub struct InputFsm {
    pub enabled: bool,
    pub trigger: TriggerButton,
    pub drawing_armed: bool,
    pub keys_armed: bool,
    pub has_strokes: bool,
    pub cursor_bounds: Option<Rect>,
    /// Physical-pixel threshold to distinguish a click from a draw drag (`4.0 * dpi_scale`).
    pub drag_threshold_px: f64,
    pub shortcuts: HashMap<KeyCombo, HighlightKind>,
    pub undo_shortcut: Option<KeyCombo>,

    trigger_pressed: bool,
    adjusting: bool,
    wheel_accum: f64,
    draw: DrawGesture,
    draw_pointer: Option<DragPointer>,
    swallow_right_up: bool,
    held_keys: HashSet<u32>,
}

impl Default for InputFsm {
    fn default() -> Self {
        Self {
            enabled: true,
            trigger: TriggerButton::Middle,
            drawing_armed: false,
            keys_armed: false,
            has_strokes: false,
            cursor_bounds: None,
            drag_threshold_px: DEFAULT_DRAG_THRESHOLD_PX,
            shortcuts: HashMap::new(),
            undo_shortcut: None,
            trigger_pressed: false,
            adjusting: false,
            wheel_accum: 0.0,
            draw: DrawGesture::Idle,
            draw_pointer: None,
            swallow_right_up: false,
            held_keys: HashSet::new(),
        }
    }
}

impl InputFsm {
    pub fn set_drawing_armed(&mut self, armed: bool) -> Vec<InputAction> {
        let mut actions = Vec::new();
        let prev = self.draw;
        let tip = self.draw_pointer.map(|d| d.location());
        self.drawing_armed = armed;
        self.swallow_right_up = false;
        match self.draw {
            DrawGesture::Drawing | DrawGesture::Finishing => {
                self.draw = DrawGesture::Finishing;
            }
            DrawGesture::Idle | DrawGesture::Pending { .. } => {
                self.draw = DrawGesture::Idle;
                self.draw_pointer = None;
            }
            DrawGesture::Passthrough => {}
        }
        match prev {
            DrawGesture::Pending { down_point, ctrl } => {
                actions.push(InputAction::ReplayLeftDown {
                    point: down_point,
                    strip_ctrl: ctrl,
                });
                actions.push(InputAction::DrawingPointer(None));
            }
            DrawGesture::Drawing => {
                if let Some(p) = tip {
                    actions.push(InputAction::MoveOsCursor(p));
                }
                actions.push(InputAction::StrokeEnded(tip));
                actions.push(InputAction::DrawingPointer(None));
            }
            _ => {}
        }
        actions
    }

    pub fn set_keys_armed(&mut self, armed: bool) {
        self.keys_armed = armed;
        self.held_keys.clear();
    }

    pub fn on_trigger_down(&mut self, button: TriggerButton, mods: Modifiers) -> HookOutcome {
        if !self.enabled || button != self.trigger {
            return HookOutcome::pass();
        }
        // Alt + trigger passes through the real middle/side click.
        if mods.alt {
            return HookOutcome::pass();
        }
        self.trigger_pressed = true;
        self.adjusting = false;
        self.wheel_accum = 0.0;
        HookOutcome::swallow(Vec::new())
    }

    pub fn on_trigger_up(&mut self, button: TriggerButton) -> HookOutcome {
        if button != self.trigger || !self.trigger_pressed {
            return HookOutcome::pass();
        }
        self.trigger_pressed = false;
        let was_adjusting = self.adjusting;
        self.adjusting = false;
        self.wheel_accum = 0.0;
        if was_adjusting {
            HookOutcome::swallow(Vec::new())
        } else {
            HookOutcome::swallow(vec![InputAction::ToggleZoom])
        }
    }

    /// `notches`: positive when wheel scrolls away from user (1.0 per standard 120-unit detent).
    pub fn on_wheel(&mut self, notches: f64) -> HookOutcome {
        if !self.enabled || !self.trigger_pressed {
            return HookOutcome::pass();
        }
        self.wheel_accum += notches;
        if !self.adjusting && self.wheel_accum.abs() < 0.75 {
            return HookOutcome::swallow(Vec::new());
        }
        self.adjusting = true;
        let steps = self.wheel_accum;
        self.wheel_accum = 0.0;
        HookOutcome::swallow(vec![InputAction::AdjustZoom(steps)])
    }

    pub fn on_left_down(&mut self, point: Point, mods: Modifiers) -> HookOutcome {
        if !self.enabled
            || !self.drawing_armed
            || self
                .cursor_bounds
                .is_some_and(|bounds| !bounds.contains(point))
        {
            return HookOutcome {
                swallow: false,
                actions: vec![InputAction::Click(point)],
            };
        }
        // While drawing is armed, defer Click emission until release confirms it wasn't a draw stroke.
        self.draw = DrawGesture::Pending {
            down_point: point,
            ctrl: mods.ctrl,
        };
        self.draw_pointer = Some(DragPointer::new(point, self.cursor_bounds));
        HookOutcome::swallow(vec![InputAction::DrawingPointer(Some(point))])
    }

    pub fn on_mouse_move(&mut self, point: Point, mods: Modifiers) -> HookOutcome {
        match self.draw {
            DrawGesture::Idle | DrawGesture::Passthrough => HookOutcome::pass(),
            DrawGesture::Pending { down_point, ctrl } => {
                if let Some(dp) = &mut self.draw_pointer {
                    dp.move_to(point, self.cursor_bounds);
                }
                let loc = self.draw_pointer.map(|d| d.location()).unwrap_or(point);
                if loc.distance_to(down_point) < self.drag_threshold_px {
                    // Swallow hover moves while deciding click vs drag so underlying apps don't change cursor/tooltip.
                    return HookOutcome::swallow(vec![InputAction::DrawingPointer(Some(loc))]);
                }
                if ctrl {
                    // Ctrl + left-drag becomes a normal drag (strip Ctrl so VS Code/browsers select text cleanly).
                    self.draw = DrawGesture::Passthrough;
                    self.draw_pointer = None;
                    return HookOutcome {
                        swallow: false,
                        actions: vec![
                            InputAction::DrawingPointer(None),
                            InputAction::ReplayLeftDown {
                                point: down_point,
                                strip_ctrl: true,
                            },
                        ],
                    };
                }
                self.draw = DrawGesture::Drawing;
                HookOutcome::swallow(vec![
                    InputAction::DrawingPointer(Some(loc)),
                    InputAction::StrokeBegan(down_point),
                    InputAction::StrokeMoved {
                        point: loc,
                        straight: mods.shift,
                    },
                ])
            }
            DrawGesture::Drawing => {
                if let Some(dp) = &mut self.draw_pointer {
                    dp.move_to(point, self.cursor_bounds);
                }
                let loc = self.draw_pointer.map(|d| d.location()).unwrap_or(point);
                // Swallow WM_MOUSEMOVE during active stroke so underlying windows don't pop tooltips or switch cursor.
                HookOutcome::swallow(vec![
                    InputAction::DrawingPointer(Some(loc)),
                    InputAction::StrokeMoved {
                        point: loc,
                        straight: mods.shift,
                    },
                ])
            }
            DrawGesture::Finishing => {
                if let Some(dp) = &mut self.draw_pointer {
                    dp.move_to(point, self.cursor_bounds);
                }
                HookOutcome::swallow(Vec::new())
            }
        }
    }

    pub fn on_left_up(&mut self, point: Point) -> HookOutcome {
        match self.draw {
            DrawGesture::Idle => HookOutcome::pass(),
            DrawGesture::Passthrough => {
                self.draw = DrawGesture::Idle;
                self.draw_pointer = None;
                HookOutcome::swallow(vec![InputAction::ReplayLeftUp(point)])
            }
            DrawGesture::Pending { down_point, .. } => {
                self.draw = DrawGesture::Idle;
                self.draw_pointer = None;
                HookOutcome::swallow(vec![
                    InputAction::DrawingPointer(None),
                    InputAction::Click(down_point),
                    InputAction::ReplayLeftClick {
                        down_point,
                        up_point: point,
                    },
                ])
            }
            DrawGesture::Drawing => {
                let tip = self.draw_pointer.map(|d| d.location());
                self.draw = DrawGesture::Idle;
                self.draw_pointer = None;
                let mut actions = Vec::new();
                if let Some(p) = tip {
                    actions.push(InputAction::MoveOsCursor(p));
                }
                actions.push(InputAction::StrokeEnded(tip));
                actions.push(InputAction::DrawingPointer(None));
                HookOutcome::swallow(actions)
            }
            DrawGesture::Finishing => {
                let tip = self.draw_pointer.map(|d| d.location());
                self.draw = DrawGesture::Idle;
                self.draw_pointer = None;
                let mut actions = Vec::new();
                if let Some(p) = tip {
                    actions.push(InputAction::MoveOsCursor(p));
                }
                actions.push(InputAction::DrawingPointer(None));
                HookOutcome::swallow(actions)
            }
        }
    }

    pub fn on_right_down(&mut self, point: Point) -> HookOutcome {
        if self.enabled
            && self.drawing_armed
            && self.has_strokes
            && self
                .cursor_bounds
                .is_none_or(|bounds| bounds.contains(point))
        {
            self.swallow_right_up = true;
            return HookOutcome::swallow(vec![InputAction::UndoStroke]);
        }
        HookOutcome {
            swallow: false,
            actions: vec![InputAction::Click(point)],
        }
    }

    pub fn on_right_up(&mut self) -> HookOutcome {
        if self.swallow_right_up {
            self.swallow_right_up = false;
            return HookOutcome::swallow(Vec::new());
        }
        HookOutcome::pass()
    }

    pub fn on_key_down(&mut self, vk: u32, mods: Modifiers) -> HookOutcome {
        if !self.enabled || !self.keys_armed {
            return HookOutcome::pass();
        }
        // Suppress OS key auto-repeat for keys we already claimed (prevents OCR storm and trailing Ctrl+Z leaks).
        if self.held_keys.contains(&vk) {
            return HookOutcome::swallow(Vec::new());
        }
        if vk == VK_ESCAPE && mods == Modifiers::NONE {
            self.held_keys.insert(vk);
            return HookOutcome::swallow(vec![if self.has_strokes {
                InputAction::ClearStrokes
            } else {
                InputAction::CancelZoom
            }]);
        }
        let combo = KeyCombo::new(vk, mods.to_bits());
        if self.has_strokes && self.undo_shortcut == Some(combo) {
            self.held_keys.insert(vk);
            return HookOutcome::swallow(vec![InputAction::UndoStroke]);
        }
        if let Some(&kind) = self.shortcuts.get(&combo) {
            self.held_keys.insert(vk);
            return HookOutcome::swallow(vec![InputAction::Highlight(kind)]);
        }
        HookOutcome::pass()
    }

    pub fn on_key_up(&mut self, vk: u32) -> HookOutcome {
        if self.held_keys.remove(&vk) {
            HookOutcome::swallow(Vec::new())
        } else {
            HookOutcome::pass()
        }
    }
}

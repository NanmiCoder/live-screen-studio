use std::collections::{HashMap, HashSet};

use crate::core::annotation::HighlightKind;
use crate::core::geometry::{Point, Rect};
use crate::core::settings::{KeyCombo, TriggerButton};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputAction {
    ToggleZoom(Point),
    CancelZoom,
    AdjustZoom { steps: f64, at: Point },
    Click(Point),
    StrokeBegan(Point),
    StrokeMoved { point: Point, straight: bool },
    StrokeEnded,
    UndoStroke,
    ClearStrokes,
    Highlight(HighlightKind),
}

#[derive(Debug, Clone, PartialEq)]
pub struct HookOutcome {
    pub swallow: bool,
    pub actions: Vec<InputAction>,
}

impl HookOutcome {
    pub fn pass() -> Self {
        Self::new(false, Vec::new())
    }

    fn swallow() -> Self {
        Self::new(true, Vec::new())
    }

    fn new(swallow: bool, actions: Vec<InputAction>) -> Self {
        Self { swallow, actions }
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
    Pending(Point),
    Drawing,
    Cancelled,
}

struct TriggerGesture {
    button: TriggerButton,
    cancelled: bool,
    adjusting: bool,
    wheel_accum: f64,
}

const DEFAULT_DRAG_THRESHOLD_PX: f64 = 4.0;
const VK_ESCAPE: u32 = 0x1B;

/// Owns any button or key it consumes until the corresponding physical release.
/// Only the explicit drawing chord reserves left-button input. Pointer motion always reaches Windows.
pub struct InputFsm {
    enabled: bool,
    trigger: TriggerButton,
    drawing_armed: bool,
    keys_armed: bool,
    suspended: bool,
    pub has_strokes: bool,
    pub drawing_bounds: Option<Rect>,
    pub drag_threshold_px: f64,
    pub shortcuts: HashMap<KeyCombo, HighlightKind>,
    pub undo_shortcut: Option<KeyCombo>,

    trigger_gesture: Option<TriggerGesture>,
    draw: DrawGesture,
    held_keys: HashSet<u32>,
}

impl Default for InputFsm {
    fn default() -> Self {
        Self {
            enabled: true,
            trigger: TriggerButton::Middle,
            drawing_armed: false,
            keys_armed: false,
            suspended: false,
            has_strokes: false,
            drawing_bounds: None,
            drag_threshold_px: DEFAULT_DRAG_THRESHOLD_PX,
            shortcuts: HashMap::new(),
            undo_shortcut: None,
            trigger_gesture: None,
            draw: DrawGesture::Idle,
            held_keys: HashSet::new(),
        }
    }
}

impl InputFsm {
    pub fn configure_trigger(
        &mut self,
        enabled: bool,
        trigger: TriggerButton,
    ) -> Option<InputAction> {
        if !enabled || trigger != self.trigger {
            self.cancel_trigger();
        }
        self.enabled = enabled;
        self.trigger = trigger;
        if enabled {
            None
        } else {
            self.cancel_drawing()
        }
    }

    pub fn set_suspended(&mut self, suspended: bool) -> Option<InputAction> {
        let entering = suspended && !self.suspended;
        self.suspended = suspended;
        if entering {
            self.cancel_trigger();
            self.cancel_drawing()
        } else {
            None
        }
    }

    pub fn set_drawing_armed(&mut self, armed: bool) -> Option<InputAction> {
        self.drawing_armed = armed;
        if armed {
            None
        } else {
            self.cancel_drawing()
        }
    }

    pub fn set_keys_armed(&mut self, armed: bool) {
        self.keys_armed = armed;
    }

    fn accepts_new_input(&self) -> bool {
        self.enabled && !self.suspended
    }

    fn cancel_trigger(&mut self) {
        if let Some(gesture) = self.trigger_gesture.as_mut() {
            gesture.cancelled = true;
        }
    }

    fn cancel_drawing(&mut self) -> Option<InputAction> {
        match self.draw {
            DrawGesture::Idle | DrawGesture::Cancelled => None,
            DrawGesture::Pending(_) => {
                self.draw = DrawGesture::Cancelled;
                None
            }
            DrawGesture::Drawing => {
                self.draw = DrawGesture::Cancelled;
                Some(InputAction::StrokeEnded)
            }
        }
    }

    pub fn on_trigger_down(&mut self, button: TriggerButton, mods: Modifiers) -> HookOutcome {
        if let Some(gesture) = self.trigger_gesture.as_ref() {
            return HookOutcome::new(gesture.button == button, Vec::new());
        }
        if !self.accepts_new_input() || button != self.trigger || mods.alt {
            return HookOutcome::pass();
        }
        self.trigger_gesture = Some(TriggerGesture {
            button,
            cancelled: false,
            adjusting: false,
            wheel_accum: 0.0,
        });
        HookOutcome::swallow()
    }

    pub fn on_trigger_up(&mut self, button: TriggerButton, point: Point) -> HookOutcome {
        if self
            .trigger_gesture
            .as_ref()
            .is_none_or(|gesture| gesture.button != button)
        {
            return HookOutcome::pass();
        }
        let gesture = self.trigger_gesture.take().unwrap();
        if gesture.adjusting || gesture.cancelled {
            HookOutcome::swallow()
        } else {
            HookOutcome::new(true, vec![InputAction::ToggleZoom(point)])
        }
    }

    pub fn on_wheel(&mut self, notches: f64, at: Point) -> HookOutcome {
        let Some(gesture) = self
            .trigger_gesture
            .as_mut()
            .filter(|gesture| !gesture.cancelled)
        else {
            return HookOutcome::pass();
        };
        gesture.wheel_accum += notches;
        if !gesture.adjusting && gesture.wheel_accum.abs() < 0.75 {
            return HookOutcome::swallow();
        }
        gesture.adjusting = true;
        let steps = std::mem::take(&mut gesture.wheel_accum);
        HookOutcome::new(true, vec![InputAction::AdjustZoom { steps, at }])
    }

    pub fn on_left_down(&mut self, point: Point, mods: Modifiers) -> HookOutcome {
        if !matches!(self.draw, DrawGesture::Idle) {
            return HookOutcome::swallow();
        }
        if self.accepts_new_input()
            && self.drawing_armed
            && mods.ctrl
            && mods.alt
            && self
                .drawing_bounds
                .is_none_or(|bounds| bounds.contains_pixel(point))
        {
            self.draw = DrawGesture::Pending(point);
            HookOutcome::swallow()
        } else {
            self.observe_click(point)
        }
    }

    pub fn on_mouse_move(&mut self, point: Point, straight: bool) -> HookOutcome {
        if self
            .drawing_bounds
            .is_some_and(|bounds| !bounds.contains_pixel(point))
        {
            return HookOutcome::new(false, self.cancel_drawing().into_iter().collect());
        }
        match self.draw {
            DrawGesture::Pending(start) if start.distance_to(point) >= self.drag_threshold_px => {
                self.draw = DrawGesture::Drawing;
                HookOutcome::new(
                    false,
                    vec![
                        InputAction::StrokeBegan(start),
                        InputAction::StrokeMoved { point, straight },
                    ],
                )
            }
            DrawGesture::Drawing => {
                HookOutcome::new(false, vec![InputAction::StrokeMoved { point, straight }])
            }
            _ => HookOutcome::pass(),
        }
    }

    pub fn on_left_up(&mut self) -> HookOutcome {
        match std::mem::replace(&mut self.draw, DrawGesture::Idle) {
            DrawGesture::Idle => HookOutcome::pass(),
            DrawGesture::Drawing => HookOutcome::new(true, vec![InputAction::StrokeEnded]),
            DrawGesture::Pending(_) | DrawGesture::Cancelled => HookOutcome::swallow(),
        }
    }

    pub fn observe_click(&self, point: Point) -> HookOutcome {
        if self.accepts_new_input() {
            HookOutcome::new(false, vec![InputAction::Click(point)])
        } else {
            HookOutcome::pass()
        }
    }

    pub fn on_key_down(&mut self, vk: u32, mods: Modifiers) -> HookOutcome {
        if self.held_keys.contains(&vk) {
            return HookOutcome::swallow();
        }
        if !self.accepts_new_input() || !self.keys_armed {
            return HookOutcome::pass();
        }
        let combo = KeyCombo::new(vk, mods.to_bits());
        let action = if vk == VK_ESCAPE && mods == Modifiers::NONE {
            if self.has_strokes {
                InputAction::ClearStrokes
            } else {
                InputAction::CancelZoom
            }
        } else if self.has_strokes && self.undo_shortcut == Some(combo) {
            InputAction::UndoStroke
        } else if let Some(&kind) = self.shortcuts.get(&combo) {
            InputAction::Highlight(kind)
        } else {
            return HookOutcome::pass();
        };
        self.held_keys.insert(vk);
        HookOutcome::new(true, vec![action])
    }

    pub fn on_key_up(&mut self, vk: u32) -> HookOutcome {
        if self.held_keys.remove(&vk) {
            HookOutcome::swallow()
        } else {
            HookOutcome::pass()
        }
    }
}

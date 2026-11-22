use std::collections::HashMap;
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::{SystemTime, UNIX_EPOCH};

use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{
    GetCurrentThread, GetCurrentThreadId, SetThreadPriority, THREAD_PRIORITY_HIGHEST,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT,
    KEYEVENTF_KEYUP, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_VIRTUALDESK, MOUSEINPUT, VK_CONTROL, VK_LCONTROL, VK_MENU,
    VK_RCONTROL, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, ClipCursor, DispatchMessageW, GetMessageW, GetSystemMetrics,
    PostThreadMessageW, SetCursorPos, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx,
    HC_ACTION, KBDLLHOOKSTRUCT, MSLLHOOKSTRUCT, MSG, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
    SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP,
    WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEMOVE, WM_MOUSEWHEEL,
    WM_QUIT, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_XBUTTONDOWN,
    WM_XBUTTONUP, XBUTTON1, XBUTTON2,
};

use crate::core::annotation::HighlightKind;
use crate::core::geometry::{Point, Rect};
use crate::core::input_fsm::{HookOutcome, InputAction, InputFsm, Modifiers};
use crate::core::settings::{KeyCombo, TriggerButton};

const SYNTHETIC_MARKER: usize = 0x4C5A_0001;
const MAIN_THREAD_STALL_MS: i64 = 400;

struct SharedHookState {
    fsm: Mutex<InputFsm>,
    tx: Mutex<Option<Sender<InputAction>>>,
    main_heartbeat_ms: AtomicI64,
    /// True while main thread is intentionally inside a Win32 modal UI loop (tray popup / window drag).
    modal_paused: AtomicBool,
}

static HOOK_STATE: OnceLock<SharedHookState> = OnceLock::new();

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn state() -> &'static SharedHookState {
    HOOK_STATE.get_or_init(|| SharedHookState {
        fsm: Mutex::new(InputFsm::default()),
        tx: Mutex::new(None),
        main_heartbeat_ms: AtomicI64::new(now_ms()),
        modal_paused: AtomicBool::new(false),
    })
}

/// Global low-level mouse & keyboard hook running on a dedicated high-priority thread.
pub struct InputHook {
    rx: Receiver<InputAction>,
    thread_id: u32,
    join: Option<JoinHandle<()>>,
}

impl InputHook {
    pub fn start() -> Result<Self, String> {
        let (tx, rx) = mpsc::channel();
        {
            let mut guard = state().tx.lock().unwrap();
            *guard = Some(tx);
        }
        state().main_heartbeat_ms.store(now_ms(), Ordering::Relaxed);
        state().modal_paused.store(false, Ordering::Relaxed);

        let tid_cell = std::sync::Arc::new(AtomicU32::new(0));
        let tid_clone = tid_cell.clone();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();

        let join = thread::Builder::new()
            .name("LiveZoom-InputHook".to_string())
            .spawn(move || unsafe {
                let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
                let tid = GetCurrentThreadId();
                tid_clone.store(tid, Ordering::SeqCst);

                let hinst = GetModuleHandleW(None)
                    .map(HINSTANCE::from)
                    .unwrap_or_default();
                let mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), hinst, 0);
                let key_hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), hinst, 0);

                match (mouse_hook, key_hook) {
                    (Ok(mh), Ok(kh)) => {
                        let _ = ready_tx.send(Ok(()));
                        let mut msg = MSG::default();
                        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                            let _ = TranslateMessage(&msg);
                            DispatchMessageW(&msg);
                        }
                        let _ = UnhookWindowsHookEx(mh);
                        let _ = UnhookWindowsHookEx(kh);
                    }
                    (mh, kh) => {
                        if let Ok(h) = mh {
                            let _ = UnhookWindowsHookEx(h);
                        }
                        if let Ok(h) = kh {
                            let _ = UnhookWindowsHookEx(h);
                        }
                        let _ = ready_tx.send(Err("SetWindowsHookExW failed".to_string()));
                    }
                }
            })
            .map_err(|e| format!("failed to spawn hook thread: {e}"))?;

        ready_rx
            .recv()
            .map_err(|_| "hook thread exited early".to_string())??;

        Ok(Self {
            rx,
            thread_id: tid_cell.load(Ordering::SeqCst),
            join: Some(join),
        })
    }

    pub fn heartbeat(&self) {
        state().main_heartbeat_ms.store(now_ms(), Ordering::Relaxed);
    }

    pub fn set_modal_paused(&self, paused: bool) {
        state().modal_paused.store(paused, Ordering::SeqCst);
        if !paused {
            self.heartbeat();
        }
    }

    pub fn drain_actions(&self) -> Vec<InputAction> {
        let mut out = Vec::new();
        while let Ok(act) = self.rx.try_recv() {
            out.push(act);
        }
        out
    }

    pub fn set_enabled(&self, enabled: bool) {
        state().fsm.lock().unwrap().enabled = enabled;
    }

    pub fn set_trigger(&self, trigger: TriggerButton) {
        state().fsm.lock().unwrap().trigger = trigger;
    }

    pub fn set_drag_threshold_px(&self, px: f64) {
        state().fsm.lock().unwrap().drag_threshold_px = px.max(2.0);
    }

    pub fn set_drawing_armed(&self, armed: bool) {
        // Lock FSM briefly (<1us), release lock completely BEFORE calling SendInput (prevents AB-BA deadlock).
        let actions = { state().fsm.lock().unwrap().set_drawing_armed(armed) };
        dispatch_actions(actions);
    }

    pub fn set_keys_armed(&self, armed: bool) {
        state().fsm.lock().unwrap().set_keys_armed(armed);
    }

    pub fn set_has_strokes(&self, has: bool) {
        state().fsm.lock().unwrap().has_strokes = has;
    }

    pub fn set_shortcuts(
        &self,
        shortcuts: HashMap<KeyCombo, HighlightKind>,
        undo: Option<KeyCombo>,
    ) {
        let mut fsm = state().fsm.lock().unwrap();
        fsm.shortcuts = shortcuts;
        fsm.undo_shortcut = undo;
    }

    /// Confines the OS cursor inside `bounds` (display work area, avoiding taskbar) while zoomed.
    pub fn set_cursor_bounds(&self, bounds: Option<Rect>) {
        state().fsm.lock().unwrap().cursor_bounds = bounds;
        unsafe {
            match bounds {
                Some(b) => {
                    let r = RECT {
                        left: b.min_x().round() as i32,
                        top: b.min_y().round() as i32,
                        right: b.max_x().round() as i32,
                        bottom: b.max_y().round() as i32,
                    };
                    let _ = ClipCursor(Some(&r));
                }
                None => {
                    let _ = ClipCursor(None);
                }
            }
        }
    }
}

impl Drop for InputHook {
    fn drop(&mut self) {
        unsafe {
            let _ = ClipCursor(None);
            if self.thread_id != 0 {
                let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
            }
        }
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
        if let Ok(mut guard) = state().tx.lock() {
            *guard = None;
        }
    }
}

fn should_passthrough_all() -> bool {
    if state().modal_paused.load(Ordering::Relaxed) {
        return true;
    }
    let last = state().main_heartbeat_ms.load(Ordering::Relaxed);
    now_ms() - last > MAIN_THREAD_STALL_MS
}

fn current_modifiers() -> Modifiers {
    unsafe {
        Modifiers {
            ctrl: (GetAsyncKeyState(VK_CONTROL.0 as i32) as u16 & 0x8000) != 0,
            alt: (GetAsyncKeyState(VK_MENU.0 as i32) as u16 & 0x8000) != 0,
            shift: (GetAsyncKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000) != 0,
        }
    }
}

/// Dispatches semantic actions safely without EVER holding any mutex across `SendInput` or `SetCursorPos`.
fn dispatch_actions(actions: Vec<InputAction>) {
    if actions.is_empty() {
        return;
    }
    // Clone sender and release `tx` mutex immediately so `SendInput` can never AB-BA deadlock with hook thread.
    let tx = state().tx.lock().ok().and_then(|g| g.clone());
    for action in actions {
        match action {
            InputAction::ReplayLeftDown { point, strip_ctrl } => {
                if strip_ctrl {
                    release_ctrl_keys();
                }
                replay_left_event(point, true, false);
            }
            InputAction::ReplayLeftClick {
                down_point,
                up_point,
            } => {
                replay_left_event(down_point, true, false);
                replay_left_event(up_point, false, true);
            }
            InputAction::MoveOsCursor(point) => unsafe {
                let _ = SetCursorPos(point.x.round() as i32, point.y.round() as i32);
            },
            other => {
                if let Some(ref sender) = tx {
                    let _ = sender.send(other);
                }
            }
        }
    }
}

/// Releases physically held Ctrl keys synthetically before replaying a Ctrl+drag as a normal text selection drag.
fn release_ctrl_keys() {
    unsafe {
        let mut inputs = Vec::with_capacity(2);
        for vk in [VK_LCONTROL, VK_RCONTROL] {
            if (GetAsyncKeyState(vk.0 as i32) as u16 & 0x8000) != 0 {
                inputs.push(INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: vk,
                            wScan: 0,
                            dwFlags: KEYEVENTF_KEYUP,
                            time: 0,
                            dwExtraInfo: SYNTHETIC_MARKER,
                        },
                    },
                });
            }
        }
        if !inputs.is_empty() {
            let _ = SendInput(&inputs, size_of::<INPUT>() as i32);
        }
    }
}

fn replay_left_event(point: Point, down: bool, up: bool) {
    unsafe {
        let vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        let vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        let vw = GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1);
        let vh = GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1);

        let dx = (((point.x - vx as f64) * 65535.0) / (vw - 1).max(1) as f64).round() as i32;
        let dy = (((point.y - vy as f64) * 65535.0) / (vh - 1).max(1) as f64).round() as i32;

        let mut flags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE;
        if down {
            flags |= MOUSEEVENTF_LEFTDOWN;
        }
        if up {
            flags |= MOUSEEVENTF_LEFTUP;
        }

        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx,
                    dy,
                    mouseData: 0,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: SYNTHETIC_MARKER,
                },
            },
        };
        let _ = SendInput(&[input], size_of::<INPUT>() as i32);
    }
}

unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code != HC_ACTION as i32 || should_passthrough_all() {
        return CallNextHookEx(None, code, wparam, lparam);
    }
    let info = &*(lparam.0 as *const MSLLHOOKSTRUCT);
    if info.dwExtraInfo == SYNTHETIC_MARKER {
        return CallNextHookEx(None, code, wparam, lparam);
    }

    let point = Point::new(info.pt.x as f64, info.pt.y as f64);
    let mods = current_modifiers();
    let msg = wparam.0 as u32;

    // Short lock (<1us, no I/O or SendInput inside): guarantees button-up events are never dropped on contention.
    let outcome: HookOutcome = {
        let mut fsm = match state().fsm.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        match msg {
            WM_MBUTTONDOWN => fsm.on_trigger_down(TriggerButton::Middle, mods),
            WM_MBUTTONUP => fsm.on_trigger_up(TriggerButton::Middle),
            WM_XBUTTONDOWN => {
                let xbtn = ((info.mouseData >> 16) & 0xFFFF) as u16;
                if xbtn == XBUTTON1 {
                    fsm.on_trigger_down(TriggerButton::Back, mods)
                } else if xbtn == XBUTTON2 {
                    fsm.on_trigger_down(TriggerButton::Forward, mods)
                } else {
                    HookOutcome::pass()
                }
            }
            WM_XBUTTONUP => {
                let xbtn = ((info.mouseData >> 16) & 0xFFFF) as u16;
                if xbtn == XBUTTON1 {
                    fsm.on_trigger_up(TriggerButton::Back)
                } else if xbtn == XBUTTON2 {
                    fsm.on_trigger_up(TriggerButton::Forward)
                } else {
                    HookOutcome::pass()
                }
            }
            WM_MOUSEWHEEL => {
                let delta = ((info.mouseData >> 16) as u16) as i16;
                let notches = delta as f64 / 120.0;
                fsm.on_wheel(notches)
            }
            WM_LBUTTONDOWN => fsm.on_left_down(point, mods),
            WM_MOUSEMOVE => fsm.on_mouse_move(point, mods),
            WM_LBUTTONUP => fsm.on_left_up(point),
            WM_RBUTTONDOWN => fsm.on_right_down(point),
            WM_RBUTTONUP => fsm.on_right_up(),
            _ => HookOutcome::pass(),
        }
    };

    dispatch_actions(outcome.actions);

    if outcome.swallow {
        LRESULT(1)
    } else {
        CallNextHookEx(None, code, wparam, lparam)
    }
}

unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code != HC_ACTION as i32 || should_passthrough_all() {
        return CallNextHookEx(None, code, wparam, lparam);
    }
    let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
    if info.dwExtraInfo == SYNTHETIC_MARKER {
        return CallNextHookEx(None, code, wparam, lparam);
    }

    let vk = info.vkCode;
    let mods = current_modifiers();
    let msg = wparam.0 as u32;

    let outcome = {
        let mut fsm = match state().fsm.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        match msg {
            WM_KEYDOWN | WM_SYSKEYDOWN => fsm.on_key_down(vk, mods),
            WM_KEYUP | WM_SYSKEYUP => fsm.on_key_up(vk),
            _ => HookOutcome::pass(),
        }
    };

    dispatch_actions(outcome.actions);

    if outcome.swallow {
        LRESULT(1)
    } else {
        CallNextHookEx(None, code, wparam, lparam)
    }
}

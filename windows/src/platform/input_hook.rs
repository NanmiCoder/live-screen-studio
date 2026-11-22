use std::collections::HashMap;
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::Instant;

use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{
    GetCurrentThread, GetCurrentThreadId, SetThreadPriority, THREAD_PRIORITY_ABOVE_NORMAL,
    THREAD_PRIORITY_HIGHEST,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT,
    KEYEVENTF_KEYUP, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_VIRTUALDESK, MOUSEINPUT, MOUSE_EVENT_FLAGS, VK_CONTROL,
    VK_LCONTROL, VK_MENU, VK_RCONTROL, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetMessageW, GetSystemMetrics, PeekMessageW, PostMessageW,
    PostThreadMessageW, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, HC_ACTION,
    KBDLLHOOKSTRUCT, MSG, MSLLHOOKSTRUCT, PM_NOREMOVE, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
    SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_APP, WM_KEYDOWN,
    WM_KEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEMOVE,
    WM_MOUSEWHEEL, WM_QUIT, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SYSKEYDOWN, WM_SYSKEYUP,
    WM_XBUTTONDOWN, WM_XBUTTONUP, XBUTTON1, XBUTTON2,
};

use crate::core::annotation::HighlightKind;
use crate::core::geometry::{Point, Rect};
use crate::core::input_fsm::{HookOutcome, InputAction, InputFsm, Modifiers};
use crate::core::settings::{KeyCombo, TriggerButton};

const SYNTHETIC_MARKER: usize = 0x4C5A_0001;
const MAIN_THREAD_STALL_MS: u64 = 400;
pub const WM_INPUT_ACTION: u32 = WM_APP + 3;

struct SharedHookState {
    fsm: Mutex<InputFsm>,
    dispatch: Mutex<Option<HookDispatch>>,
    clock: Instant,
    main_heartbeat_ms: AtomicU64,
    /// True while main thread is intentionally inside a Win32 modal UI loop (tray popup / window drag).
    modal_paused: AtomicBool,
}

#[derive(Clone)]
struct HookDispatch {
    actions: Sender<InputAction>,
    replay: Sender<InputAction>,
    wake_window: isize,
}

static HOOK_STATE: OnceLock<SharedHookState> = OnceLock::new();

fn state() -> &'static SharedHookState {
    HOOK_STATE.get_or_init(|| SharedHookState {
        fsm: Mutex::new(InputFsm::default()),
        dispatch: Mutex::new(None),
        clock: Instant::now(),
        main_heartbeat_ms: AtomicU64::new(0),
        modal_paused: AtomicBool::new(false),
    })
}

/// Global low-level mouse & keyboard hook running on a dedicated high-priority thread.
pub struct InputHook {
    rx: Receiver<InputAction>,
    thread_id: u32,
    join: Option<JoinHandle<()>>,
    replay_join: Option<JoinHandle<()>>,
}

impl InputHook {
    pub fn start(wake_window: HWND) -> Result<Self, String> {
        let (tx, rx) = mpsc::channel();
        let (replay_tx, replay_rx) = mpsc::channel();
        state().modal_paused.store(true, Ordering::Relaxed);
        let replay_join = thread::Builder::new()
            .name("LiveZoom-InputReplay".to_string())
            .spawn(move || {
                unsafe {
                    let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
                }
                for action in replay_rx {
                    replay_input(action);
                }
            })
            .map_err(|e| format!("failed to spawn input replay thread: {e}"))?;

        let (ready_tx, ready_rx) = mpsc::channel::<Result<u32, String>>();

        let join = thread::Builder::new()
            .name("LiveZoom-InputHook".to_string())
            .spawn(move || unsafe {
                let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
                let tid = GetCurrentThreadId();

                let hinst = GetModuleHandleW(None)
                    .map(HINSTANCE::from)
                    .unwrap_or_default();
                let mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), hinst, 0);
                let key_hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), hinst, 0);

                match (mouse_hook, key_hook) {
                    (Ok(mh), Ok(kh)) => {
                        let mut msg = MSG::default();
                        let _ = PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE);
                        let _ = ready_tx.send(Ok(tid));
                        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
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

        let thread_id = ready_rx
            .recv()
            .map_err(|_| "hook thread exited early".to_string())??;
        *state().dispatch.lock().unwrap() = Some(HookDispatch {
            actions: tx,
            replay: replay_tx,
            wake_window: wake_window.0 as isize,
        });

        let hook = Self {
            rx,
            thread_id,
            join: Some(join),
            replay_join: Some(replay_join),
        };
        hook.set_modal_paused(false);
        Ok(hook)
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
        let actions = { state().fsm.lock().unwrap().set_drawing_armed(armed) };
        enqueue_actions(actions);
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

    /// Limits the virtual pen tip to the current monitor during a swallowed drag.
    pub fn set_drawing_bounds(&self, bounds: Rect) {
        state().fsm.lock().unwrap().cursor_bounds = Some(bounds);
    }
}

impl Drop for InputHook {
    fn drop(&mut self) {
        self.set_modal_paused(true);
        if let Ok(mut guard) = state().dispatch.lock() {
            *guard = None;
        }
        // Keep the hook pump alive until any queued input has been replayed.
        if let Some(join) = self.replay_join.take() {
            let _ = join.join();
        }
        if unsafe { PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) }.is_ok() {
            if let Some(j) = self.join.take() {
                let _ = j.join();
            }
        }
    }
}

fn now_ms() -> u64 {
    state().clock.elapsed().as_millis() as u64
}

fn should_passthrough_all() -> bool {
    if state().modal_paused.load(Ordering::Relaxed) {
        return true;
    }
    let last = state().main_heartbeat_ms.load(Ordering::Relaxed);
    now_ms().saturating_sub(last) > MAIN_THREAD_STALL_MS
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

fn enqueue_actions(actions: Vec<InputAction>) {
    if actions.is_empty() {
        return;
    }
    let dispatch = state().dispatch.lock().ok().and_then(|guard| guard.clone());
    let Some(dispatch) = dispatch else {
        return;
    };
    let mut wake_ui = false;
    for action in actions {
        match action {
            InputAction::ReplayLeftDown { .. }
            | InputAction::ReplayLeftUp(_)
            | InputAction::ReplayLeftClick { .. }
            | InputAction::MoveOsCursor(_) => {
                let _ = dispatch.replay.send(action);
            }
            _ => wake_ui |= dispatch.actions.send(action).is_ok(),
        }
    }
    if wake_ui {
        unsafe {
            let _ = PostMessageW(
                HWND(dispatch.wake_window as *mut _),
                WM_INPUT_ACTION,
                WPARAM(0),
                LPARAM(0),
            );
        }
    }
}

/// Replays clicks independently of both the low-level hook and the renderer.
fn replay_input(action: InputAction) {
    let inputs = match action {
        InputAction::ReplayLeftDown { point, strip_ctrl } => {
            if strip_ctrl {
                release_ctrl_keys();
            }
            vec![pointer_event(point, MOUSEEVENTF_LEFTDOWN)]
        }
        InputAction::ReplayLeftUp(point) => vec![pointer_event(point, MOUSEEVENTF_LEFTUP)],
        InputAction::ReplayLeftClick {
            down_point,
            up_point,
        } => vec![
            pointer_event(down_point, MOUSEEVENTF_LEFTDOWN),
            pointer_event(up_point, MOUSEEVENTF_LEFTUP),
        ],
        InputAction::MoveOsCursor(point) => vec![pointer_event(point, MOUSE_EVENT_FLAGS(0))],
        _ => return,
    };
    unsafe {
        let _ = SendInput(&inputs, size_of::<INPUT>() as i32);
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

fn pointer_event(point: Point, button: MOUSE_EVENT_FLAGS) -> INPUT {
    unsafe {
        let vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        let vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        let vw = GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1);
        let vh = GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1);

        let dx = (((point.x - vx as f64 + 0.5) * 65536.0) / vw as f64).floor() as i32;
        let dy = (((point.y - vy as f64 + 0.5) * 65536.0) / vh as f64).floor() as i32;

        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx,
                    dy,
                    mouseData: 0,
                    dwFlags: button
                        | MOUSEEVENTF_ABSOLUTE
                        | MOUSEEVENTF_VIRTUALDESK
                        | MOUSEEVENTF_MOVE,
                    time: 0,
                    dwExtraInfo: SYNTHETIC_MARKER,
                },
            },
        }
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

    enqueue_actions(outcome.actions);

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

    enqueue_actions(outcome.actions);

    if outcome.swallow {
        LRESULT(1)
    } else {
        CallNextHookEx(None, code, wparam, lparam)
    }
}

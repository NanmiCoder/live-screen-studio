use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::Instant;

use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{
    GetCurrentThread, GetCurrentThreadId, SetThreadPriority, THREAD_PRIORITY_HIGHEST,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VK_CONTROL, VK_MENU, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetMessageW, PeekMessageW, PostMessageW, PostThreadMessageW,
    SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, HC_ACTION, KBDLLHOOKSTRUCT, MSG,
    MSLLHOOKSTRUCT, PM_NOREMOVE, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_APP, WM_KEYDOWN, WM_KEYUP,
    WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEMOVE, WM_MOUSEWHEEL,
    WM_QUIT, WM_RBUTTONDOWN, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_XBUTTONDOWN, WM_XBUTTONUP, XBUTTON1,
    XBUTTON2,
};

use crate::core::annotation::HighlightKind;
use crate::core::geometry::{Point, Rect};
use crate::core::input_fsm::{HookOutcome, InputAction, InputFsm, Modifiers};
use crate::core::settings::{KeyCombo, TriggerButton};

const MAIN_THREAD_STALL_MS: u64 = 400;
pub const WM_INPUT_ACTION: u32 = WM_APP + 3;

#[derive(Default)]
struct HookInput {
    fsm: InputFsm,
    dispatch: Option<(Sender<InputAction>, isize)>,
    modal_paused: bool,
}

struct SharedHookState {
    input: Mutex<HookInput>,
    wake_pending: AtomicBool,
    clock: Instant,
    main_heartbeat_ms: AtomicU64,
}

static HOOK_STATE: OnceLock<SharedHookState> = OnceLock::new();

fn state() -> &'static SharedHookState {
    HOOK_STATE.get_or_init(|| SharedHookState {
        input: Mutex::new(HookInput::default()),
        wake_pending: AtomicBool::new(false),
        clock: Instant::now(),
        main_heartbeat_ms: AtomicU64::new(0),
    })
}

/// The hook thread owns physical input. The UI receives semantic commands and never replays buttons.
pub struct InputHook {
    rx: Receiver<InputAction>,
    thread_id: u32,
    join: Option<JoinHandle<()>>,
}

impl InputHook {
    pub fn start(wake_window: HWND) -> Result<Self, String> {
        let (tx, rx) = mpsc::channel();
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
        let hook = Self {
            rx,
            thread_id,
            join: Some(join),
        };
        hook.heartbeat();
        state().input.lock().unwrap().dispatch = Some((tx, wake_window.0 as isize));
        Ok(hook)
    }

    pub fn heartbeat(&self) {
        state().main_heartbeat_ms.store(now_ms(), Ordering::Relaxed);
    }

    pub fn set_modal_paused(&self, paused: bool) {
        if !paused {
            self.heartbeat();
        }
        let mut input = state().input.lock().unwrap();
        input.modal_paused = paused;
        let action = input.fsm.set_suspended(paused);
        publish(&input, action);
    }

    pub fn drain_actions(&self) -> Vec<InputAction> {
        state().wake_pending.store(false, Ordering::Release);
        self.rx.try_iter().collect()
    }

    pub fn configure(
        &self,
        enabled: bool,
        trigger: TriggerButton,
        shortcuts: HashMap<KeyCombo, HighlightKind>,
        undo: Option<KeyCombo>,
    ) {
        let mut input = state().input.lock().unwrap();
        let action = input.fsm.configure_trigger(enabled, trigger);
        input.fsm.shortcuts = shortcuts;
        input.fsm.undo_shortcut = undo;
        publish(&input, action);
    }

    pub fn set_drawing_armed(&self, armed: bool) {
        let mut input = state().input.lock().unwrap();
        let action = input.fsm.set_drawing_armed(armed);
        publish(&input, action);
    }

    pub fn set_keys_armed(&self, armed: bool) {
        state().input.lock().unwrap().fsm.set_keys_armed(armed);
    }

    pub fn set_has_strokes(&self, has: bool) {
        state().input.lock().unwrap().fsm.has_strokes = has;
    }

    pub fn set_drawing_area(&self, bounds: Rect, threshold_px: f64) {
        let mut input = state().input.lock().unwrap();
        input.fsm.drawing_bounds = Some(bounds);
        input.fsm.drag_threshold_px = threshold_px.max(2.0);
    }
}

impl Drop for InputHook {
    fn drop(&mut self) {
        state().input.lock().unwrap().dispatch = None;
        if unsafe { PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) }.is_ok() {
            if let Some(join) = self.join.take() {
                let _ = join.join();
            }
        }
    }
}

fn now_ms() -> u64 {
    state().clock.elapsed().as_millis() as u64
}

fn current_modifiers() -> Modifiers {
    unsafe {
        Modifiers {
            ctrl: GetAsyncKeyState(VK_CONTROL.0 as i32) < 0,
            alt: GetAsyncKeyState(VK_MENU.0 as i32) < 0,
            shift: GetAsyncKeyState(VK_SHIFT.0 as i32) < 0,
        }
    }
}

/// Publish while holding the input lock, so UI cancellation and hook events keep their order.
fn publish(input: &HookInput, actions: impl IntoIterator<Item = InputAction>) {
    let Some((tx, hwnd)) = input.dispatch.as_ref() else {
        return;
    };
    let mut sent = false;
    for action in actions {
        sent |= tx.send(action).is_ok();
    }
    let wake = &state().wake_pending;
    if sent && !wake.swap(true, Ordering::AcqRel) {
        if unsafe { PostMessageW(HWND(*hwnd as *mut _), WM_INPUT_ACTION, WPARAM(0), LPARAM(0)) }
            .is_err()
        {
            wake.store(false, Ordering::Release);
        }
    }
}

fn handle_input(event: impl FnOnce(&mut InputFsm) -> HookOutcome) -> bool {
    let shared = state();
    let mut input = shared.input.lock().unwrap();
    if input.dispatch.is_none() {
        return false;
    }
    let main_stalled = now_ms().saturating_sub(shared.main_heartbeat_ms.load(Ordering::Relaxed))
        > MAIN_THREAD_STALL_MS;
    let suspended = input.modal_paused || main_stalled;
    // Suspension rejects new gestures, but still consumes releases the hook already owns.
    let cancelled = input.fsm.set_suspended(suspended);
    let outcome = event(&mut input.fsm);
    publish(&input, cancelled.into_iter().chain(outcome.actions));
    outcome.swallow
}

unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code != HC_ACTION as i32 {
        return CallNextHookEx(None, code, wparam, lparam);
    }
    let info = &*(lparam.0 as *const MSLLHOOKSTRUCT);
    let point = Point::new(info.pt.x as f64, info.pt.y as f64);
    let msg = wparam.0 as u32;
    let swallow = handle_input(|fsm| match msg {
        WM_MBUTTONDOWN => fsm.on_trigger_down(TriggerButton::Middle, current_modifiers()),
        WM_MBUTTONUP => fsm.on_trigger_up(TriggerButton::Middle, point),
        WM_XBUTTONDOWN | WM_XBUTTONUP => {
            let button = match (info.mouseData >> 16) as u16 {
                XBUTTON1 => TriggerButton::Back,
                XBUTTON2 => TriggerButton::Forward,
                _ => return HookOutcome::pass(),
            };
            if msg == WM_XBUTTONDOWN {
                fsm.on_trigger_down(button, current_modifiers())
            } else {
                fsm.on_trigger_up(button, point)
            }
        }
        WM_MOUSEWHEEL => {
            let delta = (info.mouseData >> 16) as i16;
            fsm.on_wheel(delta as f64 / 120.0, point)
        }
        WM_LBUTTONDOWN => fsm.on_left_down(point, current_modifiers()),
        WM_MOUSEMOVE => fsm.on_mouse_move(point, GetAsyncKeyState(VK_SHIFT.0 as i32) < 0),
        WM_LBUTTONUP => fsm.on_left_up(),
        WM_RBUTTONDOWN => fsm.observe_click(point),
        _ => HookOutcome::pass(),
    });

    if swallow {
        LRESULT(1)
    } else {
        CallNextHookEx(None, code, wparam, lparam)
    }
}

unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code != HC_ACTION as i32 {
        return CallNextHookEx(None, code, wparam, lparam);
    }
    let vk = (*(lparam.0 as *const KBDLLHOOKSTRUCT)).vkCode;
    let swallow = handle_input(|fsm| match wparam.0 as u32 {
        WM_KEYDOWN | WM_SYSKEYDOWN => fsm.on_key_down(vk, current_modifiers()),
        WM_KEYUP | WM_SYSKEYUP => fsm.on_key_up(vk),
        _ => HookOutcome::pass(),
    });

    if swallow {
        LRESULT(1)
    } else {
        CallNextHookEx(None, code, wparam, lparam)
    }
}

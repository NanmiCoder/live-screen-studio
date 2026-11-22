use std::collections::HashMap;
use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use windows::core::w;
use windows::Win32::Foundation::{
    CloseHandle, GetLastError, HANDLE, HWND, LPARAM, LRESULT, WPARAM,
};
use windows::Win32::Graphics::Dwm::DwmFlush;
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{
    CreateMutexW, CreateWaitableTimerExW, SetWaitableTimer, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
    TIMER_ALL_ACCESS,
};
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Shell::{NINF_KEY, NIN_SELECT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, FindWindowW,
    MsgWaitForMultipleObjectsEx, PeekMessageW, PostMessageW, PostQuitMessage, RegisterClassW,
    TranslateMessage, MSG, MWMO_INPUTAVAILABLE, PM_REMOVE, QS_ALLINPUT, WM_CONTEXTMENU,
    WM_DISPLAYCHANGE, WM_ENDSESSION, WM_LBUTTONDBLCLK, WM_LBUTTONUP, WM_QUERYENDSESSION, WM_QUIT,
    WM_RBUTTONUP, WNDCLASSW,
};

use crate::core::annotation::{AnnotationItem, HighlightKind, InkLook};
use crate::core::camera::{CameraConfig, CameraPhase, ViewportMath, ZoomCamera};
use crate::core::cursor::{CursorMotion, CursorStyle};
use crate::core::geometry::{Point, Rect, Size};
use crate::core::input_fsm::InputAction;
use crate::core::settings::{AppSettings, CloseWindowBehavior, KeyCombo};
use crate::platform::console::{ConsoleEvent, ConsoleWindow};
use crate::platform::cursor_system::{ActiveCursorKind, SystemCursorManager};
use crate::platform::display::{cursor_position, display_under_point, DisplayInfo};
use crate::platform::input_hook::{InputHook, WM_INPUT_ACTION};
use crate::platform::magnifier::MagnifierHost;
use crate::platform::ocr::{capture_ocr_band_sync, is_chinese_ocr_available, recognize_band_async};
use crate::platform::overlay::{
    ClickMarkDraw, CursorDraw, CursorGraphic, OverlayFrame, OverlayWindow,
};
use crate::platform::tray::{
    is_launch_at_login_enabled, set_launch_at_login, TrayIcon, MENU_OPEN_CONSOLE, MENU_QUIT,
    MENU_TOGGLE_AUTOSTART, MENU_TOGGLE_ENABLED, WM_ACTIVATE_EXISTING, WM_TRAY_ICON,
};

const MSG_WINDOW_CLASS: windows::core::PCWSTR = w!("LiveZoomMessageWindow");
const NIN_KEYSELECT: u32 = NIN_SELECT | NINF_KEY;

struct ActiveClick {
    /// Global physical pixel position.
    position: Point,
    created_at: f64,
}

enum SysMsg {
    OpenConsole,
    ShowMenu,
    DisplayChanged,
    Quit,
}

static SYS_TX: std::sync::OnceLock<std::sync::Mutex<Option<Sender<SysMsg>>>> =
    std::sync::OnceLock::new();

/// Schedules camera ticks without waiting on DWM or holding up the UI message queue.
struct FrameTimer(Option<HANDLE>);

impl FrameTimer {
    fn new() -> Self {
        Self(unsafe {
            CreateWaitableTimerExW(
                None,
                None,
                CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                TIMER_ALL_ACCESS.0,
            )
            .ok()
        })
    }

    fn wait_until(&self, deadline: Instant) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return;
        }
        unsafe {
            if let Some(timer) = self.0 {
                // A negative due time is relative, in 100 ns units.
                let due = -(remaining.as_nanos().div_ceil(100).max(1) as i64);
                if SetWaitableTimer(timer, &due, 0, None, None, false).is_ok() {
                    MsgWaitForMultipleObjectsEx(
                        Some(&[timer]),
                        u32::MAX,
                        QS_ALLINPUT,
                        MWMO_INPUTAVAILABLE,
                    );
                    return;
                }
            }
            let timeout = remaining.as_micros().div_ceil(1000) as u32;
            MsgWaitForMultipleObjectsEx(None, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        }
    }
}

impl Drop for FrameTimer {
    fn drop(&mut self) {
        if let Some(timer) = self.0 {
            unsafe {
                let _ = CloseHandle(timer);
            }
        }
    }
}

pub fn run() -> Result<(), String> {
    let instance_mutex = unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        // Single-instance check (kept alive until run() exits).
        let mutex = CreateMutexW(None, true, w!("Local\\LiveZoomWindowsSingleInstance")).ok();
        if GetLastError() == windows::Win32::Foundation::ERROR_ALREADY_EXISTS {
            // Wake the running instance and bring up its console window.
            if let Ok(existing) = FindWindowW(MSG_WINDOW_CLASS, None) {
                if !existing.0.is_null() {
                    let _ = PostMessageW(existing, WM_ACTIVATE_EXISTING, WPARAM(0), LPARAM(0));
                }
            }
            if let Some(h) = mutex {
                let _ = CloseHandle(h);
            }
            return Ok(());
        }
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        mutex
    };

    let result = run_inner();

    unsafe {
        CoUninitialize();
        if let Some(h) = instance_mutex {
            let _ = CloseHandle(h);
        }
    }
    result
}

fn make_camera_config(settings: &AppSettings, display: &DisplayInfo) -> CameraConfig {
    let mut cfg = CameraConfig::default();
    let mut preset = settings.follow_style.preset();
    // Scale logical point/sec speed ceiling by physical monitor DPI so 4K 200% screens feel identical to 100%.
    preset.max_visual_speed *= display.scale.max(1.0);
    cfg.follow = preset;
    cfg
}

#[derive(Clone, Copy)]
struct InkDrag {
    pointer_start: Point,
    origin: Point,
    zoom: f64,
}

impl InkDrag {
    fn point(self, pointer: Point, display: Size) -> Point {
        // The camera is frozen, so map physical movement to equally sized screen-space ink.
        let axis = |value: f64, start: f64, origin: f64, extent: f64| {
            let end = origin + (extent - 1.0) / self.zoom;
            (start.clamp(origin, end) + (value - start) / self.zoom).clamp(origin, end)
        };
        Point::new(
            axis(
                pointer.x,
                self.pointer_start.x,
                self.origin.x,
                display.width,
            ),
            axis(
                pointer.y,
                self.pointer_start.y,
                self.origin.y,
                display.height,
            ),
        )
    }
}

fn run_inner() -> Result<(), String> {
    let mut settings = AppSettings::load();
    settings.launch_at_login = is_launch_at_login_enabled();

    let initial_display = display_under_point(cursor_position())
        .ok_or_else(|| "no active display found".to_string())?;

    let (sys_tx, sys_rx) = mpsc::channel();
    {
        let cell = SYS_TX.get_or_init(|| std::sync::Mutex::new(None));
        *cell.lock().unwrap() = Some(sys_tx);
    }

    let msg_hwnd = create_message_window()?;
    let tray = TrayIcon::new(msg_hwnd)?;
    tray.update_tooltip(settings.enabled, settings.trigger);

    let mut magnifier = MagnifierHost::new(initial_display.bounds)?;
    let mut overlay = OverlayWindow::new(initial_display.bounds)?;
    let mut cursor_sys = SystemCursorManager::new();
    let input_hook = InputHook::start(msg_hwnd)?;

    let (console_tx, console_rx) = mpsc::channel::<ConsoleEvent>();
    let (ocr_tx, ocr_rx) = mpsc::channel::<(u64, HighlightKind, Option<Rect>)>();
    // Runs on a dedicated short-lived MTA thread so main thread's STA is never disturbed.
    let chinese_ocr = is_chinese_ocr_available();

    let mut console: Option<ConsoleWindow> = None;
    let mut console_hidden_for_zoom = false;

    let sync_exclusions = |mag: &MagnifierHost, ov: &OverlayWindow, con: &Option<ConsoleWindow>| {
        let mut excl = vec![ov.hwnd(), msg_hwnd];
        if let Some(c) = con {
            excl.push(c.hwnd());
        }
        mag.set_excluded_windows(&excl);
    };
    sync_exclusions(&magnifier, &overlay, &console);

    sync_hook_settings(&input_hook, &settings);

    let start_instant = Instant::now();
    let mut last_frame = start_instant;
    let mut next_frame = start_instant;
    let mut scheduled_hz = initial_display.refresh_hz.clamp(30, 240);
    let frame_timer = FrameTimer::new();
    let mut active_display = initial_display;
    let mut camera: Option<ZoomCamera> = None;
    let mut last_zoom_origin = Point::ZERO;
    let mut last_zoom = 1.0f64;
    let mut motion = CursorMotion::new(cursor_position(), 0.0);
    let mut zoom_generation = 0u64;
    let mut annotations: Vec<AnnotationItem> = Vec::new();
    let mut annotations_rev: u64 = 0;
    let mut ink_drag: Option<InkDrag> = None;
    let mut clicks: Vec<ActiveClick> = Vec::new();
    let mut in_modal_ui = false;
    let mut ensure_overlay_topmost = false;

    // Open console automatically on launch so user sees status & shortcuts right away.
    if let Ok(win) = ConsoleWindow::open(
        &active_display,
        settings.clone(),
        chinese_ocr,
        console_tx.clone(),
    ) {
        console = Some(win);
        sync_exclusions(&magnifier, &overlay, &console);
    }

    let mut running = true;
    while running {
        input_hook.heartbeat();

        // 1. Pump Win32 messages (tray, console WebView2, display change, shutdown).
        unsafe {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    running = false;
                    break;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        if !running {
            break;
        }

        let now = start_instant.elapsed().as_secs_f64();

        // Helper closure to cleanly exit zoom mode from any trigger (disable toggle, display change, console open).
        let reset_zoom = |camera: &mut Option<ZoomCamera>,
                          magnifier: &mut MagnifierHost,
                          cursor_sys: &mut SystemCursorManager,
                          annotations: &mut Vec<AnnotationItem>,
                          annotations_rev: &mut u64,
                          ink_drag: &mut Option<InkDrag>,
                          console: &mut Option<ConsoleWindow>,
                          console_hidden_for_zoom: &mut bool| {
            if camera.is_some() {
                *camera = None;
                magnifier.hide();
                cursor_sys.restore();
                input_hook.set_drawing_armed(false);
                input_hook.set_keys_armed(false);
                annotations.clear();
                *annotations_rev = annotations_rev.wrapping_add(1);
                *ink_drag = None;
                input_hook.set_has_strokes(false);
                if *console_hidden_for_zoom {
                    *console_hidden_for_zoom = false;
                    if let Some(ref mut c) = console {
                        c.set_visible(true);
                    }
                }
            }
        };

        // 2. Process Tray & system events.
        while let Ok(ev) = sys_rx.try_recv() {
            match ev {
                SysMsg::OpenConsole => {
                    reset_zoom(
                        &mut camera,
                        &mut magnifier,
                        &mut cursor_sys,
                        &mut annotations,
                        &mut annotations_rev,
                        &mut ink_drag,
                        &mut console,
                        &mut console_hidden_for_zoom,
                    );
                    if let Some(ref mut c) = console {
                        c.focus();
                    } else if let Ok(win) = ConsoleWindow::open(
                        &active_display,
                        settings.clone(),
                        chinese_ocr,
                        console_tx.clone(),
                    ) {
                        console = Some(win);
                        sync_exclusions(&magnifier, &overlay, &console);
                    }
                }
                SysMsg::ShowMenu => {
                    reset_zoom(
                        &mut camera,
                        &mut magnifier,
                        &mut cursor_sys,
                        &mut annotations,
                        &mut annotations_rev,
                        &mut ink_drag,
                        &mut console,
                        &mut console_hidden_for_zoom,
                    );
                    // Keep the popup and pointer in native screen coordinates.
                    cursor_sys.restore();
                    overlay.hide();
                    input_hook.set_modal_paused(true);
                    let cmd = tray.show_menu(settings.enabled, settings.launch_at_login);
                    input_hook.set_modal_paused(false);
                    if let Some(cmd) = cmd {
                        match cmd {
                            MENU_OPEN_CONSOLE => {
                                if let Some(ref mut c) = console {
                                    c.focus();
                                } else if let Ok(win) = ConsoleWindow::open(
                                    &active_display,
                                    settings.clone(),
                                    chinese_ocr,
                                    console_tx.clone(),
                                ) {
                                    console = Some(win);
                                    sync_exclusions(&magnifier, &overlay, &console);
                                }
                            }
                            MENU_TOGGLE_ENABLED => {
                                settings.enabled = !settings.enabled;
                                settings.save();
                                tray.update_tooltip(settings.enabled, settings.trigger);
                                sync_hook_settings(&input_hook, &settings);
                                if let Some(ref c) = console {
                                    c.push_settings(&settings);
                                }
                            }
                            MENU_TOGGLE_AUTOSTART => {
                                let next = !settings.launch_at_login;
                                if set_launch_at_login(next) {
                                    settings.launch_at_login = next;
                                    settings.save();
                                    if let Some(ref c) = console {
                                        c.push_settings(&settings);
                                    }
                                }
                            }
                            MENU_QUIT => {
                                running = false;
                            }
                            _ => {}
                        }
                    }
                }
                SysMsg::DisplayChanged => {
                    reset_zoom(
                        &mut camera,
                        &mut magnifier,
                        &mut cursor_sys,
                        &mut annotations,
                        &mut annotations_rev,
                        &mut ink_drag,
                        &mut console,
                        &mut console_hidden_for_zoom,
                    );
                    overlay.hide();
                    cursor_sys.restore();
                    if let Some(disp) = display_under_point(cursor_position()) {
                        active_display = disp;
                        let _ = magnifier.set_display_bounds(active_display.bounds);
                        overlay.set_bounds(active_display.bounds);
                        sync_exclusions(&magnifier, &overlay, &console);
                    }
                }
                SysMsg::Quit => running = false,
            }
            if !running {
                break;
            }
        }
        if !running {
            break;
        }

        // 3. Process Console UI events.
        while let Ok(ev) = console_rx.try_recv() {
            match ev {
                ConsoleEvent::SettingsUpdated(mut new_settings) => {
                    // Preserve conflict-checked shortcuts managed via ShortcutSet.
                    new_settings.shortcuts = settings.shortcuts.clone();
                    new_settings.undo_shortcut = settings.undo_shortcut.clone();
                    if new_settings.launch_at_login != settings.launch_at_login {
                        let _ = set_launch_at_login(new_settings.launch_at_login);
                    }
                    let draw_changed = new_settings.draw_while_zoomed != settings.draw_while_zoomed;
                    settings = new_settings;
                    settings.save();
                    tray.update_tooltip(settings.enabled, settings.trigger);
                    sync_hook_settings(&input_hook, &settings);
                    if !settings.enabled {
                        reset_zoom(
                            &mut camera,
                            &mut magnifier,
                            &mut cursor_sys,
                            &mut annotations,
                            &mut annotations_rev,
                            &mut ink_drag,
                            &mut console,
                            &mut console_hidden_for_zoom,
                        );
                    } else if let Some(ref mut cam) = camera {
                        cam.config = make_camera_config(&settings, &active_display);
                        if draw_changed {
                            input_hook.set_drawing_armed(settings.draw_while_zoomed);
                        }
                    }
                }
                ConsoleEvent::ShortcutSet { target, shortcut } => {
                    if let Some(kind) = target.as_highlight() {
                        settings.set_shortcut(kind, shortcut);
                    } else {
                        settings.set_undo_shortcut(shortcut);
                    }
                    settings.save();
                    sync_hook_settings(&input_hook, &settings);
                    if let Some(ref c) = console {
                        c.push_settings(&settings);
                    }
                }
                ConsoleEvent::EnterModalMove => {
                    in_modal_ui = true;
                    cursor_sys.restore();
                    overlay.hide();
                    input_hook.set_modal_paused(true);
                }
                ConsoleEvent::ExitModalMove => {
                    in_modal_ui = false;
                    input_hook.set_modal_paused(false);
                }
                ConsoleEvent::Closed => {
                    console = None;
                    console_hidden_for_zoom = false;
                    in_modal_ui = false;
                    input_hook.set_modal_paused(false);
                    sync_exclusions(&magnifier, &overlay, &console);
                    if settings.close_window_behavior == CloseWindowBehavior::QuitApp {
                        running = false;
                    }
                }
                ConsoleEvent::Quit => running = false,
            }
            if !running {
                break;
            }
        }
        if !running {
            break;
        }

        // Keep the active stroke at the end of the list until the pen is released.
        if ink_drag.is_none() {
            while let Ok((generation, kind, line_opt)) = ocr_rx.try_recv() {
                if generation != zoom_generation {
                    continue;
                }
                if let (Some(line), Some(ref cam)) = (line_opt, &camera) {
                    if cam.phase() == CameraPhase::Zoomed || cam.phase() == CameraPhase::ZoomingIn {
                        if kind == HighlightKind::Spotlight {
                            annotations.retain(|a| !a.is_spotlight());
                        }
                        let look = InkLook {
                            style: settings.ink_style,
                            color: settings.ink_color.rgba(),
                            width: settings.stroke_width,
                        };
                        annotations.push(AnnotationItem::new_highlight(
                            kind,
                            line,
                            active_display.size(),
                            look,
                            cam.zoom(),
                            now,
                        ));
                        annotations_rev = annotations_rev.wrapping_add(1);
                        input_hook.set_has_strokes(!annotations.is_empty());
                    }
                }
            }
        }

        // 5. Process input hook actions.
        let actions = input_hook.drain_actions();
        let needs_frame = actions.iter().any(|action| {
            matches!(
                action,
                InputAction::ToggleZoom(_)
                    | InputAction::CancelZoom
                    | InputAction::AdjustZoom { .. }
            )
        });
        for action in actions {
            match action {
                InputAction::CancelZoom => reset_zoom(
                    &mut camera,
                    &mut magnifier,
                    &mut cursor_sys,
                    &mut annotations,
                    &mut annotations_rev,
                    &mut ink_drag,
                    &mut console,
                    &mut console_hidden_for_zoom,
                ),
                InputAction::ToggleZoom(at) | InputAction::AdjustZoom { at, .. }
                    if settings.enabled =>
                {
                    let adjustment = match action {
                        InputAction::AdjustZoom { steps, .. } => Some(steps),
                        _ => None,
                    };
                    if camera.is_some() && !active_display.bounds.contains_pixel(at) {
                        reset_zoom(
                            &mut camera,
                            &mut magnifier,
                            &mut cursor_sys,
                            &mut annotations,
                            &mut annotations_rev,
                            &mut ink_drag,
                            &mut console,
                            &mut console_hidden_for_zoom,
                        );
                        overlay.hide();
                    }
                    if let Some(cam) = camera.as_mut() {
                        let local = active_display.to_local(at);
                        if let Some(steps) = adjustment {
                            cam.adjust_zoom((0.1 * steps).exp());
                        } else if cam.phase() == CameraPhase::ZoomingOut {
                            cam.zoom_in(settings.default_zoom, local, now);
                            input_hook.set_drawing_armed(settings.draw_while_zoomed);
                            input_hook.set_keys_armed(true);
                        } else {
                            cam.set_follow_paused(false);
                            cam.zoom_out(local, now);
                            input_hook.set_drawing_armed(false);
                            input_hook.set_keys_armed(false);
                            annotations.clear();
                            annotations_rev = annotations_rev.wrapping_add(1);
                            ink_drag = None;
                            input_hook.set_has_strokes(false);
                        }
                    } else if adjustment.is_none_or(|steps| steps > 0.0) {
                        if let Some(disp) = display_under_point(at) {
                            if magnifier.set_display_bounds(disp.bounds).is_err() {
                                continue;
                            }
                            active_display = disp;
                            overlay.set_bounds(active_display.bounds);
                            if let Some(ref mut c) = console {
                                c.set_visible(false);
                                console_hidden_for_zoom = true;
                            }
                            sync_exclusions(&magnifier, &overlay, &console);

                            let cfg = make_camera_config(&settings, &active_display);
                            let mut cam = ZoomCamera::new(active_display.size(), cfg);
                            cam.zoom_in(settings.default_zoom, active_display.to_local(at), now);
                            camera = Some(cam);
                            zoom_generation = zoom_generation.wrapping_add(1);
                            ensure_overlay_topmost = true;
                            input_hook.set_drawing_area(
                                active_display.bounds,
                                4.0 * active_display.scale,
                            );
                            input_hook.set_drawing_armed(settings.draw_while_zoomed);
                            input_hook.set_keys_armed(true);
                        }
                    }
                }
                InputAction::Click(pt) => {
                    clicks.push(ActiveClick {
                        position: pt,
                        created_at: now,
                    });
                }
                InputAction::StrokeBegan(pt) => {
                    if let Some(ref mut cam) = camera {
                        cam.set_follow_paused(true);
                        let drag = InkDrag {
                            pointer_start: active_display.to_local(pt),
                            origin: last_zoom_origin,
                            zoom: last_zoom,
                        };
                        let local = drag.point(drag.pointer_start, active_display.size());
                        let look = InkLook {
                            style: settings.ink_style,
                            color: settings.ink_color.rgba(),
                            width: settings.stroke_width,
                        };
                        annotations.push(AnnotationItem::new_stroke(local, look, last_zoom, now));
                        annotations_rev = annotations_rev.wrapping_add(1);
                        ink_drag = Some(drag);
                        input_hook.set_has_strokes(true);
                    }
                }
                InputAction::StrokeMoved { point, straight } => {
                    if let Some(drag) = ink_drag {
                        let local =
                            drag.point(active_display.to_local(point), active_display.size());
                        if annotations
                            .last_mut()
                            .is_some_and(|last| last.extend(local, straight))
                        {
                            annotations_rev = annotations_rev.wrapping_add(1);
                        }
                    }
                }
                InputAction::StrokeEnded => {
                    ink_drag = None;
                    if let Some(ref mut cam) = camera {
                        cam.set_follow_paused(false);
                    }
                }
                InputAction::UndoStroke => {
                    annotations.pop();
                    annotations_rev = annotations_rev.wrapping_add(1);
                    // End the active drag so it cannot extend the previous stroke.
                    ink_drag = None;
                    if let Some(ref mut cam) = camera {
                        cam.set_follow_paused(false);
                    }
                    input_hook.set_has_strokes(!annotations.is_empty());
                }
                InputAction::ClearStrokes => {
                    annotations.clear();
                    annotations_rev = annotations_rev.wrapping_add(1);
                    ink_drag = None;
                    if let Some(ref mut cam) = camera {
                        cam.set_follow_paused(false);
                    }
                    input_hook.set_has_strokes(false);
                }
                InputAction::Highlight(kind) => {
                    // Toggle spotlight off immediately if one is already active (matches macOS).
                    if kind == HighlightKind::Spotlight
                        && annotations.iter().any(|a| a.is_spotlight())
                    {
                        annotations.retain(|a| !a.is_spotlight());
                        annotations_rev = annotations_rev.wrapping_add(1);
                        input_hook.set_has_strokes(!annotations.is_empty());
                        continue;
                    }
                    if camera.is_some() {
                        let cur_global = cursor_position();
                        let cur_local = active_display.to_local(cur_global);
                        // Momentarily hide overlay for 1 DWM frame if annotations/spotlight exist so OCR sees clean text.
                        let temporarily_hidden = overlay.is_visible() && !annotations.is_empty();
                        if temporarily_hidden {
                            overlay.hide();
                            unsafe {
                                let _ = DwmFlush();
                            }
                        }
                        let band = capture_ocr_band_sync(
                            &active_display,
                            cur_local,
                            last_zoom_origin,
                            last_zoom,
                        );
                        if temporarily_hidden {
                            ensure_overlay_topmost = true;
                        }
                        if let Some(band) = band {
                            let tx = ocr_tx.clone();
                            recognize_band_async(band, move |line| {
                                let _ = tx.send((zoom_generation, kind, line));
                            });
                        }
                    }
                }
                InputAction::ToggleZoom(_) | InputAction::AdjustZoom { .. } => {}
            }
        }

        // Skip rendering while console is inside a modal Win32 drag/resize loop.
        if in_modal_ui {
            frame_timer.wait_until(Instant::now() + Duration::from_millis(16));
            continue;
        }

        // 6. Update camera & cursor motion.
        let frame_start = Instant::now();
        if frame_start < next_frame && !needs_frame {
            frame_timer.wait_until(next_frame);
            continue;
        }
        let now = frame_start.duration_since(start_instant).as_secs_f64();
        let dt = frame_start
            .duration_since(last_frame)
            .as_secs_f64()
            .min(0.05);
        last_frame = frame_start;
        let raw_cursor_global = cursor_position();
        if !active_display.bounds.contains_pixel(raw_cursor_global) {
            // Finish the old display immediately. Its overlay cannot show a pointer on another display.
            reset_zoom(
                &mut camera,
                &mut magnifier,
                &mut cursor_sys,
                &mut annotations,
                &mut annotations_rev,
                &mut ink_drag,
                &mut console,
                &mut console_hidden_for_zoom,
            );
            if let Some(disp) = display_under_point(raw_cursor_global) {
                if disp.handle != active_display.handle {
                    overlay.hide();
                    cursor_sys.restore();
                    active_display = disp;
                    overlay.set_bounds(active_display.bounds);
                    motion.jump(raw_cursor_global, now);
                }
            }
        }

        // A zoomed hotspot is an input coordinate; keep its position exact.
        motion.smooth_time = if settings.smooth_cursor && camera.is_none() {
            0.06
        } else {
            0.0
        };
        motion.idle_delay = if settings.hide_idle_cursor {
            Some(settings.idle_delay)
        } else {
            None
        };
        motion.update(raw_cursor_global, ink_drag.is_some(), now, dt);

        // Update ZoomCamera & MagnifierHost (exact integer origin returned for pixel-locked overlay).
        let zoom_frame = if let Some(ref mut cam) = camera {
            let local_cursor = active_display.to_local(raw_cursor_global);
            cam.update(local_cursor, now, dt);
            if ink_drag.is_none() {
                cam.keep_cursor_visible(local_cursor);
            }
            if cam.phase() == CameraPhase::Idle {
                magnifier.hide();
                camera = None;
                input_hook.set_drawing_armed(false);
                input_hook.set_keys_armed(false);
                if console_hidden_for_zoom {
                    console_hidden_for_zoom = false;
                    if let Some(ref mut c) = console {
                        c.set_visible(true);
                    }
                }
                Ok((1.0, Point::ZERO))
            } else {
                let zoom = cam.zoom() as f32 as f64;
                let viewport = ViewportMath::rect(cam.center(), zoom, active_display.size());
                magnifier
                    .render(viewport, zoom)
                    .map(|origin| (zoom, origin))
            }
        } else {
            Ok((1.0, Point::ZERO))
        };
        let (zoom, zoom_origin) = match zoom_frame {
            Ok(frame) => frame,
            Err(()) => {
                reset_zoom(
                    &mut camera,
                    &mut magnifier,
                    &mut cursor_sys,
                    &mut annotations,
                    &mut annotations_rev,
                    &mut ink_drag,
                    &mut console,
                    &mut console_hidden_for_zoom,
                );
                (1.0, Point::ZERO)
            }
        };
        last_zoom_origin = zoom_origin;
        last_zoom = zoom;

        // 7. Synchronize OS cursor hiding (hides ALL standard OS cursors while zoomed so none sit at unzoomed coords).
        let is_zoomed_now = camera.is_some();
        let custom_cursor_enabled = settings.enabled
            && settings.cursor_style != CursorStyle::System
            && (settings.custom_cursor_always || is_zoomed_now);
        let replace_hand = settings.cursor_style.replaces_pointing_hand();

        // 8. Build click marks & cursor draw descriptors.
        let click_dur = settings.click_effect.duration();
        clicks.retain(|c| now - c.created_at < click_dur);
        let click_color = settings.click_color.rgba();
        let click_marks: Vec<ClickMarkDraw> = clicks
            .iter()
            .filter_map(|c| {
                let look = settings.click_effect.appearance(now - c.created_at)?;
                let local = active_display.to_local(c.position);
                let screen_pt = Point::new(
                    (local.x - zoom_origin.x) * zoom,
                    (local.y - zoom_origin.y) * zoom,
                );
                Some(ClickMarkDraw {
                    center: screen_pt,
                    look,
                    color: click_color,
                })
            })
            .collect();

        let cursor_zoom_scale = zoom.sqrt();
        let mut cursor_local = active_display.to_local(motion.position());
        if let Some(drag) = ink_drag {
            cursor_local = drag.point(cursor_local, active_display.size());
        }
        let screen_pt = Point::new(
            (cursor_local.x - zoom_origin.x) * zoom,
            (cursor_local.y - zoom_origin.y) * zoom,
        );
        let draw_cursor =
            match cursor_sys.prepare_cursor(is_zoomed_now, custom_cursor_enabled, replace_hand) {
                ActiveCursorKind::None => None,
                ActiveCursorKind::CustomVector => Some(CursorDraw {
                    graphic: CursorGraphic::Vector(settings.cursor_style),
                    position: screen_pt,
                    pixel_scale: settings.cursor_size * active_display.scale * cursor_zoom_scale,
                    bitmap_zoom: cursor_zoom_scale,
                    opacity: motion.opacity(),
                }),
                ActiveCursorKind::SystemBitmap(sys_bmp) => Some(CursorDraw {
                    graphic: CursorGraphic::SystemBitmap(sys_bmp),
                    position: screen_pt,
                    pixel_scale: active_display.scale * cursor_zoom_scale,
                    bitmap_zoom: cursor_zoom_scale,
                    opacity: motion.opacity(),
                }),
            };

        // 9. Render transparent overlay (skips GPU work when frame is static; recovers or restores cursor on GPU reset).
        let frame = OverlayFrame {
            now,
            display_scale: active_display.scale,
            zoom_origin,
            zoom,
            annotations_rev,
            annotations: &annotations,
            click_marks: &click_marks,
            cursor: draw_cursor,
            ensure_topmost: ensure_overlay_topmost,
        };
        ensure_overlay_topmost = false;

        if overlay.render(&frame).is_ok() {
            if overlay.is_ready() {
                cursor_sys.sync(is_zoomed_now, custom_cursor_enabled, replace_hand);
            } else {
                cursor_sys.restore();
            }
        } else {
            overlay.hide();
            cursor_sys.restore();
            reset_zoom(
                &mut camera,
                &mut magnifier,
                &mut cursor_sys,
                &mut annotations,
                &mut annotations_rev,
                &mut ink_drag,
                &mut console,
                &mut console_hidden_for_zoom,
            );
        }

        let refresh_hz = active_display.refresh_hz.clamp(30, 240);
        let period = Duration::from_secs_f64(1.0 / refresh_hz as f64);
        if refresh_hz != scheduled_hz {
            scheduled_hz = refresh_hz;
            next_frame = frame_start + period;
        } else if let Some(late) = frame_start.checked_duration_since(next_frame) {
            // Skip missed slots without shifting the timeline on every frame.
            let remainder = (late.as_nanos() % period.as_nanos()) as u64;
            next_frame = frame_start + period - Duration::from_nanos(remainder);
        }
        frame_timer.wait_until(next_frame);
    }

    magnifier.hide();
    overlay.hide();
    cursor_sys.restore();
    input_hook.set_drawing_armed(false);
    drop(input_hook);
    drop(tray);
    unsafe {
        let _ = DestroyWindow(msg_hwnd);
    }
    Ok(())
}

fn sync_hook_settings(hook: &InputHook, settings: &AppSettings) {
    let mut map: HashMap<KeyCombo, HighlightKind> = HashMap::new();
    for (&kind, sc) in &settings.shortcuts {
        map.insert(sc.combo(), kind);
    }
    hook.configure(
        settings.enabled,
        settings.trigger,
        map,
        settings.undo_shortcut.as_ref().map(|s| s.combo()),
    );
}

fn create_message_window() -> Result<HWND, String> {
    unsafe {
        let hinst = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let wc = WNDCLASSW {
            lpfnWndProc: Some(msg_wnd_proc),
            hInstance: hinst.into(),
            lpszClassName: MSG_WINDOW_CLASS,
            ..Default::default()
        };
        RegisterClassW(&wc);
        CreateWindowExW(
            Default::default(),
            MSG_WINDOW_CLASS,
            w!("LiveZoom"),
            Default::default(),
            0,
            0,
            0,
            0,
            None,
            None,
            hinst,
            None,
        )
        .map_err(|e| format!("CreateWindowExW(MsgWindow) failed: {e}"))
    }
}

unsafe extern "system" fn msg_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_INPUT_ACTION => LRESULT(0),
        WM_TRAY_ICON => {
            let ev = (lparam.0 & 0xFFFF) as u32;
            let legacy = (lparam.0 >> 16) == 0;
            if let Some(cell) = SYS_TX.get() {
                if let Some(ref tx) = *cell.lock().unwrap() {
                    if matches!(ev, NIN_SELECT | NIN_KEYSELECT | WM_LBUTTONDBLCLK)
                        || (legacy && ev == WM_LBUTTONUP)
                    {
                        let _ = tx.send(SysMsg::OpenConsole);
                    } else if ev == WM_CONTEXTMENU || (legacy && ev == WM_RBUTTONUP) {
                        let _ = tx.send(SysMsg::ShowMenu);
                    }
                }
            }
            LRESULT(0)
        }
        WM_ACTIVATE_EXISTING => {
            if let Some(cell) = SYS_TX.get() {
                if let Some(ref tx) = *cell.lock().unwrap() {
                    let _ = tx.send(SysMsg::OpenConsole);
                }
            }
            LRESULT(0)
        }
        WM_DISPLAYCHANGE => {
            if let Some(cell) = SYS_TX.get() {
                if let Some(ref tx) = *cell.lock().unwrap() {
                    let _ = tx.send(SysMsg::DisplayChanged);
                }
            }
            LRESULT(0)
        }
        WM_QUERYENDSESSION => {
            // Allow OS shutdown without prematurely killing LiveZoom if user later cancels shutdown.
            LRESULT(1)
        }
        WM_ENDSESSION => {
            if wparam.0 != 0 {
                if let Some(cell) = SYS_TX.get() {
                    if let Some(ref tx) = *cell.lock().unwrap() {
                        let _ = tx.send(SysMsg::Quit);
                    }
                }
                PostQuitMessage(0);
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

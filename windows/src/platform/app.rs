use std::collections::HashMap;
use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use windows::core::w;
use windows::Win32::Foundation::{CloseHandle, GetLastError, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Dwm::DwmFlush;
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, FindWindowW, PeekMessageW,
    PostMessageW, PostQuitMessage, RegisterClassW, TranslateMessage, MSG, PM_REMOVE,
    WM_DISPLAYCHANGE, WM_ENDSESSION, WM_LBUTTONDBLCLK, WM_LBUTTONUP, WM_QUERYENDSESSION, WM_QUIT,
    WM_RBUTTONUP, WNDCLASSW,
};

use crate::core::annotation::{AnnotationItem, HighlightKind, InkLook};
use crate::core::camera::{CameraConfig, CameraPhase, ViewportMath, ZoomCamera};
use crate::core::cursor::{CursorMotion, CursorStyle};
use crate::core::geometry::{Point, Rect};
use crate::core::input_fsm::InputAction;
use crate::core::settings::{AppSettings, CloseWindowBehavior, KeyCombo};
use crate::platform::console::{ConsoleEvent, ConsoleWindow};
use crate::platform::cursor_system::{ActiveCursorKind, SystemCursorManager};
use crate::platform::display::{cursor_position, display_under_point, DisplayInfo};
use crate::platform::input_hook::InputHook;
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
    let input_hook = InputHook::start()?;

    let (console_tx, console_rx) = mpsc::channel::<ConsoleEvent>();
    let (ocr_tx, ocr_rx) = mpsc::channel::<(HighlightKind, Option<Rect>)>();
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
    input_hook.set_drag_threshold_px(4.0 * initial_display.scale.max(1.0));

    let start_instant = Instant::now();
    let mut last_frame = start_instant;
    let mut active_display = initial_display;
    let mut camera: Option<ZoomCamera> = None;
    let mut last_zoom_origin = Point::ZERO;
    let mut last_zoom = 1.0f64;
    let mut motion = CursorMotion::new(cursor_position(), 0.0);
    let mut drawing_pointer: Option<Point> = None;
    let mut annotations: Vec<AnnotationItem> = Vec::new();
    let mut annotations_rev: u64 = 0;
    let mut stroke_in_progress = false;
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
        let raw_dt = last_frame.elapsed().as_secs_f64();
        let dt = raw_dt.clamp(1.0 / 240.0, 1.0 / 20.0);
        last_frame = Instant::now();

        // Helper closure to cleanly exit zoom mode from any trigger (disable toggle, display change, console open).
        let reset_zoom = |camera: &mut Option<ZoomCamera>,
                          magnifier: &mut MagnifierHost,
                          annotations: &mut Vec<AnnotationItem>,
                          annotations_rev: &mut u64,
                          stroke_in_progress: &mut bool,
                          console: &mut Option<ConsoleWindow>,
                          console_hidden_for_zoom: &mut bool| {
            if camera.is_some() {
                *camera = None;
                magnifier.hide();
                input_hook.set_cursor_bounds(None);
                input_hook.set_drawing_armed(false);
                input_hook.set_keys_armed(false);
                annotations.clear();
                *annotations_rev = annotations_rev.wrapping_add(1);
                *stroke_in_progress = false;
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
                        &mut annotations,
                        &mut annotations_rev,
                        &mut stroke_in_progress,
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
                    // Restore native OS cursor and pause hooks during modal TrackPopupMenu so the cursor never freezes.
                    cursor_sys.restore();
                    overlay.hide();
                    input_hook.set_modal_paused(true);
                    let cmd = tray.show_menu(settings.enabled, settings.launch_at_login);
                    input_hook.set_modal_paused(false);
                    if let Some(cmd) = cmd {
                        match cmd {
                            MENU_OPEN_CONSOLE => {
                                reset_zoom(
                                    &mut camera,
                                    &mut magnifier,
                                    &mut annotations,
                                    &mut annotations_rev,
                                    &mut stroke_in_progress,
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
                            MENU_TOGGLE_ENABLED => {
                                settings.enabled = !settings.enabled;
                                settings.save();
                                tray.update_tooltip(settings.enabled, settings.trigger);
                                sync_hook_settings(&input_hook, &settings);
                                if !settings.enabled {
                                    reset_zoom(
                                        &mut camera,
                                        &mut magnifier,
                                        &mut annotations,
                                        &mut annotations_rev,
                                        &mut stroke_in_progress,
                                        &mut console,
                                        &mut console_hidden_for_zoom,
                                    );
                                }
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
                        &mut annotations,
                        &mut annotations_rev,
                        &mut stroke_in_progress,
                        &mut console,
                        &mut console_hidden_for_zoom,
                    );
                    if let Some(disp) = display_under_point(cursor_position()) {
                        active_display = disp;
                        magnifier.set_display_bounds(active_display.bounds);
                        overlay.set_bounds(active_display.bounds);
                        input_hook.set_drag_threshold_px(4.0 * active_display.scale.max(1.0));
                        sync_exclusions(&magnifier, &overlay, &console);
                    }
                }
                SysMsg::Quit => running = false,
            }
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
                            &mut annotations,
                            &mut annotations_rev,
                            &mut stroke_in_progress,
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
            }
        }

        // 4. Process async OCR results.
        while let Ok((kind, line_opt)) = ocr_rx.try_recv() {
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

        // 5. Process input hook actions.
        for action in input_hook.drain_actions() {
            match action {
                InputAction::ToggleZoom => {
                    let cur_global = drawing_pointer.unwrap_or_else(cursor_position);
                    match camera.as_mut() {
                        None => {
                            if let Some(disp) = display_under_point(cur_global) {
                                active_display = disp;
                                magnifier.set_display_bounds(active_display.bounds);
                                overlay.set_bounds(active_display.bounds);
                                input_hook
                                    .set_drag_threshold_px(4.0 * active_display.scale.max(1.0));
                                // Hide console while zoomed so it never intercepts clicks behind the click-through magnifier.
                                if let Some(ref mut c) = console {
                                    c.set_visible(false);
                                    console_hidden_for_zoom = true;
                                }
                                sync_exclusions(&magnifier, &overlay, &console);

                                let cfg = make_camera_config(&settings, &active_display);
                                let mut cam = ZoomCamera::new(active_display.size(), cfg);
                                let local = active_display.to_local(cur_global);
                                cam.zoom_in(settings.default_zoom, local, now);
                                camera = Some(cam);
                                ensure_overlay_topmost = true;
                                input_hook.set_cursor_bounds(Some(active_display.work_area));
                                input_hook.set_drawing_armed(settings.draw_while_zoomed);
                                input_hook.set_keys_armed(true);
                            }
                        }
                        Some(cam) => {
                            let local = active_display.to_local(cur_global);
                            if cam.phase() == CameraPhase::ZoomingOut {
                                cam.zoom_in(settings.default_zoom, local, now);
                                ensure_overlay_topmost = true;
                                input_hook.set_cursor_bounds(Some(active_display.work_area));
                                input_hook.set_drawing_armed(settings.draw_while_zoomed);
                                input_hook.set_keys_armed(true);
                            } else {
                                cam.zoom_out(local, now);
                                input_hook.set_cursor_bounds(None);
                                input_hook.set_drawing_armed(false);
                                input_hook.set_keys_armed(false);
                                annotations.clear();
                                annotations_rev = annotations_rev.wrapping_add(1);
                                stroke_in_progress = false;
                                input_hook.set_has_strokes(false);
                            }
                        }
                    }
                }
                InputAction::AdjustZoom(steps) => {
                    let factor = (0.1 * steps).exp();
                    if let Some(ref mut cam) = camera {
                        cam.adjust_zoom(factor);
                    } else if steps > 0.0 {
                        // Match macOS: scrolling up while holding trigger at 1x starts zoom-in.
                        let cur_global = drawing_pointer.unwrap_or_else(cursor_position);
                        if let Some(disp) = display_under_point(cur_global) {
                            active_display = disp;
                            magnifier.set_display_bounds(active_display.bounds);
                            overlay.set_bounds(active_display.bounds);
                            input_hook.set_drag_threshold_px(4.0 * active_display.scale.max(1.0));
                            if let Some(ref mut c) = console {
                                c.set_visible(false);
                                console_hidden_for_zoom = true;
                            }
                            sync_exclusions(&magnifier, &overlay, &console);

                            let cfg = make_camera_config(&settings, &active_display);
                            let mut cam = ZoomCamera::new(active_display.size(), cfg);
                            let local = active_display.to_local(cur_global);
                            cam.zoom_in(settings.default_zoom, local, now);
                            camera = Some(cam);
                            ensure_overlay_topmost = true;
                            input_hook.set_cursor_bounds(Some(active_display.work_area));
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
                InputAction::DrawingPointer(pt) => {
                    drawing_pointer = pt;
                    if let Some(p) = pt {
                        motion.jump(p, now);
                    }
                }
                InputAction::StrokeBegan(pt) => {
                    if let Some(ref mut cam) = camera {
                        cam.set_follow_paused(true);
                        let local = active_display.to_local(pt);
                        let look = InkLook {
                            style: settings.ink_style,
                            color: settings.ink_color.rgba(),
                            width: settings.stroke_width,
                        };
                        annotations.push(AnnotationItem::new_stroke(local, look, cam.zoom(), now));
                        annotations_rev = annotations_rev.wrapping_add(1);
                        stroke_in_progress = true;
                        input_hook.set_has_strokes(true);
                    }
                }
                InputAction::StrokeMoved { point, straight } => {
                    if stroke_in_progress {
                        let local = active_display.to_local(point);
                        if let Some(last) = annotations.last_mut() {
                            last.extend(local, straight);
                            annotations_rev = annotations_rev.wrapping_add(1);
                        }
                    }
                }
                InputAction::StrokeEnded(_) => {
                    stroke_in_progress = false;
                    if let Some(ref mut cam) = camera {
                        cam.set_follow_paused(false);
                    }
                }
                InputAction::UndoStroke => {
                    annotations.pop();
                    annotations_rev = annotations_rev.wrapping_add(1);
                    // Clear stroke_in_progress so mid-stroke undo never appends into the previous finished stroke.
                    stroke_in_progress = false;
                    if let Some(ref mut cam) = camera {
                        cam.set_follow_paused(false);
                    }
                    input_hook.set_has_strokes(!annotations.is_empty());
                }
                InputAction::ClearStrokes => {
                    annotations.clear();
                    annotations_rev = annotations_rev.wrapping_add(1);
                    stroke_in_progress = false;
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
                        let cur_global = drawing_pointer.unwrap_or_else(cursor_position);
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
                                let _ = tx.send((kind, line));
                            });
                        }
                    }
                }
                InputAction::ReplayLeftDown { .. }
                | InputAction::ReplayLeftClick { .. }
                | InputAction::MoveOsCursor(_) => {}
            }
        }

        // Skip rendering while console is inside a modal Win32 drag/resize loop.
        if in_modal_ui {
            std::thread::sleep(Duration::from_millis(16));
            continue;
        }

        // 6. Update camera & cursor motion.
        let raw_cursor_global = drawing_pointer.unwrap_or_else(cursor_position);
        let is_zoomed = camera.is_some();

        // If Alt+Tab or system UI released ClipCursor and the cursor left the zoomed monitor, smoothly zoom out.
        if let Some(ref mut cam) = camera {
            if !active_display.bounds.contains(raw_cursor_global)
                && cam.phase() != CameraPhase::ZoomingOut
            {
                let local = active_display.to_local(raw_cursor_global);
                cam.zoom_out(local, now);
                input_hook.set_cursor_bounds(None);
                input_hook.set_drawing_armed(false);
                input_hook.set_keys_armed(false);
                annotations.clear();
                annotations_rev = annotations_rev.wrapping_add(1);
                stroke_in_progress = false;
                input_hook.set_has_strokes(false);
            }
        }

        // When not zoomed, keep overlay aligned with whichever display holds the cursor.
        if !is_zoomed {
            if let Some(disp) = display_under_point(raw_cursor_global) {
                if disp.handle != active_display.handle {
                    active_display = disp;
                    overlay.set_bounds(active_display.bounds);
                    input_hook.set_drag_threshold_px(4.0 * active_display.scale.max(1.0));
                }
            }
        }

        motion.smooth_time = if settings.smooth_cursor { 0.06 } else { 0.0 };
        motion.idle_delay = if settings.hide_idle_cursor {
            Some(settings.idle_delay)
        } else {
            None
        };
        motion.update(raw_cursor_global, stroke_in_progress, now, dt);

        // Update ZoomCamera & MagnifierHost (exact integer origin returned for pixel-locked overlay).
        let (zoom, zoom_origin) = if let Some(ref mut cam) = camera {
            let local_cursor = active_display.to_local(raw_cursor_global);
            cam.update(local_cursor, now, dt);
            if cam.phase() == CameraPhase::Idle {
                magnifier.hide();
                camera = None;
                input_hook.set_cursor_bounds(None);
                input_hook.set_drawing_armed(false);
                input_hook.set_keys_armed(false);
                if console_hidden_for_zoom {
                    console_hidden_for_zoom = false;
                    if let Some(ref mut c) = console {
                        c.set_visible(true);
                    }
                }
                (1.0, Point::ZERO)
            } else {
                let mut vp = cam.viewport();
                if cam.is_settled() {
                    vp = ViewportMath::pixel_aligned(vp, cam.zoom(), 1.0, active_display.size());
                }
                let snapped_origin = magnifier.render(vp, cam.zoom());
                (cam.zoom(), snapped_origin)
            }
        } else {
            magnifier.hide();
            (1.0, Point::ZERO)
        };
        last_zoom_origin = zoom_origin;
        last_zoom = zoom;

        // 7. Synchronize OS cursor hiding (hides ALL standard OS cursors while zoomed so none sit at unzoomed coords).
        let is_zoomed_now = camera.is_some();
        let custom_cursor_enabled = settings.enabled
            && settings.cursor_style != CursorStyle::System
            && (settings.custom_cursor_always || is_zoomed_now);
        cursor_sys.sync(
            is_zoomed_now,
            custom_cursor_enabled,
            settings.cursor_style.replaces_pointing_hand(),
        );

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
        let draw_cursor = match cursor_sys.resolve_cursor() {
            ActiveCursorKind::None => None,
            ActiveCursorKind::CustomVector => {
                let local = active_display.to_local(motion.position());
                let screen_pt = Point::new(
                    (local.x - zoom_origin.x) * zoom,
                    (local.y - zoom_origin.y) * zoom,
                );
                Some(CursorDraw {
                    graphic: CursorGraphic::Vector(settings.cursor_style),
                    position: screen_pt,
                    pixel_scale: settings.cursor_size * active_display.scale * cursor_zoom_scale,
                    bitmap_zoom: cursor_zoom_scale,
                    opacity: motion.opacity(),
                })
            }
            ActiveCursorKind::SystemBitmap(sys_bmp) => {
                let local = active_display.to_local(motion.position());
                let screen_pt = Point::new(
                    (local.x - zoom_origin.x) * zoom,
                    (local.y - zoom_origin.y) * zoom,
                );
                Some(CursorDraw {
                    graphic: CursorGraphic::SystemBitmap(sys_bmp),
                    position: screen_pt,
                    pixel_scale: active_display.scale * cursor_zoom_scale,
                    bitmap_zoom: cursor_zoom_scale,
                    opacity: motion.opacity(),
                })
            }
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

        let drew_frame = match overlay.render(&frame) {
            Ok(drew) => drew,
            Err(()) => {
                // Unrecoverable GPU device loss: immediately give the user back their real OS cursor.
                cursor_sys.restore();
                false
            }
        };

        // 10. Pace loop: VSync via DwmFlush while actively animating, low-CPU sleep when completely static.
        let actively_animating = drew_frame
            || is_zoomed_now
            || !click_marks.is_empty()
            || !annotations.is_empty();
        if actively_animating {
            unsafe {
                if DwmFlush().is_err() {
                    std::thread::sleep(Duration::from_millis(8));
                }
            }
        } else {
            std::thread::sleep(Duration::from_millis(12));
        }
    }

    // Clean shutdown: restore system cursor, release ClipCursor, destroy windows.
    cursor_sys.restore();
    input_hook.set_cursor_bounds(None);
    unsafe {
        let _ = DestroyWindow(msg_hwnd);
    }
    Ok(())
}

fn sync_hook_settings(hook: &InputHook, settings: &AppSettings) {
    hook.set_enabled(settings.enabled);
    hook.set_trigger(settings.trigger);
    let mut map: HashMap<KeyCombo, HighlightKind> = HashMap::new();
    for (&kind, sc) in &settings.shortcuts {
        map.insert(sc.combo(), kind);
    }
    hook.set_shortcuts(map, settings.undo_shortcut.as_ref().map(|s| s.combo()));
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
        WM_TRAY_ICON => {
            let ev = (lparam.0 & 0xFFFF) as u32;
            if let Some(cell) = SYS_TX.get() {
                if let Some(ref tx) = *cell.lock().unwrap() {
                    if ev == WM_LBUTTONUP || ev == WM_LBUTTONDBLCLK {
                        let _ = tx.send(SysMsg::OpenConsole);
                    } else if ev == WM_RBUTTONUP {
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

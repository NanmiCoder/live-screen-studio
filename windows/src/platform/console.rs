use std::cell::{Cell, RefCell};
use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::rc::{Rc, Weak};
use std::sync::mpsc::Sender;

use serde::Deserialize;
use webview2_com::Microsoft::Web::WebView2::Win32::{
    CreateCoreWebView2EnvironmentWithOptions, ICoreWebView2, ICoreWebView2Controller,
    ICoreWebView2Environment,
};
use webview2_com::{
    CreateCoreWebView2ControllerCompletedHandler, CreateCoreWebView2EnvironmentCompletedHandler,
    WebMessageReceivedEventHandler,
};
use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{CreateSolidBrush, HBRUSH};
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GetClientRect, GetWindowLongPtrW, LoadCursorW,
    LoadIconW, MessageBoxW, RegisterClassW, SetForegroundWindow, SetWindowLongPtrW, SetWindowPos,
    ShowWindow, CREATESTRUCTW, GWLP_USERDATA, IDC_ARROW, IDI_APPLICATION, MB_ICONWARNING, MB_OK,
    SWP_NOACTIVATE, SWP_NOZORDER, SW_HIDE, SW_RESTORE, SW_SHOW, WM_CLOSE, WM_CREATE, WM_DPICHANGED,
    WM_ENTERSIZEMOVE, WM_EXITSIZEMOVE, WM_SIZE, WNDCLASSW, WS_OVERLAPPEDWINDOW,
};

use crate::core::annotation::HighlightKind;
use crate::core::settings::{AppSettings, Shortcut};
use crate::platform::display::DisplayInfo;

const CONSOLE_HTML: &str = include_str!("../../assets/console.html");

#[derive(Debug)]
pub enum ConsoleEvent {
    SettingsUpdated(AppSettings),
    ShortcutSet {
        target: ShortcutTarget,
        shortcut: Option<Shortcut>,
    },
    EnterModalMove,
    ExitModalMove,
    Closed,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutTarget {
    Undo,
    Box,
    Underline,
    Fill,
    Spotlight,
}

impl ShortcutTarget {
    pub fn as_highlight(&self) -> Option<HighlightKind> {
        match self {
            Self::Undo => None,
            Self::Box => Some(HighlightKind::Box),
            Self::Underline => Some(HighlightKind::Underline),
            Self::Fill => Some(HighlightKind::Fill),
            Self::Spotlight => Some(HighlightKind::Spotlight),
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum WebMessage {
    Ready,
    UpdateSettings {
        settings: AppSettings,
    },
    SetShortcut {
        target: ShortcutTarget,
        shortcut: Option<Shortcut>,
    },
}

struct ConsoleInner {
    hwnd: Cell<HWND>,
    closed: Cell<bool>,
    controller: RefCell<Option<ICoreWebView2Controller>>,
    webview: RefCell<Option<ICoreWebView2>>,
    tx: Sender<ConsoleEvent>,
    initial_settings: RefCell<AppSettings>,
    chinese_ocr: bool,
}

/// On-demand 3-page Settings Console backed by system WebView2.
/// Created only when opened; closing the window destroys the WebView2 controller cleanly (0 MB idle RAM).
pub struct ConsoleWindow {
    inner: Rc<ConsoleInner>,
    visible: bool,
}

impl ConsoleWindow {
    pub fn open(
        display: &DisplayInfo,
        settings: AppSettings,
        chinese_ocr: bool,
        tx: Sender<ConsoleEvent>,
    ) -> Result<Self, String> {
        let hmodule = unsafe { GetModuleHandleW(None).map_err(|e| e.to_string())? };
        let hinst = HINSTANCE::from(hmodule);
        let class_name = w!("LiveZoomConsoleWindow");

        unsafe {
            let bg: HBRUSH = CreateSolidBrush(COLORREF(0x0017_110F)); // #0f1117 BGR
            let icon = LoadIconW(hinst, PCWSTR(1 as *const u16))
                .or_else(|_| LoadIconW(None, IDI_APPLICATION))
                .unwrap_or_default();
            let cursor = LoadCursorW(None, IDC_ARROW).unwrap_or_default();
            let wc = WNDCLASSW {
                lpfnWndProc: Some(console_wnd_proc),
                hInstance: hinst,
                hIcon: icon,
                hCursor: cursor,
                hbrBackground: bg,
                lpszClassName: class_name,
                ..Default::default()
            };
            RegisterClassW(&wc);
        }

        // Scale logical 840x660 window by monitor DPI and clamp cleanly inside work area.
        let scale = display.scale.max(1.0);
        let w_px = ((840.0 * scale).round())
            .min(display.work_area.width * 0.92)
            .max(640.0) as i32;
        let h_px = ((660.0 * scale).round())
            .min(display.work_area.height * 0.92)
            .max(480.0) as i32;
        let x = (display.work_area.x + (display.work_area.width - w_px as f64) * 0.5).round() as i32;
        let y = (display.work_area.y + (display.work_area.height - h_px as f64) * 0.5).round() as i32;

        let inner = Rc::new(ConsoleInner {
            hwnd: Cell::new(HWND::default()),
            closed: Cell::new(false),
            controller: RefCell::new(None),
            webview: RefCell::new(None),
            tx,
            initial_settings: RefCell::new(settings),
            chinese_ocr,
        });

        let raw_ptr = Rc::as_ptr(&inner) as *mut std::ffi::c_void;
        let hwnd = unsafe {
            CreateWindowExW(
                Default::default(),
                class_name,
                w!("LiveZoom 控制台"),
                WS_OVERLAPPEDWINDOW,
                x,
                y,
                w_px,
                h_px,
                None,
                None,
                hinst,
                Some(raw_ptr),
            )
            .map_err(|e| format!("CreateWindowExW(Console) failed: {e}"))?
        };

        inner.hwnd.set(hwnd);
        unsafe {
            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetForegroundWindow(hwnd);
        }

        init_webview2(Rc::downgrade(&inner));

        Ok(Self {
            inner,
            visible: true,
        })
    }

    pub fn hwnd(&self) -> HWND {
        self.inner.hwnd.get()
    }

    pub fn focus(&mut self) {
        let hwnd = self.inner.hwnd.get();
        self.visible = true;
        unsafe {
            let _ = ShowWindow(hwnd, SW_RESTORE);
            let _ = SetForegroundWindow(hwnd);
        }
    }

    /// Temporarily hides or restores the console window (e.g. hiding during zoom so it never acts as
    /// an invisible click-intercepting black hole underneath the click-through magnifier).
    pub fn set_visible(&mut self, show: bool) {
        if self.visible == show {
            return;
        }
        self.visible = show;
        let hwnd = self.inner.hwnd.get();
        unsafe {
            let _ = ShowWindow(hwnd, if show { SW_SHOW } else { SW_HIDE });
        }
    }

    pub fn push_settings(&self, settings: &AppSettings) {
        *self.inner.initial_settings.borrow_mut() = settings.clone();
        hydrate_webview(&self.inner);
    }
}

impl Drop for ConsoleWindow {
    fn drop(&mut self) {
        self.inner.closed.set(true);
        if let Some(ctrl) = self.inner.controller.borrow_mut().take() {
            unsafe {
                let _ = ctrl.Close();
            }
        }
        self.inner.webview.borrow_mut().take();
        let hwnd = self.inner.hwnd.replace(HWND::default());
        unsafe {
            if !hwnd.0.is_null() {
                let _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                let _ = DestroyWindow(hwnd);
            }
        }
    }
}

fn show_webview2_missing_notice(hwnd: HWND) {
    unsafe {
        MessageBoxW(
            hwnd,
            w!("未能初始化控制台界面（缺少 Microsoft Edge WebView2 运行时）。\n\nLiveZoom 放大与标注核心仍可正常使用；如需打开设置界面，请前往微软官网安装「Edge WebView2 Runtime」。"),
            w!("LiveZoom 提示"),
            MB_OK | MB_ICONWARNING,
        );
    }
}

fn init_webview2(weak_inner: Weak<ConsoleInner>) {
    let user_data_dir = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .map(|p| p.join("LiveZoom").join("WebView2"));
    let user_data_wide: Option<Vec<u16>> = user_data_dir.map(|p| {
        OsStr::new(&p)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    });
    let user_data_pcwstr = user_data_wide
        .as_ref()
        .map(|v| PCWSTR(v.as_ptr()))
        .unwrap_or(PCWSTR::null());

    let weak_env = weak_inner.clone();
    let handler = CreateCoreWebView2EnvironmentCompletedHandler::create(Box::new(
        move |res, env: Option<ICoreWebView2Environment>| {
            let Some(inner) = weak_env.upgrade() else {
                return Ok(());
            };
            if inner.closed.get() {
                return Ok(());
            }
            let hwnd = inner.hwnd.get();
            if res.is_err() || env.is_none() || hwnd.0.is_null() {
                show_webview2_missing_notice(hwnd);
                return Ok(());
            }
            let env = env.unwrap();
            let weak_ctrl = Rc::downgrade(&inner);
            let ctrl_handler = CreateCoreWebView2ControllerCompletedHandler::create(Box::new(
                move |res, controller: Option<ICoreWebView2Controller>| {
                    let Some(ctrl) = controller else {
                        return Ok(());
                    };
                    let Some(inner) = weak_ctrl.upgrade() else {
                        unsafe {
                            let _ = ctrl.Close();
                        }
                        return Ok(());
                    };
                    if inner.closed.get() || res.is_err() {
                        unsafe {
                            let _ = ctrl.Close();
                        }
                        return Ok(());
                    }
                    let hwnd = inner.hwnd.get();
                    if hwnd.0.is_null() {
                        unsafe {
                            let _ = ctrl.Close();
                        }
                        return Ok(());
                    }
                    unsafe {
                        let mut bounds = RECT::default();
                        let _ = GetClientRect(hwnd, &mut bounds);
                        let _ = ctrl.SetBounds(bounds);
                        let _ = ctrl.SetIsVisible(true);

                        if let Ok(wv) = ctrl.CoreWebView2() {
                            let weak_msg = Rc::downgrade(&inner);
                            let mut token = Default::default();
                            let _ = wv.add_WebMessageReceived(
                                &WebMessageReceivedEventHandler::create(Box::new(
                                    move |_wv, args| {
                                        let Some(inner_msg) = weak_msg.upgrade() else {
                                            return Ok(());
                                        };
                                        if inner_msg.closed.get() {
                                            return Ok(());
                                        }
                                        if let Some(args) = args {
                                            let mut raw = windows::core::PWSTR::null();
                                            if args.WebMessageAsJson(&mut raw).is_ok()
                                                && !raw.is_null()
                                            {
                                                let parsed = raw.to_string();
                                                // Must free COM string allocated by WebView2.
                                                CoTaskMemFree(Some(raw.0 as *const _));
                                                if let Ok(json_str) = parsed {
                                                    if let Ok(msg) =
                                                        serde_json::from_str::<WebMessage>(&json_str)
                                                    {
                                                        match msg {
                                                            WebMessage::Ready => {
                                                                hydrate_webview(&inner_msg);
                                                            }
                                                            WebMessage::UpdateSettings {
                                                                settings,
                                                            } => {
                                                                let _ = inner_msg.tx.send(
                                                                    ConsoleEvent::SettingsUpdated(
                                                                        settings,
                                                                    ),
                                                                );
                                                            }
                                                            WebMessage::SetShortcut {
                                                                target,
                                                                shortcut,
                                                            } => {
                                                                let _ = inner_msg.tx.send(
                                                                    ConsoleEvent::ShortcutSet {
                                                                        target,
                                                                        shortcut,
                                                                    },
                                                                );
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        Ok(())
                                    },
                                )),
                                &mut token,
                            );

                            let html = HSTRING::from(CONSOLE_HTML);
                            let _ = wv.NavigateToString(&html);
                            *inner.webview.borrow_mut() = Some(wv);
                        }
                    }
                    *inner.controller.borrow_mut() = Some(ctrl);
                    Ok(())
                },
            ));
            unsafe {
                let _ = env.CreateCoreWebView2Controller(hwnd, &ctrl_handler);
            }
            Ok(())
        },
    ));

    let res = unsafe {
        CreateCoreWebView2EnvironmentWithOptions(
            PCWSTR::null(),
            user_data_pcwstr,
            None,
            &handler,
        )
    };
    if res.is_err() {
        if let Some(inner) = weak_inner.upgrade() {
            if !inner.closed.get() {
                show_webview2_missing_notice(inner.hwnd.get());
            }
        }
    }
}

fn hydrate_webview(inner: &ConsoleInner) {
    if inner.closed.get() {
        return;
    }
    let Some(ref wv) = *inner.webview.borrow() else {
        return;
    };
    let payload = serde_json::json!({
        "settings": *inner.initial_settings.borrow(),
        "chineseOcr": inner.chinese_ocr,
    });
    let script = HSTRING::from(format!("window.__livezoomHydrate({});", payload));
    unsafe {
        let _ = wv.ExecuteScript(&script, None);
    }
}

unsafe extern "system" fn console_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_CREATE => {
            let cs = &*(lparam.0 as *const CREATESTRUCTW);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, cs.lpCreateParams as isize);
            LRESULT(0)
        }
        WM_SIZE => {
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const ConsoleInner;
            if !ptr.is_null() {
                let inner = &*ptr;
                if let Some(ref ctrl) = *inner.controller.borrow() {
                    let mut bounds = RECT::default();
                    let _ = GetClientRect(hwnd, &mut bounds);
                    let _ = ctrl.SetBounds(bounds);
                }
            }
            LRESULT(0)
        }
        WM_DPICHANGED => {
            let suggested = &*(lparam.0 as *const RECT);
            let _ = SetWindowPos(
                hwnd,
                None,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            LRESULT(0)
        }
        WM_ENTERSIZEMOVE => {
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const ConsoleInner;
            if !ptr.is_null() {
                let inner = &*ptr;
                let _ = inner.tx.send(ConsoleEvent::EnterModalMove);
            }
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_EXITSIZEMOVE => {
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const ConsoleInner;
            if !ptr.is_null() {
                let inner = &*ptr;
                let _ = inner.tx.send(ConsoleEvent::ExitModalMove);
            }
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_CLOSE => {
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const ConsoleInner;
            if !ptr.is_null() {
                let inner = &*ptr;
                let _ = inner.tx.send(ConsoleEvent::Closed);
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

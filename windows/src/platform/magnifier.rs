use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::InvalidateRect;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Magnification::{
    MagInitialize, MagSetWindowFilterList, MagSetWindowSource, MagSetWindowTransform,
    MagUninitialize, MAGTRANSFORM, MW_FILTERMODE_EXCLUDE,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, RegisterClassW, SetLayeredWindowAttributes,
    SetWindowPos, ShowWindow, HWND_TOPMOST, LWA_ALPHA, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE,
    SW_HIDE, SW_SHOWNOACTIVATE, WNDCLASSW, WS_CHILD, WS_EX_LAYERED, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP, WS_VISIBLE,
};

use crate::core::geometry::{Point, Rect};

/// Full-screen click-through Windows Magnification API host (`WC_MAGNIFIER`).
///
/// Uses `MagSetWindowFilterList(MW_FILTERMODE_EXCLUDE, ...)` to exclude ONLY LiveZoom's own windows
/// while remaining 100% visible to any external screen recorder, livestream or meeting app (zero config).
pub struct MagnifierHost {
    host_hwnd: HWND,
    mag_hwnd: HWND,
    visible: bool,
    display_bounds: Rect,
    last_transform: Option<f32>,
    last_source: Option<RECT>,
}

impl MagnifierHost {
    pub fn new(display_bounds: Rect) -> Result<Self, String> {
        unsafe {
            if !MagInitialize().as_bool() {
                return Err("MagInitialize failed".to_string());
            }

            let hinstance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
            let class_name = w!("LiveZoomMagnifierHost");

            let wc = WNDCLASSW {
                lpfnWndProc: Some(mag_host_wnd_proc),
                hInstance: hinstance.into(),
                lpszClassName: class_name,
                ..Default::default()
            };
            RegisterClassW(&wc);

            let x = display_bounds.x.round() as i32;
            let y = display_bounds.y.round() as i32;
            let w_px = display_bounds.width.round() as i32;
            let h_px = display_bounds.height.round() as i32;

            let host_hwnd = CreateWindowExW(
                WS_EX_TOPMOST
                    | WS_EX_LAYERED
                    | WS_EX_TRANSPARENT
                    | WS_EX_NOACTIVATE
                    | WS_EX_TOOLWINDOW,
                class_name,
                w!("LiveZoom Magnifier"),
                WS_POPUP,
                x,
                y,
                w_px,
                h_px,
                None,
                None,
                hinstance,
                None,
            )
            .map_err(|e| format!("CreateWindowExW(MagnifierHost) failed: {e}"))?;

            // Fully opaque layered host (required by WC_MAGNIFIER).
            let _ = SetLayeredWindowAttributes(host_hwnd, COLORREF(0), 255, LWA_ALPHA);

            let mag_class = w!("Magnifier");
            let mag_hwnd = CreateWindowExW(
                Default::default(),
                mag_class,
                w!("LiveZoom Magnifier Control"),
                WS_CHILD | WS_VISIBLE,
                0,
                0,
                w_px,
                h_px,
                host_hwnd,
                None,
                hinstance,
                None,
            )
            .map_err(|e| {
                let _ = DestroyWindow(host_hwnd);
                format!("CreateWindowExW(WC_MAGNIFIER) failed: {e}")
            })?;

            Ok(Self {
                host_hwnd,
                mag_hwnd,
                visible: false,
                display_bounds,
                last_transform: None,
                last_source: None,
            })
        }
    }

    #[allow(dead_code)]
    pub fn host_hwnd(&self) -> HWND {
        self.host_hwnd
    }

    /// Excludes LiveZoom's own windows (host, overlay, console) from magnification so it never self-captures.
    pub fn set_excluded_windows(&self, extra: &[HWND]) {
        let mut list = Vec::with_capacity(extra.len() + 2);
        list.push(self.host_hwnd);
        list.push(self.mag_hwnd);
        for &hwnd in extra {
            if !hwnd.0.is_null() {
                list.push(hwnd);
            }
        }
        unsafe {
            let _ = MagSetWindowFilterList(
                self.mag_hwnd,
                MW_FILTERMODE_EXCLUDE,
                list.len() as i32,
                list.as_mut_ptr(),
            );
        }
    }

    /// Repositions the magnifier onto a different display when the user zooms on another monitor.
    pub fn set_display_bounds(&mut self, bounds: Rect) {
        if self.display_bounds == bounds {
            return;
        }
        self.display_bounds = bounds;
        let x = bounds.x.round() as i32;
        let y = bounds.y.round() as i32;
        let w = bounds.width.round() as i32;
        let h = bounds.height.round() as i32;
        unsafe {
            let _ = SetWindowPos(
                self.host_hwnd,
                HWND_TOPMOST,
                x,
                y,
                w,
                h,
                SWP_NOACTIVATE,
            );
            let _ = SetWindowPos(self.mag_hwnd, None, 0, 0, w, h, SWP_NOACTIVATE);
        }
    }

    /// Updates magnification scale and source rectangle (display-local physical pixels).
    /// Returns the exact integer-snapped display-local origin passed to `MagSetWindowSource`
    /// so `OverlayWindow` stays locked pixel-for-pixel with the magnified image (zero pan jitter).
    pub fn render(&mut self, viewport_local: Rect, zoom: f64) -> Result<Point, ()> {
        let z = zoom.max(1.0) as f32;

        let disp_x = self.display_bounds.x.round() as i32;
        let disp_y = self.display_bounds.y.round() as i32;
        let width = self.display_bounds.width as i32;
        let height = self.display_bounds.height as i32;
        let src_w = (self.display_bounds.width / z as f64).ceil() as i32;
        let src_h = (self.display_bounds.height / z as f64).ceil() as i32;
        let local_x = (viewport_local.x.round() as i32).clamp(0, width - src_w);
        let local_y = (viewport_local.y.round() as i32).clamp(0, height - src_h);

        let src = RECT {
            left: disp_x + local_x,
            top: disp_y + local_y,
            right: disp_x + local_x + src_w,
            bottom: disp_y + local_y + src_h,
        };

        unsafe {
            if self.last_transform != Some(z) {
                let mut transform = MAGTRANSFORM::default();
                transform.v[0] = z;
                transform.v[4] = z;
                transform.v[8] = 1.0;
                if !MagSetWindowTransform(self.mag_hwnd, &mut transform).as_bool() {
                    return Err(());
                }
                self.last_transform = Some(z);
            }
            if self.last_source != Some(src) {
                if !MagSetWindowSource(self.mag_hwnd, src).as_bool() {
                    return Err(());
                }
                self.last_source = Some(src);
            } else {
                // The source geometry can stay still while windows inside it continue to animate.
                let _ = InvalidateRect(self.mag_hwnd, None, false);
            }
            if !self.visible {
                let _ = ShowWindow(self.host_hwnd, SW_SHOWNOACTIVATE);
                let _ = SetWindowPos(
                    self.host_hwnd,
                    HWND_TOPMOST,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                );
                self.visible = true;
            }
        }

        Ok(Point::new(local_x as f64, local_y as f64))
    }

    pub fn hide(&mut self) {
        if !self.visible {
            return;
        }
        unsafe {
            let _ = ShowWindow(self.host_hwnd, SW_HIDE);
        }
        self.visible = false;
        self.last_source = None;
    }

    #[allow(dead_code)]
    pub fn is_visible(&self) -> bool {
        self.visible
    }
}

impl Drop for MagnifierHost {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.host_hwnd);
            let _ = MagUninitialize();
        }
    }
}

unsafe extern "system" fn mag_host_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

#[allow(dead_code)]
fn _keep_pcwstr(_: PCWSTR) {}

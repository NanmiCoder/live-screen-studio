use std::mem::size_of;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{BOOL, LPARAM, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, EnumDisplaySettingsW, GetMonitorInfoW, MonitorFromPoint, DEVMODEW,
    ENUM_CURRENT_SETTINGS, HDC, HMONITOR, MONITORINFOEXW, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

use crate::core::geometry::{Point, Rect, Size};

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct DisplayInfo {
    pub handle: isize,
    pub bounds: Rect,
    pub work_area: Rect,
    /// DPI scaling factor (`1.0` = 96 DPI, `1.5` = 144 DPI, `2.0` = 192 DPI).
    pub scale: f64,
    pub refresh_hz: u32,
    pub is_primary: bool,
}

impl DisplayInfo {
    #[inline]
    pub fn size(&self) -> Size {
        self.bounds.size()
    }

    /// Converts global virtual-screen physical pixel point to display-local physical pixel point.
    #[inline]
    pub fn to_local(&self, global: Point) -> Point {
        Point::new(global.x - self.bounds.x, global.y - self.bounds.y)
    }

    /// Converts display-local physical pixel point to global virtual-screen physical pixel point.
    #[inline]
    #[allow(dead_code)]
    pub fn to_global(&self, local: Point) -> Point {
        Point::new(local.x + self.bounds.x, local.y + self.bounds.y)
    }
}

pub fn cursor_position() -> Point {
    let mut pt = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut pt);
    }
    Point::new(pt.x as f64, pt.y as f64)
}

#[allow(dead_code)]
pub fn enumerate_displays() -> Vec<DisplayInfo> {
    let mut list: Vec<DisplayInfo> = Vec::new();
    unsafe extern "system" fn callback(
        hmon: HMONITOR,
        _hdc: HDC,
        _rect: *mut RECT,
        data: LPARAM,
    ) -> BOOL {
        let out = &mut *(data.0 as *mut Vec<DisplayInfo>);
        if let Some(info) = query_monitor(hmon) {
            out.push(info);
        }
        BOOL(1)
    }

    unsafe {
        let _ = EnumDisplayMonitors(
            HDC::default(),
            None,
            Some(callback),
            LPARAM((&mut list as *mut Vec<DisplayInfo>) as isize),
        );
    }
    list
}

pub fn display_under_point(pt: Point) -> Option<DisplayInfo> {
    let p = POINT {
        x: pt.x.round() as i32,
        y: pt.y.round() as i32,
    };
    let hmon = unsafe { MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST) };
    query_monitor(hmon)
}

pub fn query_monitor(hmon: HMONITOR) -> Option<DisplayInfo> {
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    unsafe {
        if !GetMonitorInfoW(hmon, &mut info.monitorInfo as *mut _ as *mut _).as_bool() {
            return None;
        }
    }

    let r = info.monitorInfo.rcMonitor;
    let w = info.monitorInfo.rcWork;
    let bounds = Rect::new(
        r.left as f64,
        r.top as f64,
        (r.right - r.left).max(1) as f64,
        (r.bottom - r.top).max(1) as f64,
    );
    let work_area = Rect::new(
        w.left as f64,
        w.top as f64,
        (w.right - w.left).max(1) as f64,
        (w.bottom - w.top).max(1) as f64,
    );

    let mut dpi_x = 96u32;
    let mut dpi_y = 96u32;
    let scale = unsafe {
        if GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y).is_ok() && dpi_x > 0 {
            dpi_x as f64 / 96.0
        } else {
            1.0
        }
    };

    let mut devmode = DEVMODEW::default();
    devmode.dmSize = size_of::<DEVMODEW>() as u16;
    let refresh_hz = unsafe {
        if EnumDisplaySettingsW(
            PCWSTR(info.szDevice.as_ptr()),
            ENUM_CURRENT_SETTINGS,
            &mut devmode,
        )
        .as_bool()
            && devmode.dmDisplayFrequency >= 30
        {
            devmode.dmDisplayFrequency
        } else {
            60
        }
    };

    let is_primary = (info.monitorInfo.dwFlags & 1) != 0;

    Some(DisplayInfo {
        handle: hmon.0 as isize,
        bounds,
        work_area,
        scale,
        refresh_hz,
        is_primary,
    })
}

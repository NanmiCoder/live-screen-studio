use std::collections::HashMap;
use std::mem::size_of;
use std::sync::Arc;

use windows::core::PCWSTR;
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetObjectW, SelectObject,
    BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CopyIcon, CreateCursor, DestroyCursor, DestroyIcon, DrawIconEx, GetCursorInfo, GetIconInfo,
    GetSystemMetrics, LoadCursorW, SetSystemCursor, CURSORINFO, CURSOR_SHOWING, DI_NORMAL,
    HCURSOR, HICON, ICONINFO, IDC_APPSTARTING, IDC_ARROW, IDC_CROSS, IDC_HAND, IDC_IBEAM, IDC_NO,
    IDC_SIZEALL, IDC_SIZENESW, IDC_SIZENS, IDC_SIZENWSE, IDC_SIZEWE, IDC_UPARROW, IDC_WAIT,
    OCR_APPSTARTING, OCR_CROSS, OCR_HAND, OCR_IBEAM, OCR_NO, OCR_NORMAL, OCR_SIZEALL, OCR_SIZENESW,
    OCR_SIZENS, OCR_SIZENWSE, OCR_SIZEWE, OCR_UP, OCR_WAIT, SM_CXCURSOR, SM_CYCURSOR,
    SYSTEM_CURSOR_ID,
};

use crate::platform::watchdog::{restore_system_cursors, CursorWatchdogGuard};

/// Premultiplied BGRA bitmap snapshot of a real Windows system cursor (e.g. I-Beam, Hand, Resize)
/// used so `OverlayWindow` renders it at the exact zoomed coordinate when zoomed in.
#[derive(Clone)]
pub struct SystemCursorBitmap {
    pub key: isize,
    pub width: u32,
    pub height: u32,
    pub hotspot_x: f32,
    pub hotspot_y: f32,
    pub bgra: Arc<[u8]>,
}

pub enum ActiveCursorKind {
    /// Overlay should not draw any cursor (hardware cursor is visible at 1:1 or hidden by app).
    None,
    /// Overlay should draw LiveZoom's custom vector cursor style.
    CustomVector,
    /// Overlay should draw this real Windows cursor bitmap at the zoomed coordinate.
    SystemBitmap(SystemCursorBitmap),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HideMode {
    None,
    /// At 1× unzoomed: selectively hide only arrow (+ hand when `.dot`), leaving I-Beam/resize native.
    Selective { hide_hand: bool },
    /// While zoomed: hide ALL standard system cursors so hardware cursor never shows at wrong unzoomed coordinates.
    AllForZoom { replace_arrow: bool, replace_hand: bool },
}

const ALL_STANDARD_SLOTS: [(SYSTEM_CURSOR_ID, PCWSTR); 13] = [
    (OCR_NORMAL, IDC_ARROW),
    (OCR_IBEAM, IDC_IBEAM),
    (OCR_WAIT, IDC_WAIT),
    (OCR_CROSS, IDC_CROSS),
    (OCR_UP, IDC_UPARROW),
    (OCR_SIZENWSE, IDC_SIZENWSE),
    (OCR_SIZENESW, IDC_SIZENESW),
    (OCR_SIZEWE, IDC_SIZEWE),
    (OCR_SIZENS, IDC_SIZENS),
    (OCR_SIZEALL, IDC_SIZEALL),
    (OCR_NO, IDC_NO),
    (OCR_HAND, IDC_HAND),
    (OCR_APPSTARTING, IDC_APPSTARTING),
];

/// Manages system cursor hiding, original cursor snapshotting (for zoomed I-Beam/Hand/System styles),
/// and crash-proof restoration via the sibling Watchdog process.
pub struct SystemCursorManager {
    mode: HideMode,
    /// Maps active (transparent) shared system cursor handle -> original real cursor bitmap snapshot.
    saved_snapshots: HashMap<isize, SystemCursorBitmap>,
    /// Cache for non-standard/app-custom cursor handles encountered while zoomed.
    dynamic_cache: HashMap<isize, SystemCursorBitmap>,
    blank_arrow_handle: Option<isize>,
    blank_hand_handle: Option<isize>,
    _watchdog: Option<CursorWatchdogGuard>,
}

impl SystemCursorManager {
    pub fn new() -> Self {
        Self {
            mode: HideMode::None,
            saved_snapshots: HashMap::new(),
            dynamic_cache: HashMap::new(),
            blank_arrow_handle: None,
            blank_hand_handle: None,
            _watchdog: CursorWatchdogGuard::start(),
        }
    }

    fn desired_mode(is_zoomed: bool, custom_cursor_enabled: bool, replace_hand: bool) -> HideMode {
        if is_zoomed {
            HideMode::AllForZoom {
                replace_arrow: custom_cursor_enabled,
                replace_hand: custom_cursor_enabled && replace_hand,
            }
        } else if custom_cursor_enabled {
            HideMode::Selective {
                hide_hand: replace_hand,
            }
        } else {
            HideMode::None
        }
    }

    /// Resolve the image while the native cursor is still available. Hiding is
    /// committed only after the overlay has accepted the frame.
    pub fn prepare_cursor(
        &mut self,
        is_zoomed: bool,
        custom_cursor_enabled: bool,
        replace_hand: bool,
    ) -> ActiveCursorKind {
        let desired = Self::desired_mode(is_zoomed, custom_cursor_enabled, replace_hand);
        if self.mode != desired {
            self.restore();
        }
        self.resolve_cursor(desired)
    }

    pub fn sync(&mut self, is_zoomed: bool, custom_cursor_enabled: bool, replace_hand: bool) {
        let desired = Self::desired_mode(is_zoomed, custom_cursor_enabled, replace_hand);
        if self.mode == desired {
            return;
        }

        // Always restore real system cursors first so we capture authentic original bitmaps cleanly.
        self.restore();

        match desired {
            HideMode::None => {}
            HideMode::Selective { hide_hand } => {
                if let Some(h) = replace_slot_with_transparent(OCR_NORMAL, IDC_ARROW) {
                    self.blank_arrow_handle = Some(h);
                }
                if hide_hand {
                    if let Some(h) = replace_slot_with_transparent(OCR_HAND, IDC_HAND) {
                        self.blank_hand_handle = Some(h);
                    }
                }
            }
            HideMode::AllForZoom { .. } => {
                // Step 1: Capture real bitmaps of all standard system cursors BEFORE replacing them.
                let mut originals: Vec<(SYSTEM_CURSOR_ID, PCWSTR, Option<SystemCursorBitmap>)> =
                    Vec::with_capacity(ALL_STANDARD_SLOTS.len());
                for &(ocr, idc) in &ALL_STANDARD_SLOTS {
                    let bmp = unsafe {
                        LoadCursorW(None, idc)
                            .ok()
                            .and_then(|hc| rasterize_hcursor(hc, ocr.0 as isize))
                    };
                    originals.push((ocr, idc, bmp));
                }
                // Step 2: Replace all standard slots with 1×1 transparent cursors and record mapping.
                for (ocr, idc, bmp) in originals {
                    if let Some(shared_handle) = replace_slot_with_transparent(ocr, idc) {
                        if ocr == OCR_NORMAL {
                            self.blank_arrow_handle = Some(shared_handle);
                        } else if ocr == OCR_HAND {
                            self.blank_hand_handle = Some(shared_handle);
                        }
                        if let Some(mut b) = bmp {
                            b.key = shared_handle;
                            self.saved_snapshots.insert(shared_handle, b);
                        }
                    }
                }
            }
        }

        self.mode = desired;
    }

    /// Resolves what `OverlayWindow` should render for the cursor on this frame.
    fn resolve_cursor(&mut self, desired: HideMode) -> ActiveCursorKind {
        if desired == HideMode::None {
            return ActiveCursorKind::None;
        }

        let mut info = CURSORINFO {
            cbSize: size_of::<CURSORINFO>() as u32,
            ..Default::default()
        };
        unsafe {
            if GetCursorInfo(&mut info).is_err() {
                return ActiveCursorKind::None;
            }
        }
        if (info.flags.0 & CURSOR_SHOWING.0) == 0 {
            return ActiveCursorKind::None;
        }
        let current = info.hCursor.0 as isize;

        let is_standard = |blank, idc| {
            Some(current) == blank
                || (self.mode == HideMode::None
                    && unsafe { LoadCursorW(None, idc).is_ok_and(|handle| handle == info.hCursor) })
        };
        match desired {
            HideMode::None => ActiveCursorKind::None,
            HideMode::Selective { hide_hand } => {
                if is_standard(self.blank_arrow_handle, IDC_ARROW)
                    || (hide_hand && is_standard(self.blank_hand_handle, IDC_HAND))
                {
                    ActiveCursorKind::CustomVector
                } else {
                    ActiveCursorKind::None
                }
            }
            HideMode::AllForZoom {
                replace_arrow,
                replace_hand,
            } => {
                if replace_arrow && is_standard(self.blank_arrow_handle, IDC_ARROW) {
                    return ActiveCursorKind::CustomVector;
                }
                if replace_hand && is_standard(self.blank_hand_handle, IDC_HAND) {
                    return ActiveCursorKind::CustomVector;
                }
                if let Some(bmp) = self.saved_snapshots.get(&current) {
                    return ActiveCursorKind::SystemBitmap(bmp.clone());
                }
                // App-custom cursor (e.g. Figma/Photoshop tool cursor): rasterize and cache by HCURSOR handle.
                if let Some(bmp) = self.dynamic_cache.get(&current) {
                    return ActiveCursorKind::SystemBitmap(bmp.clone());
                }
                if let Some(bmp) = unsafe { rasterize_hcursor(info.hCursor, current) } {
                    if self.dynamic_cache.len() > 64 {
                        self.dynamic_cache.clear();
                    }
                    self.dynamic_cache.insert(current, bmp.clone());
                    return ActiveCursorKind::SystemBitmap(bmp);
                }
                // Fallback so cursor is never invisible while zoomed.
                if replace_arrow {
                    ActiveCursorKind::CustomVector
                } else {
                    self.blank_arrow_handle
                        .and_then(|handle| self.saved_snapshots.get(&handle).cloned())
                        .or_else(|| unsafe {
                            let arrow = LoadCursorW(None, IDC_ARROW).ok()?;
                            rasterize_hcursor(arrow, arrow.0 as isize)
                        })
                        .map(ActiveCursorKind::SystemBitmap)
                        .unwrap_or(ActiveCursorKind::None)
                }
            }
        }
    }

    pub fn restore(&mut self) {
        if self.mode != HideMode::None {
            restore_system_cursors();
            self.mode = HideMode::None;
            self.blank_arrow_handle = None;
            self.blank_hand_handle = None;
            self.saved_snapshots.clear();
            self.dynamic_cache.clear();
        }
    }
}

impl Drop for SystemCursorManager {
    fn drop(&mut self) {
        self.restore();
    }
}

fn replace_slot_with_transparent(id: SYSTEM_CURSOR_ID, idc: PCWSTR) -> Option<isize> {
    unsafe {
        let hinst = GetModuleHandleW(None).ok()?;
        // 32x32 1-bit transparent cursor: AND mask = all 1s, XOR mask = all 0s.
        let and_mask = [0xFFu8; 128];
        let xor_mask = [0x00u8; 128];
        let cursor = CreateCursor(
            hinst,
            0,
            0,
            32,
            32,
            and_mask.as_ptr() as *const _,
            xor_mask.as_ptr() as *const _,
        )
        .ok()?;

        // SetSystemCursor destroys `cursor` ONLY on success; destroy manually on error to avoid leaks.
        if SetSystemCursor(cursor, id).is_err() {
            let _ = DestroyCursor(cursor);
            return None;
        }

        LoadCursorW(None, idc).ok().map(|h| h.0 as isize)
    }
}

/// Rasterizes an `HCURSOR` into premultiplied BGRA pixels + hotspot using `DrawIconEx`.
unsafe fn rasterize_hcursor(hcursor: HCURSOR, key: isize) -> Option<SystemCursorBitmap> {
    let copied: HICON = CopyIcon(hcursor).ok()?;
    let mut icon_info = ICONINFO::default();
    if GetIconInfo(copied, &mut icon_info).is_err() {
        let _ = DestroyIcon(copied);
        return None;
    }

    let mut width = GetSystemMetrics(SM_CXCURSOR).max(32);
    let mut height = GetSystemMetrics(SM_CYCURSOR).max(32);

    if !icon_info.hbmColor.is_invalid() {
        let mut bm = BITMAP::default();
        if GetObjectW(
            icon_info.hbmColor,
            size_of::<BITMAP>() as i32,
            Some(&mut bm as *mut _ as *mut _),
        ) > 0
        {
            width = bm.bmWidth.max(1);
            height = bm.bmHeight.abs().max(1);
        }
    } else if !icon_info.hbmMask.is_invalid() {
        let mut bm = BITMAP::default();
        if GetObjectW(
            icon_info.hbmMask,
            size_of::<BITMAP>() as i32,
            Some(&mut bm as *mut _ as *mut _),
        ) > 0
        {
            width = bm.bmWidth.max(1);
            // Monochrome cursor mask bitmap stores AND + XOR stacked vertically (height = 2 * cursor_height).
            height = (bm.bmHeight.abs() / 2).max(1);
        }
    }

    let hotspot_x = icon_info.xHotspot as f32;
    let hotspot_y = icon_info.yHotspot as f32;
    if !icon_info.hbmColor.is_invalid() {
        let _ = DeleteObject(icon_info.hbmColor);
    }
    if !icon_info.hbmMask.is_invalid() {
        let _ = DeleteObject(icon_info.hbmMask);
    }

    let mem_dc = CreateCompatibleDC(None);
    if mem_dc.is_invalid() {
        let _ = DestroyIcon(copied);
        return None;
    }

    let bi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height, // top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };

    let mut bits_ptr: *mut std::ffi::c_void = std::ptr::null_mut();
    let dib = CreateDIBSection(mem_dc, &bi, DIB_RGB_COLORS, &mut bits_ptr, None, 0).ok();
    let Some(dib) = dib else {
        let _ = DeleteDC(mem_dc);
        let _ = DestroyIcon(copied);
        return None;
    };

    let byte_len = (width as usize) * (height as usize) * 4;
    let slice = std::slice::from_raw_parts_mut(bits_ptr as *mut u8, byte_len);
    slice.fill(0);

    let old = SelectObject(mem_dc, dib);
    let draw_ok = DrawIconEx(mem_dc, 0, 0, copied, width, height, 0, None, DI_NORMAL).is_ok();
    SelectObject(mem_dc, old);

    let result = if draw_ok {
        let mut bgra = slice.to_vec();
        // Check if monochrome / alpha-less cursor (like classic I-Beam) drew RGB with alpha=0.
        let has_any_alpha = bgra.chunks_exact(4).any(|px| px[3] != 0);
        if !has_any_alpha {
            // Re-render onto white + black probe or treat non-zero RGB pixels as opaque; for inverted
            // monochrome I-Beam (drawn as black on transparent=0), draw on white background to recover silhouette.
            slice.fill(0xFF);
            let old2 = SelectObject(mem_dc, dib);
            let _ = DrawIconEx(mem_dc, 0, 0, copied, width, height, 0, None, DI_NORMAL);
            SelectObject(mem_dc, old2);
            let on_white = slice.to_vec();
            for (dst, w_px) in bgra.chunks_exact_mut(4).zip(on_white.chunks_exact(4)) {
                let is_drawn = w_px[0] < 240 || w_px[1] < 240 || w_px[2] < 240;
                if is_drawn {
                    dst[0] = w_px[0];
                    dst[1] = w_px[1];
                    dst[2] = w_px[2];
                    dst[3] = 255;
                } else {
                    dst.fill(0);
                }
            }
        } else {
            // Ensure premultiplied alpha for Direct2D (`D2D1_ALPHA_MODE_PREMULTIPLIED`).
            for px in bgra.chunks_exact_mut(4) {
                let a = px[3] as u16;
                px[0] = ((px[0] as u16 * a + 127) / 255) as u8;
                px[1] = ((px[1] as u16 * a + 127) / 255) as u8;
                px[2] = ((px[2] as u16 * a + 127) / 255) as u8;
            }
        }

        Some(SystemCursorBitmap {
            key,
            width: width as u32,
            height: height as u32,
            hotspot_x,
            hotspot_y,
            bgra: Arc::from(bgra.into_boxed_slice()),
        })
    } else {
        None
    };

    let _ = DeleteObject(dib);
    let _ = DeleteDC(mem_dc);
    let _ = DestroyIcon(copied);
    result
}

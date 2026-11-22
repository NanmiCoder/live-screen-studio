use std::mem::size_of;
use std::thread;

use windows::Globalization::Language;
use windows::Graphics::Imaging::{BitmapPixelFormat, SoftwareBitmap};
use windows::Media::Ocr::OcrEngine;
use windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
    ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT, DIB_RGB_COLORS,
    SRCCOPY,
};
use windows::Win32::System::WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED};

use crate::core::annotation::TextLines;
use crate::core::geometry::{Point, Rect};
use crate::platform::display::DisplayInfo;

/// RAII WinRT guard: ONLY calls `RoUninitialize` when `RoInitialize` actually succeeded,
/// preventing `RPC_E_CHANGED_MODE` from ever uninitializing a caller's STA apartment.
struct RoInitGuard {
    initialized: bool,
}

impl RoInitGuard {
    fn enter_mta() -> Self {
        let initialized = unsafe { RoInitialize(RO_INIT_MULTITHREADED).is_ok() };
        Self { initialized }
    }
}

impl Drop for RoInitGuard {
    fn drop(&mut self) {
        if self.initialized {
            unsafe {
                RoUninitialize();
            }
        }
    }
}

/// Synchronously captured BGRA band ready for asynchronous WinRT OCR.
pub struct CapturedOcrBand {
    bgra: Vec<u8>,
    width: i32,
    height: i32,
    roi_left: i32,
    roi_top: i32,
    cursor_content: Point,
    zoom_origin: Point,
    zoom: f64,
}

/// Synchronously captures a narrow ±60pt magnified screen band around `cursor_content` (~2–4ms)
/// using `SRCCOPY | CAPTUREBLT` so DWM-composited magnified content is captured at exact camera coordinates
/// with zero async drift. Caller should hide `OverlayWindow` for 1 frame if annotations/spotlight exist.
pub fn capture_ocr_band_sync(
    display: &DisplayInfo,
    cursor_content: Point,
    zoom_origin: Point,
    zoom: f64,
) -> Option<CapturedOcrBand> {
    let screen_cursor = Point::new(
        (cursor_content.x - zoom_origin.x) * zoom,
        (cursor_content.y - zoom_origin.y) * zoom,
    );
    let band_px = 60.0 * display.scale * zoom;
    let top = (screen_cursor.y - band_px).max(0.0).floor() as i32;
    let bottom = (screen_cursor.y + band_px).min(display.bounds.height).ceil() as i32;
    let left = 0i32;
    let right = display.bounds.width.round() as i32;
    let w = right - left;
    let h = bottom - top;
    if w <= 8 || h <= 8 {
        return None;
    }

    let bgra = capture_screen_band_bgra(
        display.bounds.x.round() as i32 + left,
        display.bounds.y.round() as i32 + top,
        w,
        h,
    )?;

    Some(CapturedOcrBand {
        bgra,
        width: w,
        height: h,
        roi_left: left,
        roi_top: top,
        cursor_content,
        zoom_origin,
        zoom,
    })
}

/// Runs WinRT OCR asynchronously on a previously captured band and invokes `callback` with the
/// matched text-line rectangle in display-local content physical pixels.
pub fn recognize_band_async(
    band: CapturedOcrBand,
    callback: impl FnOnce(Option<Rect>) + Send + 'static,
) {
    thread::spawn(move || {
        let _ro = RoInitGuard::enter_mta();
        let result = recognize_segments(&band.bgra, band.width, band.height).and_then(|segments| {
            let content_segments: Vec<Rect> = segments
                .into_iter()
                .map(|r| {
                    let sx = band.roi_left as f64 + r.x;
                    let sy = band.roi_top as f64 + r.y;
                    Rect::new(
                        band.zoom_origin.x + sx / band.zoom,
                        band.zoom_origin.y + sy / band.zoom,
                        r.width / band.zoom,
                        r.height / band.zoom,
                    )
                })
                .collect();
            TextLines::line(band.cursor_content, &content_segments)
        });
        callback(result);
    });
}

fn capture_screen_band_bgra(x: i32, y: i32, w: i32, h: i32) -> Option<Vec<u8>> {
    unsafe {
        let screen_dc = GetDC(None);
        if screen_dc.is_invalid() {
            return None;
        }
        let mem_dc = CreateCompatibleDC(screen_dc);
        if mem_dc.is_invalid() {
            ReleaseDC(None, screen_dc);
            return None;
        }
        let bmp = CreateCompatibleBitmap(screen_dc, w, h);
        if bmp.is_invalid() {
            let _ = DeleteDC(mem_dc);
            ReleaseDC(None, screen_dc);
            return None;
        }
        let old = SelectObject(mem_dc, bmp);
        // CAPTUREBLT ensures WS_EX_LAYERED MagnifierHost is included in the capture.
        let blt_ok = BitBlt(mem_dc, 0, 0, w, h, screen_dc, x, y, SRCCOPY | CAPTUREBLT).is_ok();

        let mut buf = vec![0u8; (w * h * 4) as usize];
        let mut bi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h, // top-down DIB
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };

        let lines = if blt_ok {
            GetDIBits(
                mem_dc,
                bmp,
                0,
                h as u32,
                Some(buf.as_mut_ptr() as *mut _),
                &mut bi,
                DIB_RGB_COLORS,
            )
        } else {
            0
        };

        SelectObject(mem_dc, old);
        let _ = DeleteObject(bmp);
        let _ = DeleteDC(mem_dc);
        ReleaseDC(None, screen_dc);

        if lines > 0 {
            // GetDIBits outputs BGRX with alpha=0x00; force alpha=0xFF so premultiplied BGRA8 is opaque.
            for px in buf.chunks_exact_mut(4) {
                px[3] = 0xFF;
            }
            Some(buf)
        } else {
            None
        }
    }
}

fn create_ocr_engine() -> Option<OcrEngine> {
    if let Ok(lang) = Language::CreateLanguage(&"zh-Hans-CN".into()) {
        if OcrEngine::IsLanguageSupported(&lang).unwrap_or(false) {
            if let Ok(engine) = OcrEngine::TryCreateFromLanguage(&lang) {
                return Some(engine);
            }
        }
    }
    OcrEngine::TryCreateFromUserProfileLanguages().ok()
}

fn recognize_segments(bgra: &[u8], w: i32, h: i32) -> Option<Vec<Rect>> {
    let engine = create_ocr_engine()?;

    let stream = InMemoryRandomAccessStream::new().ok()?;
    let writer = DataWriter::CreateDataWriter(&stream).ok()?;
    writer.WriteBytes(bgra).ok()?;
    let ibuf = writer.DetachBuffer().ok()?;

    let bitmap =
        SoftwareBitmap::CreateCopyFromBuffer(&ibuf, BitmapPixelFormat::Bgra8, w, h).ok()?;

    let ocr_res = engine.RecognizeAsync(&bitmap).ok()?.get().ok()?;
    let lines = ocr_res.Lines().ok()?;

    let mut segments = Vec::new();
    for line in lines {
        let Ok(words) = line.Words() else { continue };
        for word in words {
            if let Ok(r) = word.BoundingRect() {
                if r.Width > 0.0 && r.Height > 0.0 {
                    segments.push(Rect::new(
                        r.X as f64,
                        r.Y as f64,
                        r.Width as f64,
                        r.Height as f64,
                    ));
                }
            }
        }
    }
    Some(segments)
}

/// Checks Chinese OCR availability on a dedicated short-lived MTA thread so the main STA thread's
/// COM apartment (required by WebView2) is never touched.
pub fn is_chinese_ocr_available() -> bool {
    thread::spawn(|| {
        let _ro = RoInitGuard::enter_mta();
        Language::CreateLanguage(&"zh-Hans-CN".into())
            .ok()
            .and_then(|l| OcrEngine::IsLanguageSupported(&l).ok())
            .unwrap_or(false)
    })
    .join()
    .unwrap_or(false)
}

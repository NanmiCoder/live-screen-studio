use std::cell::Cell;
use std::collections::HashMap;
use std::time::{Duration, Instant};

use windows::core::{w, Interface};
use windows::Foundation::Numerics::Matrix3x2;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_BEZIER_SEGMENT, D2D1_COLOR_F, D2D1_FIGURE_BEGIN_FILLED,
    D2D1_FIGURE_BEGIN_HOLLOW, D2D1_FIGURE_END_CLOSED, D2D1_FIGURE_END_OPEN,
    D2D1_FILL_MODE_ALTERNATE, D2D1_GRADIENT_STOP, D2D1_PIXEL_FORMAT, D2D_POINT_2F, D2D_RECT_F,
    D2D_SIZE_U,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1CreateFactory, ID2D1Bitmap1, ID2D1Device, ID2D1DeviceContext, ID2D1Factory1,
    ID2D1LinearGradientBrush, ID2D1PathGeometry1, ID2D1SolidColorBrush, ID2D1StrokeStyle1,
    D2D1_ANTIALIAS_MODE_ALIASED, D2D1_BITMAP_OPTIONS_CANNOT_DRAW, D2D1_BITMAP_OPTIONS_NONE,
    D2D1_BITMAP_OPTIONS_TARGET, D2D1_BITMAP_PROPERTIES1, D2D1_BUFFER_PRECISION_8BPC_UNORM,
    D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_ROUND, D2D1_COLOR_INTERPOLATION_MODE_PREMULTIPLIED,
    D2D1_COLOR_SPACE_SRGB, D2D1_DASH_STYLE_CUSTOM, D2D1_DEVICE_CONTEXT_OPTIONS_NONE, D2D1_ELLIPSE,
    D2D1_EXTEND_MODE_CLAMP, D2D1_FACTORY_TYPE_SINGLE_THREADED, D2D1_INTERPOLATION_MODE_LINEAR,
    D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES, D2D1_LINE_JOIN_ROUND, D2D1_QUADRATIC_BEZIER_SEGMENT,
    D2D1_ROUNDED_RECT, D2D1_STROKE_STYLE_PROPERTIES1,
};
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION,
};
use windows::Win32::Graphics::DirectComposition::{
    DCompositionCreateDevice, IDCompositionDevice, IDCompositionSurface, IDCompositionTarget,
    IDCompositionVisual,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_ALPHA_MODE_PREMULTIPLIED, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{
    IDXGIDevice, IDXGIFactory2, IDXGISurface, IDXGISwapChain1, DXGI_ERROR_WAS_STILL_DRAWING,
    DXGI_PRESENT_DO_NOT_WAIT, DXGI_SCALING_STRETCH, DXGI_SWAP_CHAIN_DESC1,
    DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL, DXGI_USAGE_RENDER_TARGET_OUTPUT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, RegisterClassW, SetLayeredWindowAttributes,
    SetWindowPos, ShowWindow, HWND_TOPMOST, LWA_ALPHA, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE,
    SW_HIDE, SW_SHOWNOACTIVATE, WM_PAINT, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE,
    WS_EX_NOREDIRECTIONBITMAP, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
};

use crate::core::annotation::{AnnotationItem, ArrowHead, HighlightKind, InkStyle};
use crate::core::cursor::{ClickAppearance, CursorStyle};
use crate::core::easing::ease_in_out_cubic;
use crate::core::geometry::{ColorRgba, Point, Rect};
use crate::platform::cursor_system::SystemCursorBitmap;

pub struct ClickMarkDraw {
    /// Display-local physical pixel coordinate.
    pub center: Point,
    pub look: ClickAppearance,
    pub color: ColorRgba,
}

pub enum CursorGraphic {
    Vector(CursorStyle),
    SystemBitmap(SystemCursorBitmap),
}

pub struct CursorDraw {
    pub graphic: CursorGraphic,
    /// Display-local physical pixel coordinate.
    pub position: Point,
    /// Visual cursor scale multiplier (includes DPI scale and zoom scale).
    pub pixel_scale: f64,
    /// Zoom multiplier applied to system cursor bitmaps (already at native DPI).
    pub bitmap_zoom: f64,
    pub opacity: f64,
}

pub struct OverlayFrame<'a> {
    pub now: f64,
    pub display_scale: f64,
    /// Integer-snapped zoom viewport origin in display-local physical pixels (`Point::ZERO` at 1×).
    pub zoom_origin: Point,
    /// Current zoom factor (`1.0` when not zoomed).
    pub zoom: f64,
    /// Monotonic revision bumped whenever annotations change.
    pub annotations_rev: u64,
    pub annotations: &'a [AnnotationItem],
    pub click_marks: &'a [ClickMarkDraw],
    pub cursor: Option<CursorDraw>,
    /// True when the magnifier just became visible and overlay must re-assert Z-order above it.
    pub ensure_topmost: bool,
}

#[derive(PartialEq)]
struct AnnotationFrameKey {
    zoom_bits: u64,
    origin_x_bits: u64,
    origin_y_bits: u64,
    annotations_rev: u64,
    animating: bool,
}

#[derive(PartialEq)]
struct CursorFrameKey {
    graphic_id: i64,
    scale: f64,
    opacity: u8,
}

struct CursorSurface {
    surface: IDCompositionSurface,
    width: u32,
    height: u32,
    image: Option<CursorFrameKey>,
    offset: Option<Point>,
    attached: bool,
}

struct GpuResources {
    _d3d_device: ID3D11Device,
    d2d_factory: ID2D1Factory1,
    _d2d_device: ID2D1Device,
    d2d_ctx: ID2D1DeviceContext,
    swap_chain: IDXGISwapChain1,
    target_bitmap: ID2D1Bitmap1,
    dcomp_device: IDCompositionDevice,
    _dcomp_target: IDCompositionTarget,
    annotation_visual: IDCompositionVisual,
    cursor_visual: IDCompositionVisual,
    cursor_surface: Option<CursorSurface>,
    round_stroke: ID2D1StrokeStyle1,
    flat_stroke: ID2D1StrokeStyle1,
    sys_cursor_bitmaps: HashMap<isize, ID2D1Bitmap1>,
}

/// Transparent click-through Direct2D + DirectComposition overlay window.
///
/// Deliberately NOT marked with `WDA_EXCLUDEFROMCAPTURE` so any screen recorder, livestream,
/// or meeting app captures annotations, highlights, ripples, and custom cursor natively.
pub struct OverlayWindow {
    hwnd: HWND,
    bounds: Rect,
    visible: bool,
    renderer: Option<OverlayRenderer>,
    retry_at: Instant,
}

struct OverlayRenderer {
    gpu: GpuResources,
    last_annotations: Option<AnnotationFrameKey>,
}

const DEVICE_RETRY_DELAY: Duration = Duration::from_millis(500);
thread_local! {
    static CHECK_DEVICE: Cell<bool> = const { Cell::new(false) };
}

impl OverlayWindow {
    pub fn new(bounds: Rect) -> Result<Self, String> {
        unsafe {
            let hinstance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
            let class_name = w!("LiveZoomOverlayWindow");
            let wc = WNDCLASSW {
                lpfnWndProc: Some(overlay_wnd_proc),
                hInstance: hinstance.into(),
                lpszClassName: class_name,
                ..Default::default()
            };
            RegisterClassW(&wc);

            let x = bounds.x.round() as i32;
            let y = bounds.y.round() as i32;
            let w_px = bounds.width.round() as i32;
            let h_px = bounds.height.round() as i32;

            let hwnd = CreateWindowExW(
                WS_EX_NOREDIRECTIONBITMAP
                    | WS_EX_LAYERED
                    | WS_EX_TOPMOST
                    | WS_EX_TRANSPARENT
                    | WS_EX_NOACTIVATE
                    | WS_EX_TOOLWINDOW,
                class_name,
                w!("LiveZoom Overlay"),
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
            .map_err(|e| format!("CreateWindowExW(Overlay) failed: {e}"))?;

            // Layered + transparent windows are skipped by cross-process mouse hit testing.
            SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA)
                .map_err(|e| format!("SetLayeredWindowAttributes(Overlay) failed: {e}"))
                .inspect_err(|_| {
                    let _ = DestroyWindow(hwnd);
                })?;

            Ok(Self {
                hwnd,
                bounds,
                visible: false,
                renderer: None,
                retry_at: Instant::now(),
            })
        }
    }

    pub fn hwnd(&self) -> HWND {
        self.hwnd
    }

    pub fn is_visible(&self) -> bool {
        self.visible
    }

    pub fn set_bounds(&mut self, bounds: Rect) {
        if bounds == self.bounds {
            return;
        }
        let resize = bounds.size() != self.bounds.size();
        self.bounds = bounds;
        if self.position_window().is_err() {
            self.invalidate_renderer();
        } else if resize {
            // A new monitor size needs a new backbuffer; position-only changes reuse it.
            self.renderer = None;
            self.retry_at = Instant::now();
        }
    }

    fn position_window(&self) -> windows::core::Result<()> {
        unsafe {
            SetWindowPos(
                self.hwnd,
                HWND_TOPMOST,
                self.bounds.x as i32,
                self.bounds.y as i32,
                self.bounds.width as i32,
                self.bounds.height as i32,
                SWP_NOACTIVATE,
            )
        }
    }

    pub fn is_ready(&self) -> bool {
        self.renderer.is_some()
    }

    fn invalidate_renderer(&mut self) {
        self.hide();
        self.renderer = None;
        self.retry_at = Instant::now() + DEVICE_RETRY_DELAY;
    }

    fn check_device(&mut self) {
        if CHECK_DEVICE.take()
            && self.renderer.as_ref().is_some_and(|renderer| unsafe {
                !renderer
                    .gpu
                    .dcomp_device
                    .CheckDeviceState()
                    .is_ok_and(|valid| valid.as_bool())
            })
        {
            self.invalidate_renderer();
        }
    }

    pub fn render(&mut self, frame: &OverlayFrame<'_>) -> Result<(), ()> {
        self.check_device();
        let cursor = frame.cursor.as_ref().filter(|c| c.opacity > 0.0);
        if frame.annotations.is_empty() && frame.click_marks.is_empty() && cursor.is_none() {
            self.hide();
            return Ok(());
        }

        if self.renderer.is_none() && Instant::now() >= self.retry_at {
            let gpu = self
                .position_window()
                .map_err(|e| e.to_string())
                .and_then(|()| unsafe {
                    create_gpu_resources(
                        self.hwnd,
                        self.bounds.width as u32,
                        self.bounds.height as u32,
                    )
                });
            match gpu {
                Ok(gpu) => {
                    self.renderer = Some(OverlayRenderer {
                        gpu,
                        last_annotations: None,
                    })
                }
                Err(_) => self.invalidate_renderer(),
            }
        }
        let Some(renderer) = self.renderer.as_mut() else {
            return Err(());
        };

        // Submit the replacement cursor before the caller hides the system cursor.
        if unsafe { renderer.render_visuals(frame, cursor) }.is_err() {
            self.invalidate_renderer();
            return Err(());
        }
        unsafe {
            let just_shown = !self.visible;
            if just_shown {
                let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                self.visible = true;
            }
            if just_shown || frame.ensure_topmost {
                if SetWindowPos(
                    self.hwnd,
                    HWND_TOPMOST,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                )
                .is_err()
                {
                    self.invalidate_renderer();
                    return Err(());
                }
            }
        }
        Ok(())
    }

    pub fn hide(&mut self) {
        if self.visible {
            unsafe {
                let _ = ShowWindow(self.hwnd, SW_HIDE);
            }
            self.visible = false;
        }
    }
}

impl OverlayRenderer {
    unsafe fn render_visuals(
        &mut self,
        frame: &OverlayFrame<'_>,
        cursor: Option<&CursorDraw>,
    ) -> Result<(), windows::core::HRESULT> {
        let mut commit = self.update_cursor_visual(cursor)?;
        if frame.annotations.is_empty() && frame.click_marks.is_empty() {
            if self.last_annotations.take().is_some() {
                self.gpu
                    .annotation_visual
                    .SetContent(None)
                    .map_err(|e| e.code())?;
                commit = true;
            }
        } else {
            let animating = !frame.click_marks.is_empty()
                || frame
                    .annotations
                    .iter()
                    .any(|a| is_annotation_animating(a, frame.now));
            let key = AnnotationFrameKey {
                zoom_bits: frame.zoom.to_bits(),
                origin_x_bits: frame.zoom_origin.x.to_bits(),
                origin_y_bits: frame.zoom_origin.y.to_bits(),
                annotations_rev: frame.annotations_rev,
                // Draw the final static frame after the last transient effect expires.
                animating,
            };
            if animating || self.last_annotations.as_ref() != Some(&key) {
                match self.draw_and_present(frame) {
                    Ok(()) => {
                        if self.last_annotations.is_none() {
                            self.gpu
                                .annotation_visual
                                .SetContent(&self.gpu.swap_chain)
                                .map_err(|e| e.code())?;
                            commit = true;
                        }
                        self.last_annotations = Some(key);
                    }
                    Err(DXGI_ERROR_WAS_STILL_DRAWING) => {}
                    Err(hr) => return Err(hr),
                }
            }
        }
        if commit {
            self.gpu.dcomp_device.Commit().map_err(|e| e.code())?;
        }
        Ok(())
    }

    /// The compositor moves the cached cursor image without repainting a monitor-sized texture.
    unsafe fn update_cursor_visual(
        &mut self,
        cursor: Option<&CursorDraw>,
    ) -> Result<bool, windows::core::HRESULT> {
        let Some(cursor) = cursor else {
            if let Some(surface) = self.gpu.cursor_surface.as_mut().filter(|s| s.attached) {
                self.gpu
                    .cursor_visual
                    .SetContent(None)
                    .map_err(|e| e.code())?;
                surface.attached = false;
                return Ok(true);
            }
            return Ok(false);
        };

        let (graphic_id, scale, hotspot, width, height) = match &cursor.graphic {
            CursorGraphic::Vector(style) => {
                // All vector paths and their shadows fit inside 24 points of the hotspot.
                let radius = (24.0 * cursor.pixel_scale).ceil() + 1.0;
                (
                    -(*style as i64) - 1,
                    cursor.pixel_scale,
                    Point::new(radius, radius),
                    (radius * 2.0) as u32,
                    (radius * 2.0) as u32,
                )
            }
            CursorGraphic::SystemBitmap(bitmap) => (
                bitmap.key as i64,
                cursor.bitmap_zoom,
                Point::new(
                    bitmap.hotspot_x as f64 * cursor.bitmap_zoom,
                    bitmap.hotspot_y as f64 * cursor.bitmap_zoom,
                ),
                (bitmap.width as f64 * cursor.bitmap_zoom).ceil() as u32,
                (bitmap.height as f64 * cursor.bitmap_zoom).ceil() as u32,
            ),
        };
        if self
            .gpu
            .cursor_surface
            .as_ref()
            .is_none_or(|s| s.width < width || s.height < height)
        {
            let width = width.max(32).next_power_of_two();
            let height = height.max(32).next_power_of_two();
            let surface = self
                .gpu
                .dcomp_device
                .CreateSurface(
                    width,
                    height,
                    DXGI_FORMAT_B8G8R8A8_UNORM,
                    DXGI_ALPHA_MODE_PREMULTIPLIED,
                )
                .map_err(|e| e.code())?;
            self.gpu.cursor_surface = Some(CursorSurface {
                surface,
                width,
                height,
                image: None,
                offset: None,
                attached: false,
            });
        }

        let key = CursorFrameKey {
            graphic_id,
            scale,
            opacity: (cursor.opacity * 255.0).round() as u8,
        };
        let surface = self.gpu.cursor_surface.as_ref().unwrap();
        let redraw = surface.image.as_ref() != Some(&key);
        if redraw {
            let mut origin = POINT::default();
            let target = surface.surface.clone();
            let dxgi_surface: IDXGISurface =
                target.BeginDraw(None, &mut origin).map_err(|e| e.code())?;
            let source = CursorDraw {
                graphic: match &cursor.graphic {
                    CursorGraphic::Vector(style) => CursorGraphic::Vector(*style),
                    CursorGraphic::SystemBitmap(bitmap) => {
                        CursorGraphic::SystemBitmap(bitmap.clone())
                    }
                },
                position: Point::new(origin.x as f64 + hotspot.x, origin.y as f64 + hotspot.y),
                pixel_scale: cursor.pixel_scale,
                bitmap_zoom: cursor.bitmap_zoom,
                opacity: cursor.opacity,
            };
            let clip = D2D_RECT_F {
                left: origin.x as f32,
                top: origin.y as f32,
                right: origin.x as f32 + surface.width as f32,
                bottom: origin.y as f32 + surface.height as f32,
            };
            let draw = match create_target_bitmap(&self.gpu.d2d_ctx, &dxgi_surface) {
                Ok(bitmap) => {
                    self.gpu.d2d_ctx.SetTarget(&bitmap);
                    self.gpu.d2d_ctx.BeginDraw();
                    self.gpu.d2d_ctx.SetTransform(&Matrix3x2::identity());
                    self.gpu
                        .d2d_ctx
                        .PushAxisAlignedClip(&clip, D2D1_ANTIALIAS_MODE_ALIASED);
                    self.gpu.d2d_ctx.Clear(None);
                    self.draw_cursor(&source);
                    self.gpu.d2d_ctx.PopAxisAlignedClip();
                    let result = self.gpu.d2d_ctx.EndDraw(None, None);
                    self.gpu.d2d_ctx.SetTarget(None);
                    result
                }
                Err(error) => Err(error),
            };
            drop(dxgi_surface);
            let end = target.EndDraw();
            draw.and(end).map_err(|e| e.code())?;
        }

        let offset = Point::new(cursor.position.x - hotspot.x, cursor.position.y - hotspot.y);
        let surface = self.gpu.cursor_surface.as_mut().unwrap();
        let moved = surface.offset != Some(offset);
        if moved {
            self.gpu
                .cursor_visual
                .SetOffsetX2(offset.x as f32)
                .map_err(|e| e.code())?;
            self.gpu
                .cursor_visual
                .SetOffsetY2(offset.y as f32)
                .map_err(|e| e.code())?;
            surface.offset = Some(offset);
        }
        let attaching = !surface.attached;
        if attaching {
            self.gpu
                .cursor_visual
                .SetContent(&surface.surface)
                .map_err(|e| e.code())?;
            surface.attached = true;
        }
        surface.image = Some(key);
        Ok(redraw || moved || attaching)
    }

    unsafe fn draw_and_present(
        &mut self,
        frame: &OverlayFrame<'_>,
    ) -> Result<(), windows::core::HRESULT> {
        self.gpu.d2d_ctx.SetTarget(&self.gpu.target_bitmap);
        self.gpu.d2d_ctx.BeginDraw();
        self.gpu.d2d_ctx.SetTransform(&Matrix3x2::identity());
        self.gpu.d2d_ctx.Clear(Some(&D2D1_COLOR_F {
            r: 0.0,
            g: 0.0,
            b: 0.0,
            a: 0.0,
        }));

        // 1. Annotations (in display-local content space, transformed by zoom camera).
        if !frame.annotations.is_empty() {
            let z = frame.zoom as f32;
            let tx = -(frame.zoom_origin.x * frame.zoom) as f32;
            let ty = -(frame.zoom_origin.y * frame.zoom) as f32;
            let mat = Matrix3x2 {
                M11: z,
                M12: 0.0,
                M21: 0.0,
                M22: z,
                M31: tx,
                M32: ty,
            };
            self.gpu.d2d_ctx.SetTransform(&mat);
            for item in frame.annotations {
                self.draw_annotation(item, frame.now, frame.display_scale);
            }
            self.gpu.d2d_ctx.SetTransform(&Matrix3x2::identity());
        }

        // 2. Click marks (screen space, scaled with DPI and zoom).
        let click_scale = frame.display_scale * frame.zoom.sqrt();
        for mark in frame.click_marks {
            self.draw_click_mark(mark, click_scale);
        }

        self.gpu.d2d_ctx.EndDraw(None, None).map_err(|e| e.code())?;
        self.gpu
            .swap_chain
            .Present(0, DXGI_PRESENT_DO_NOT_WAIT)
            .ok()
            .map_err(|e| e.code())
    }

    unsafe fn make_brush(&self, c: ColorRgba) -> Option<ID2D1SolidColorBrush> {
        self.gpu
            .d2d_ctx
            .CreateSolidColorBrush(
                &D2D1_COLOR_F {
                    r: c.r,
                    g: c.g,
                    b: c.b,
                    a: c.a,
                },
                None,
            )
            .ok()
    }

    unsafe fn draw_annotation(&self, item: &AnnotationItem, now: f64, dpi_scale: f64) {
        match item {
            AnnotationItem::Stroke {
                look,
                unit,
                points,
                created_at,
            } => {
                if points.is_empty() {
                    return;
                }
                let w = (look.width * dpi_scale * *unit) as f32;
                let Ok(geo) = self.build_smooth_path(points) else {
                    return;
                };
                self.stroke_styled_geometry(&geo, look.style, look.color, w, now - *created_at);
                if look.style == InkStyle::Arrow {
                    let length = (look.width * 3.2).max(14.0) * dpi_scale * *unit;
                    if let (Some((a, b)), Some(&tip)) = (
                        ArrowHead::barbs(points, length, ArrowHead::DEFAULT_ANGLE),
                        points.last(),
                    ) {
                        if let Some(brush) = self.make_brush(look.color) {
                            self.gpu.d2d_ctx.DrawLine(
                                pt2f(a),
                                pt2f(tip),
                                &brush,
                                w,
                                &self.gpu.round_stroke,
                            );
                            self.gpu.d2d_ctx.DrawLine(
                                pt2f(tip),
                                pt2f(b),
                                &brush,
                                w,
                                &self.gpu.round_stroke,
                            );
                        }
                    }
                }
            }
            AnnotationItem::Highlight {
                kind,
                line,
                display,
                look,
                unit,
                created_at,
            } => {
                let age = (now - *created_at).max(0.0);
                let h = line.height;
                let around = line.inset_by(-h * 0.35, -h * 0.12);
                let corner = (around.height * 0.25).min(8.0 * dpi_scale * *unit) as f32;
                let line_style = match look.style {
                    InkStyle::Neon | InkStyle::Dashed => look.style,
                    _ => InkStyle::Marker,
                };
                let w = ((look.width * 0.45).max(2.0) * dpi_scale * *unit) as f32;

                match kind {
                    HighlightKind::Box => {
                        let progress = ease_in_out_cubic((age / 0.45).clamp(0.0, 1.0)) as f32;
                        let r = D2D1_ROUNDED_RECT {
                            rect: rect_f(around),
                            radiusX: corner,
                            radiusY: corner,
                        };
                        if let Ok(geo) = self.gpu.d2d_factory.CreateRoundedRectangleGeometry(&r) {
                            self.stroke_styled_geometry(
                                &geo,
                                line_style,
                                look.color.with_alpha(look.color.a * progress),
                                w,
                                age,
                            );
                        }
                    }
                    HighlightKind::Underline => {
                        let progress = ease_in_out_cubic((age / 0.35).clamp(0.0, 1.0));
                        let y = line.max_y() + h * 0.18;
                        let x_end = line.min_x() + line.width * progress;
                        let pts = [Point::new(line.min_x(), y), Point::new(x_end, y)];
                        if let Ok(geo) = self.build_smooth_path(&pts) {
                            self.stroke_styled_geometry(&geo, line_style, look.color, w, age);
                        }
                    }
                    HighlightKind::Fill => {
                        let progress = ease_in_out_cubic((age / 0.35).clamp(0.0, 1.0));
                        let x0 = line.min_x() - h * 0.15;
                        let x1 = x0 + (line.width + h * 0.30) * progress;
                        let pass_rect = Rect::new(x0, line.mid_y() - h * 0.625, x1 - x0, h * 1.25);
                        if let Some(brush) = self.make_brush(look.color.with_alpha(0.35)) {
                            self.gpu.d2d_ctx.FillRectangle(&rect_f(pass_rect), &brush);
                        }
                    }
                    HighlightKind::Spotlight => {
                        let alpha = (age / 0.25).clamp(0.0, 1.0) as f32;
                        if let Ok(mask_geo) = self.gpu.d2d_factory.CreatePathGeometry() {
                            if let Ok(sink) = mask_geo.Open() {
                                sink.SetFillMode(D2D1_FILL_MODE_ALTERNATE);
                                let outer = Rect::new(
                                    -display.width,
                                    -display.height,
                                    display.width * 3.0,
                                    display.height * 3.0,
                                );
                                add_rect_figure(&sink, outer);
                                add_rounded_rect_figure(&sink, around, corner as f64);
                                let _ = sink.Close();
                                if let Some(dim) =
                                    self.make_brush(ColorRgba::new(0.0, 0.0, 0.0, 0.55 * alpha))
                                {
                                    self.gpu.d2d_ctx.FillGeometry(&mask_geo, &dim, None);
                                }
                            }
                        }
                        let r = D2D1_ROUNDED_RECT {
                            rect: rect_f(around),
                            radiusX: corner,
                            radiusY: corner,
                        };
                        if let Some(edge) = self.make_brush(look.color.with_alpha(0.85 * alpha)) {
                            self.gpu.d2d_ctx.DrawRoundedRectangle(
                                &r,
                                &edge,
                                (1.5 * dpi_scale * *unit) as f32,
                                &self.gpu.round_stroke,
                            );
                        }
                    }
                }
            }
        }
    }

    unsafe fn stroke_styled_geometry<G: Interface>(
        &self,
        geo: &G,
        style: InkStyle,
        color: ColorRgba,
        w: f32,
        age: f64,
    ) {
        let Ok(d2d_geo) = geo.cast::<windows::Win32::Graphics::Direct2D::ID2D1Geometry>() else {
            return;
        };
        match style {
            InkStyle::Marker | InkStyle::Arrow => {
                if let Some(b) = self.make_brush(color) {
                    self.gpu
                        .d2d_ctx
                        .DrawGeometry(&d2d_geo, &b, w, &self.gpu.round_stroke);
                }
            }
            InkStyle::Neon => {
                let core = color.blended_with_white(0.7);
                let layers = [
                    (w * 3.6, color.with_alpha(0.14 * color.a)),
                    (w * 2.0, color.with_alpha(0.32 * color.a)),
                    (w, color),
                    (w * 0.38, core),
                ];
                for (lw, col) in layers {
                    if let Some(b) = self.make_brush(col) {
                        self.gpu
                            .d2d_ctx
                            .DrawGeometry(&d2d_geo, &b, lw, &self.gpu.round_stroke);
                    }
                }
            }
            InkStyle::Highlighter => {
                if let Some(b) = self.make_brush(color.with_alpha(0.38 * color.a)) {
                    self.gpu
                        .d2d_ctx
                        .DrawGeometry(&d2d_geo, &b, w * 3.6, &self.gpu.flat_stroke);
                }
            }
            InkStyle::Dashed => {
                let phase = -((age / 0.6) % 1.0) as f32 * 4.6;
                let dashes = [2.4f32, 2.2f32];
                if let Ok(dash_style) = self.gpu.d2d_factory.CreateStrokeStyle(
                    &D2D1_STROKE_STYLE_PROPERTIES1 {
                        startCap: D2D1_CAP_STYLE_ROUND,
                        endCap: D2D1_CAP_STYLE_ROUND,
                        dashCap: D2D1_CAP_STYLE_ROUND,
                        lineJoin: D2D1_LINE_JOIN_ROUND,
                        miterLimit: 10.0,
                        dashStyle: D2D1_DASH_STYLE_CUSTOM,
                        dashOffset: phase,
                        ..Default::default()
                    },
                    Some(&dashes),
                ) {
                    if let Some(b) = self.make_brush(color) {
                        self.gpu.d2d_ctx.DrawGeometry(&d2d_geo, &b, w, &dash_style);
                    }
                }
            }
        }
    }

    unsafe fn build_smooth_path(
        &self,
        points: &[Point],
    ) -> windows::core::Result<ID2D1PathGeometry1> {
        let geo = self.gpu.d2d_factory.CreatePathGeometry()?;
        let sink = geo.Open()?;
        let first = points[0];
        sink.BeginFigure(pt2f(first), D2D1_FIGURE_BEGIN_HOLLOW);
        if points.len() <= 2 {
            let end = if points.len() == 2 {
                points[1]
            } else {
                Point::new(first.x + 0.01, first.y)
            };
            sink.AddLine(pt2f(end));
        } else {
            for i in 1..(points.len() - 1) {
                let mid = Point::new(
                    (points[i].x + points[i + 1].x) * 0.5,
                    (points[i].y + points[i + 1].y) * 0.5,
                );
                sink.AddQuadraticBezier(&D2D1_QUADRATIC_BEZIER_SEGMENT {
                    point1: pt2f(points[i]),
                    point2: pt2f(mid),
                });
            }
            sink.AddLine(pt2f(points[points.len() - 1]));
        }
        sink.EndFigure(D2D1_FIGURE_END_OPEN);
        sink.Close()?;
        Ok(geo)
    }

    unsafe fn draw_click_mark(&self, mark: &ClickMarkDraw, scale: f64) {
        let r = (mark.look.radius * scale) as f32;
        let ellipse = D2D1_ELLIPSE {
            point: pt2f(mark.center),
            radiusX: r,
            radiusY: r,
        };
        let col = mark
            .color
            .with_alpha((mark.look.opacity as f32).clamp(0.0, 1.0));
        if let Some(brush) = self.make_brush(col) {
            if mark.look.filled {
                self.gpu.d2d_ctx.FillEllipse(&ellipse, &brush);
            } else {
                self.gpu.d2d_ctx.DrawEllipse(
                    &ellipse,
                    &brush,
                    (mark.look.line_width * scale) as f32,
                    &self.gpu.round_stroke,
                );
            }
        }
    }

    unsafe fn draw_cursor(&mut self, cursor: &CursorDraw) {
        let alpha = cursor.opacity.clamp(0.0, 1.0) as f32;
        match &cursor.graphic {
            CursorGraphic::SystemBitmap(sys_bmp) => {
                let d2d_bmp = if let Some(existing) = self.gpu.sys_cursor_bitmaps.get(&sys_bmp.key)
                {
                    existing.clone()
                } else {
                    let props = D2D1_BITMAP_PROPERTIES1 {
                        pixelFormat: D2D1_PIXEL_FORMAT {
                            format: DXGI_FORMAT_B8G8R8A8_UNORM,
                            alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
                        },
                        dpiX: 96.0,
                        dpiY: 96.0,
                        bitmapOptions: D2D1_BITMAP_OPTIONS_NONE,
                        colorContext: std::mem::ManuallyDrop::new(None),
                    };
                    let Ok(created) = self.gpu.d2d_ctx.CreateBitmap(
                        D2D_SIZE_U {
                            width: sys_bmp.width,
                            height: sys_bmp.height,
                        },
                        Some(sys_bmp.bgra.as_ptr() as *const _),
                        sys_bmp.width * 4,
                        &props,
                    ) else {
                        return;
                    };
                    if self.gpu.sys_cursor_bitmaps.len() > 64 {
                        self.gpu.sys_cursor_bitmaps.clear();
                    }
                    self.gpu
                        .sys_cursor_bitmaps
                        .insert(sys_bmp.key, created.clone());
                    created
                };

                let z = cursor.bitmap_zoom as f32;
                let x = cursor.position.x as f32 - sys_bmp.hotspot_x * z;
                let y = cursor.position.y as f32 - sys_bmp.hotspot_y * z;
                let dst = D2D_RECT_F {
                    left: x,
                    top: y,
                    right: x + sys_bmp.width as f32 * z,
                    bottom: y + sys_bmp.height as f32 * z,
                };
                self.gpu.d2d_ctx.DrawBitmap(
                    &d2d_bmp,
                    Some(&dst),
                    alpha,
                    D2D1_INTERPOLATION_MODE_LINEAR,
                    None,
                    None,
                );
            }
            CursorGraphic::Vector(style) => {
                if *style == CursorStyle::System {
                    return;
                }
                let s = cursor.pixel_scale as f32;
                let transform = Matrix3x2 {
                    M11: s,
                    M12: 0.0,
                    M21: 0.0,
                    M22: s,
                    M31: cursor.position.x as f32,
                    M32: cursor.position.y as f32,
                };
                self.gpu.d2d_ctx.SetTransform(&transform);

                match style {
                    CursorStyle::System => {}
                    CursorStyle::Classic => {
                        self.draw_arrow_cursor(
                            CursorFill::Solid(ColorRgba::new(0.07, 0.07, 0.08, alpha)),
                            ColorRgba::new(1.0, 1.0, 1.0, alpha),
                            1.5,
                            alpha,
                        );
                    }
                    CursorStyle::Light => {
                        self.draw_arrow_cursor(
                            CursorFill::Solid(ColorRgba::new(1.0, 1.0, 1.0, alpha)),
                            ColorRgba::new(0.10, 0.10, 0.12, alpha),
                            1.2,
                            alpha,
                        );
                    }
                    CursorStyle::Ocean => {
                        self.draw_arrow_cursor(
                            CursorFill::Gradient(
                                ColorRgba::new(0.18, 0.50, 0.93, alpha),
                                ColorRgba::new(0.34, 0.80, 0.95, alpha),
                            ),
                            ColorRgba::new(1.0, 1.0, 1.0, alpha),
                            1.6,
                            alpha,
                        );
                    }
                    CursorStyle::Sunset => {
                        self.draw_arrow_cursor(
                            CursorFill::Gradient(
                                ColorRgba::new(1.00, 0.48, 0.09, alpha),
                                ColorRgba::new(1.00, 0.24, 0.47, alpha),
                            ),
                            ColorRgba::new(1.0, 1.0, 1.0, alpha),
                            1.6,
                            alpha,
                        );
                    }
                    CursorStyle::Mint => {
                        self.draw_mint_pointer(alpha);
                    }
                    CursorStyle::Dot => {
                        let r = 7.5f32;
                        let shadow = D2D1_ELLIPSE {
                            point: D2D_POINT_2F { x: 0.0, y: 1.2 },
                            radiusX: r + 1.4,
                            radiusY: r + 1.4,
                        };
                        if let Some(sb) =
                            self.make_brush(ColorRgba::new(0.0, 0.0, 0.0, 0.24 * alpha))
                        {
                            self.gpu.d2d_ctx.FillEllipse(&shadow, &sb);
                        }
                        let e = D2D1_ELLIPSE {
                            point: D2D_POINT_2F { x: 0.0, y: 0.0 },
                            radiusX: r,
                            radiusY: r,
                        };
                        if let Some(stroke) = self.make_brush(ColorRgba::new(1.0, 1.0, 1.0, alpha))
                        {
                            self.gpu
                                .d2d_ctx
                                .DrawEllipse(&e, &stroke, 3.0, &self.gpu.round_stroke);
                        }
                        if let Some(fill) =
                            self.make_brush(ColorRgba::new(0.10, 0.10, 0.12, 0.88 * alpha))
                        {
                            self.gpu.d2d_ctx.FillEllipse(&e, &fill);
                        }
                    }
                    CursorStyle::Spotlight => {
                        let halo = D2D1_ELLIPSE {
                            point: D2D_POINT_2F { x: 0.0, y: 0.0 },
                            radiusX: 17.0,
                            radiusY: 17.0,
                        };
                        if let Some(hb) =
                            self.make_brush(ColorRgba::new(1.0, 0.84, 0.04, 0.42 * alpha))
                        {
                            self.gpu.d2d_ctx.FillEllipse(&halo, &hb);
                        }
                        self.draw_arrow_cursor(
                            CursorFill::Solid(ColorRgba::new(0.07, 0.07, 0.08, alpha)),
                            ColorRgba::new(1.0, 1.0, 1.0, alpha),
                            1.5,
                            alpha,
                        );
                    }
                }

                self.gpu.d2d_ctx.SetTransform(&Matrix3x2::identity());
            }
        }
    }

    unsafe fn draw_arrow_cursor(&self, fill: CursorFill, stroke: ColorRgba, lw: f32, alpha: f32) {
        let pts = [
            D2D_POINT_2F { x: 0.0, y: 0.0 },
            D2D_POINT_2F { x: 0.0, y: 16.5 },
            D2D_POINT_2F { x: 3.9, y: 12.8 },
            D2D_POINT_2F { x: 6.6, y: 19.0 },
            D2D_POINT_2F { x: 9.3, y: 17.8 },
            D2D_POINT_2F { x: 6.7, y: 11.8 },
            D2D_POINT_2F { x: 11.8, y: 11.8 },
        ];
        self.draw_polygon_cursor(&pts, fill, stroke, lw, alpha, 11.8, 19.0);
    }

    unsafe fn draw_mint_pointer(&self, alpha: f32) {
        let pts = [
            D2D_POINT_2F { x: 0.0, y: 0.0 },
            D2D_POINT_2F { x: 0.0, y: 15.5 },
            D2D_POINT_2F { x: 4.4, y: 11.4 },
            D2D_POINT_2F { x: 10.9, y: 11.4 },
        ];
        self.draw_polygon_cursor(
            &pts,
            CursorFill::Gradient(
                ColorRgba::new(0.0, 0.72, 0.58, alpha),
                ColorRgba::new(0.33, 0.94, 0.77, alpha),
            ),
            ColorRgba::new(1.0, 1.0, 1.0, alpha),
            1.6,
            alpha,
            10.9,
            15.5,
        );
    }

    #[allow(clippy::too_many_arguments)]
    unsafe fn draw_polygon_cursor(
        &self,
        pts: &[D2D_POINT_2F],
        fill: CursorFill,
        stroke: ColorRgba,
        lw: f32,
        alpha: f32,
        max_x: f32,
        max_y: f32,
    ) {
        let Ok(geo) = self.gpu.d2d_factory.CreatePathGeometry() else {
            return;
        };
        let Ok(sink) = geo.Open() else {
            return;
        };
        sink.BeginFigure(pts[0], D2D1_FIGURE_BEGIN_FILLED);
        for &p in &pts[1..] {
            sink.AddLine(p);
        }
        sink.EndFigure(D2D1_FIGURE_END_CLOSED);
        if sink.Close().is_err() {
            return;
        }

        if let Some(sb) = self.make_brush(ColorRgba::new(0.0, 0.0, 0.0, 0.24 * alpha)) {
            let mut cur = Matrix3x2::default();
            self.gpu.d2d_ctx.GetTransform(&mut cur);
            let shifted = Matrix3x2 {
                M31: cur.M31,
                M32: cur.M32 + 1.2 * cur.M22,
                ..cur
            };
            self.gpu.d2d_ctx.SetTransform(&shifted);
            self.gpu
                .d2d_ctx
                .DrawGeometry(&geo, &sb, lw * 2.0 + 1.4, &self.gpu.round_stroke);
            self.gpu.d2d_ctx.SetTransform(&cur);
        }

        if let Some(sb) = self.make_brush(stroke) {
            self.gpu
                .d2d_ctx
                .DrawGeometry(&geo, &sb, lw * 2.0, &self.gpu.round_stroke);
        }
        match fill {
            CursorFill::Solid(c) => {
                if let Some(fb) = self.make_brush(c) {
                    self.gpu.d2d_ctx.FillGeometry(&geo, &fb, None);
                }
            }
            CursorFill::Gradient(from, to) => {
                if let Some(gb) = self.make_gradient_brush(from, to, max_x, max_y) {
                    self.gpu.d2d_ctx.FillGeometry(&geo, &gb, None);
                }
            }
        }
    }

    unsafe fn make_gradient_brush(
        &self,
        from: ColorRgba,
        to: ColorRgba,
        max_x: f32,
        max_y: f32,
    ) -> Option<ID2D1LinearGradientBrush> {
        let stops = [
            D2D1_GRADIENT_STOP {
                position: 0.0,
                color: D2D1_COLOR_F {
                    r: from.r,
                    g: from.g,
                    b: from.b,
                    a: from.a,
                },
            },
            D2D1_GRADIENT_STOP {
                position: 1.0,
                color: D2D1_COLOR_F {
                    r: to.r,
                    g: to.g,
                    b: to.b,
                    a: to.a,
                },
            },
        ];
        let coll = self
            .gpu
            .d2d_ctx
            .CreateGradientStopCollection(
                &stops,
                D2D1_COLOR_SPACE_SRGB,
                D2D1_COLOR_SPACE_SRGB,
                D2D1_BUFFER_PRECISION_8BPC_UNORM,
                D2D1_EXTEND_MODE_CLAMP,
                D2D1_COLOR_INTERPOLATION_MODE_PREMULTIPLIED,
            )
            .ok()?;
        let props = D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES {
            startPoint: D2D_POINT_2F { x: 0.0, y: 0.0 },
            endPoint: D2D_POINT_2F { x: max_x, y: max_y },
        };
        self.gpu
            .d2d_ctx
            .CreateLinearGradientBrush(&props, None, &coll)
            .ok()
    }
}

impl Drop for OverlayWindow {
    fn drop(&mut self) {
        self.renderer = None;
        unsafe {
            let _ = DestroyWindow(self.hwnd);
        }
    }
}

fn is_annotation_animating(item: &AnnotationItem, now: f64) -> bool {
    match item {
        AnnotationItem::Stroke { look, .. } => look.style == InkStyle::Dashed,
        AnnotationItem::Highlight {
            kind,
            look,
            created_at,
            ..
        } => {
            if look.style == InkStyle::Dashed
                && matches!(kind, HighlightKind::Box | HighlightKind::Underline)
            {
                return true;
            }
            let dur = match kind {
                HighlightKind::Box => 0.46,
                HighlightKind::Underline | HighlightKind::Fill => 0.36,
                HighlightKind::Spotlight => 0.26,
            };
            now - *created_at < dur
        }
    }
}

unsafe fn create_gpu_resources(hwnd: HWND, w_px: u32, h_px: u32) -> Result<GpuResources, String> {
    let mut d3d_device: Option<ID3D11Device> = None;
    let res = D3D11CreateDevice(
        None,
        D3D_DRIVER_TYPE_HARDWARE,
        None,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        None,
        D3D11_SDK_VERSION,
        Some(&mut d3d_device),
        None,
        None,
    );
    if res.is_err() {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_WARP,
            None,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut d3d_device),
            None,
            None,
        )
        .map_err(|e| format!("D3D11CreateDevice failed: {e}"))?;
    }
    let d3d_device = d3d_device.ok_or("D3D11CreateDevice returned null")?;
    let dxgi_device: IDXGIDevice = d3d_device.cast().map_err(|e| e.to_string())?;
    let dxgi_adapter = dxgi_device.GetAdapter().map_err(|e| e.to_string())?;
    let dxgi_factory: IDXGIFactory2 = dxgi_adapter.GetParent().map_err(|e| e.to_string())?;

    let sc_desc = DXGI_SWAP_CHAIN_DESC1 {
        Width: w_px,
        Height: h_px,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        Stereo: false.into(),
        SampleDesc: DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
        BufferCount: 2,
        Scaling: DXGI_SCALING_STRETCH,
        SwapEffect: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
        AlphaMode: DXGI_ALPHA_MODE_PREMULTIPLIED,
        Flags: 0,
    };
    let swap_chain = dxgi_factory
        .CreateSwapChainForComposition(&dxgi_device, &sc_desc, None)
        .map_err(|e| format!("CreateSwapChainForComposition failed: {e}"))?;

    let d2d_factory: ID2D1Factory1 =
        D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)
            .map_err(|e| format!("D2D1CreateFactory failed: {e}"))?;
    let d2d_device = d2d_factory
        .CreateDevice(&dxgi_device)
        .map_err(|e| format!("CreateDevice(D2D) failed: {e}"))?;
    let d2d_ctx = d2d_device
        .CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE)
        .map_err(|e| format!("CreateDeviceContext failed: {e}"))?;

    let target_bitmap = bind_backbuffer(&d2d_ctx, &swap_chain)?;

    let dcomp_device: IDCompositionDevice = DCompositionCreateDevice(&dxgi_device)
        .map_err(|e| format!("DCompositionCreateDevice failed: {e}"))?;
    let dcomp_target = dcomp_device
        .CreateTargetForHwnd(hwnd, true)
        .map_err(|e| format!("CreateTargetForHwnd failed: {e}"))?;
    let dcomp_visual = dcomp_device
        .CreateVisual()
        .map_err(|e| format!("CreateVisual failed: {e}"))?;
    let annotation_visual = dcomp_device.CreateVisual().map_err(|e| e.to_string())?;
    let cursor_visual = dcomp_device.CreateVisual().map_err(|e| e.to_string())?;
    dcomp_visual
        .AddVisual(&annotation_visual, true, None)
        .map_err(|e| e.to_string())?;
    dcomp_visual
        .AddVisual(&cursor_visual, true, &annotation_visual)
        .map_err(|e| e.to_string())?;
    dcomp_target
        .SetRoot(&dcomp_visual)
        .map_err(|e| format!("SetRoot failed: {e}"))?;
    dcomp_device
        .Commit()
        .map_err(|e| format!("DComp Commit failed: {e}"))?;

    let round_stroke = d2d_factory
        .CreateStrokeStyle(
            &D2D1_STROKE_STYLE_PROPERTIES1 {
                startCap: D2D1_CAP_STYLE_ROUND,
                endCap: D2D1_CAP_STYLE_ROUND,
                dashCap: D2D1_CAP_STYLE_ROUND,
                lineJoin: D2D1_LINE_JOIN_ROUND,
                miterLimit: 10.0,
                ..Default::default()
            },
            None,
        )
        .map_err(|e| e.to_string())?;
    let flat_stroke = d2d_factory
        .CreateStrokeStyle(
            &D2D1_STROKE_STYLE_PROPERTIES1 {
                startCap: D2D1_CAP_STYLE_FLAT,
                endCap: D2D1_CAP_STYLE_FLAT,
                dashCap: D2D1_CAP_STYLE_FLAT,
                lineJoin: D2D1_LINE_JOIN_ROUND,
                miterLimit: 10.0,
                ..Default::default()
            },
            None,
        )
        .map_err(|e| e.to_string())?;

    Ok(GpuResources {
        _d3d_device: d3d_device,
        d2d_factory,
        _d2d_device: d2d_device,
        d2d_ctx,
        swap_chain,
        target_bitmap,
        dcomp_device,
        _dcomp_target: dcomp_target,
        annotation_visual,
        cursor_visual,
        cursor_surface: None,
        round_stroke,
        flat_stroke,
        sys_cursor_bitmaps: HashMap::new(),
    })
}

enum CursorFill {
    Solid(ColorRgba),
    Gradient(ColorRgba, ColorRgba),
}

unsafe fn bind_backbuffer(
    d2d_ctx: &ID2D1DeviceContext,
    swap_chain: &IDXGISwapChain1,
) -> Result<ID2D1Bitmap1, String> {
    let surface: IDXGISurface = swap_chain
        .GetBuffer(0)
        .map_err(|e| format!("SwapChain::GetBuffer failed: {e}"))?;
    create_target_bitmap(d2d_ctx, &surface)
        .map_err(|e| format!("CreateBitmapFromDxgiSurface failed: {e}"))
}

unsafe fn create_target_bitmap(
    d2d_ctx: &ID2D1DeviceContext,
    surface: &IDXGISurface,
) -> windows::core::Result<ID2D1Bitmap1> {
    let props = D2D1_BITMAP_PROPERTIES1 {
        pixelFormat: D2D1_PIXEL_FORMAT {
            format: DXGI_FORMAT_B8G8R8A8_UNORM,
            alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
        },
        dpiX: 96.0,
        dpiY: 96.0,
        bitmapOptions: D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        colorContext: std::mem::ManuallyDrop::new(None),
    };
    d2d_ctx.CreateBitmapFromDxgiSurface(surface, Some(&props))
}

#[inline]
fn pt2f(p: Point) -> D2D_POINT_2F {
    D2D_POINT_2F {
        x: p.x as f32,
        y: p.y as f32,
    }
}

#[inline]
fn rect_f(r: Rect) -> D2D_RECT_F {
    D2D_RECT_F {
        left: r.min_x() as f32,
        top: r.min_y() as f32,
        right: r.max_x() as f32,
        bottom: r.max_y() as f32,
    }
}

unsafe fn add_rect_figure(
    sink: &windows::Win32::Graphics::Direct2D::ID2D1GeometrySink,
    r: Rect,
) {
    sink.BeginFigure(
        pt2f(Point::new(r.min_x(), r.min_y())),
        D2D1_FIGURE_BEGIN_FILLED,
    );
    sink.AddLine(pt2f(Point::new(r.max_x(), r.min_y())));
    sink.AddLine(pt2f(Point::new(r.max_x(), r.max_y())));
    sink.AddLine(pt2f(Point::new(r.min_x(), r.max_y())));
    sink.EndFigure(D2D1_FIGURE_END_CLOSED);
}

unsafe fn add_rounded_rect_figure(
    sink: &windows::Win32::Graphics::Direct2D::ID2D1GeometrySink,
    r: Rect,
    radius: f64,
) {
    let rad = radius.min(r.width * 0.5).min(r.height * 0.5);
    let k = rad * 0.552_284_749_8;
    let x0 = r.min_x();
    let y0 = r.min_y();
    let x1 = r.max_x();
    let y1 = r.max_y();

    sink.BeginFigure(pt2f(Point::new(x0 + rad, y0)), D2D1_FIGURE_BEGIN_FILLED);
    sink.AddLine(pt2f(Point::new(x1 - rad, y0)));
    sink.AddBezier(&D2D1_BEZIER_SEGMENT {
        point1: pt2f(Point::new(x1 - rad + k, y0)),
        point2: pt2f(Point::new(x1, y0 + rad - k)),
        point3: pt2f(Point::new(x1, y0 + rad)),
    });
    sink.AddLine(pt2f(Point::new(x1, y1 - rad)));
    sink.AddBezier(&D2D1_BEZIER_SEGMENT {
        point1: pt2f(Point::new(x1, y1 - rad + k)),
        point2: pt2f(Point::new(x1 - rad + k, y1)),
        point3: pt2f(Point::new(x1 - rad, y1)),
    });
    sink.AddLine(pt2f(Point::new(x0 + rad, y1)));
    sink.AddBezier(&D2D1_BEZIER_SEGMENT {
        point1: pt2f(Point::new(x0 + rad - k, y1)),
        point2: pt2f(Point::new(x0, y1 - rad + k)),
        point3: pt2f(Point::new(x0, y1 - rad)),
    });
    sink.AddLine(pt2f(Point::new(x0, y0 + rad)));
    sink.AddBezier(&D2D1_BEZIER_SEGMENT {
        point1: pt2f(Point::new(x0, y0 + rad - k)),
        point2: pt2f(Point::new(x0 + rad - k, y0)),
        point3: pt2f(Point::new(x0 + rad, y0)),
    });
    sink.EndFigure(D2D1_FIGURE_END_CLOSED);
}

unsafe extern "system" fn overlay_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if msg == WM_PAINT {
        CHECK_DEVICE.set(true);
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

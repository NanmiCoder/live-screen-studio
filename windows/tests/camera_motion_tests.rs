use livezoom_core::core::camera::{CameraConfig, CameraPhase, ViewportMath, ZoomCamera};
use livezoom_core::core::follow_preset::FollowPreset;
use livezoom_core::core::geometry::{Point, Rect, Size};
use livezoom_core::core::settings::{AppSettings, FollowStyle};

const DISPLAY: Size = Size::new(4608.0, 3072.0);
const CENTER: Point = Point::new(2304.0, 1536.0);
const FRAME: f64 = 1.0 / 120.0;

fn assert_close(actual: f64, expected: f64) {
    assert!((actual - expected).abs() < 1e-8, "{actual} != {expected}");
}

#[test]
fn windows_defaults_to_continuous_and_keeps_saved_presets() {
    assert_eq!(AppSettings::default().follow_style, FollowStyle::Continuous);
    for (json, style) in [
        (r#"{}"#, FollowStyle::Continuous),
        (r#"{"followStyle":"edge"}"#, FollowStyle::Edge),
        (r#"{"followStyle":"calm"}"#, FollowStyle::Calm),
    ] {
        let saved: AppSettings = serde_json::from_str(json).unwrap();
        assert_eq!(saved.follow_style, style);
    }
}

#[test]
fn continuous_tracks_small_sweeps_without_delay_or_drift() {
    for level in [1.25, 2.0, 2.333, 4.0] {
        let mut camera = ZoomCamera::new(DISPLAY, CameraConfig::default());
        camera.zoom_in(level, CENTER, 0.0);
        camera.update(CENTER, 0.5, FRAME);

        let compositor_zoom = camera.zoom() as f32 as f64;
        let mut previous_origin: Option<Point> = None;
        let mut now = 0.5;
        for step in 0..100 {
            let dt = if step % 3 == 0 { FRAME * 2.0 } else { FRAME };
            let cursor = Point::new(2190.0 + step as f64, 1660.0 - step as f64);
            now += dt;
            camera.update(cursor, now, dt);

            let viewport = camera.viewport();
            let pan_ratio = 1.0 - 1.0 / level;
            assert_close(viewport.x, cursor.x * pan_ratio);
            assert_close(viewport.y, cursor.y * pan_ratio);
            let hotspot = camera.screen_point(cursor);
            assert_close(hotspot.x, cursor.x);
            assert_close(hotspot.y, cursor.y);

            let viewport = ViewportMath::rect(camera.center(), compositor_zoom, DISPLAY);
            let origin = ViewportMath::magnifier_origin(viewport, DISPLAY);
            assert!(
                Rect::new(origin.x, origin.y, viewport.width, viewport.height)
                    .contains_pixel(cursor)
            );
            let submitted_x = (cursor.x - origin.x) * compositor_zoom;
            let submitted_y = (cursor.y - origin.y) * compositor_zoom;
            assert!((submitted_x - cursor.x).abs() <= compositor_zoom * 0.5 + 0.001);
            assert!((submitted_y - cursor.y).abs() <= compositor_zoom * 0.5 + 0.001);
            if let Some(previous) = previous_origin {
                assert!((0.0..=1.0).contains(&(origin.x - previous.x)));
                assert!((-1.0..=0.0).contains(&(origin.y - previous.y)));
            }
            previous_origin = Some(origin);

            let settled = camera.viewport();
            now += FRAME * 0.5;
            camera.update(cursor, now, FRAME * 0.5);
            assert_eq!(camera.viewport(), settled);
        }
    }
}

#[test]
fn continuous_keeps_the_hotspot_at_the_cursor_through_zooming() {
    let mut camera = ZoomCamera::new(DISPLAY, CameraConfig::default());
    camera.zoom_in(2.5, CENTER, 0.0);

    let mut previous_zoom = 1.0;
    let mut cursor = CENTER;
    for frame in 1..=60 {
        cursor = Point::new(CENTER.x + frame as f64 * 9.0, CENTER.y - frame as f64 * 7.0);
        camera.update(cursor, frame as f64 * FRAME, FRAME);
        let hotspot = camera.screen_point(cursor);
        assert_close(hotspot.x, cursor.x);
        assert_close(hotspot.y, cursor.y);
        assert!(camera.zoom() >= previous_zoom);
        previous_zoom = camera.zoom();
    }
    assert_eq!(camera.phase(), CameraPhase::Zoomed);

    camera.zoom_out(cursor, 0.5);
    for frame in 1..=60 {
        cursor = Point::new(cursor.x - 9.0, cursor.y + 7.0);
        camera.update(cursor, 0.5 + frame as f64 * FRAME, FRAME);
        let hotspot = camera.screen_point(cursor);
        assert_close(hotspot.x, cursor.x);
        assert_close(hotspot.y, cursor.y);
        assert!(camera.zoom() <= previous_zoom);
        previous_zoom = camera.zoom();
    }
    assert_eq!(camera.phase(), CameraPhase::Idle);
}

#[test]
fn edge_tracks_the_first_rim_crossing_and_holds_on_retreat() {
    let mut camera = ZoomCamera::new(
        DISPLAY,
        CameraConfig {
            follow: FollowPreset::EDGE,
            ..CameraConfig::default()
        },
    );
    camera.zoom_in(2.0, CENTER, 0.0);
    camera.update(CENTER, 0.5, FRAME);
    let rim = camera.viewport().max_x() - camera.viewport().width * FollowPreset::EDGE.margin;

    camera.update(Point::new(rim - 0.5, CENTER.y), 0.51, 0.01);
    assert_eq!(camera.center(), CENTER);
    for step in 0..100 {
        let offset = step as f64 + 0.5;
        let cursor = Point::new(rim + offset, CENTER.y);
        camera.update(cursor, 0.52 + step as f64 * FRAME, FRAME);
        assert_close(camera.center().x, CENTER.x + offset);
        assert_close(camera.screen_point(cursor).x, DISPLAY.width * 0.92);
    }

    let settled = camera.center();
    camera.update(Point::new(rim + 50.0, CENTER.y), 1.4, FRAME);
    assert_eq!(camera.center(), settled);
    camera.update(Point::new(DISPLAY.width - 1.0, CENTER.y), 1.41, FRAME);
    assert_close(camera.viewport().max_x(), DISPLAY.width);
}

#[test]
fn edge_zoom_in_retains_a_pan_after_the_cursor_retreats() {
    let mut camera = ZoomCamera::new(
        DISPLAY,
        CameraConfig {
            follow: FollowPreset::EDGE,
            ..CameraConfig::default()
        },
    );
    camera.zoom_in(2.0, CENTER, 0.0);
    let cursor = Point::new(4000.0, CENTER.y);
    camera.update(cursor, 0.2, FRAME);
    assert_close(camera.screen_point(cursor).x, DISPLAY.width * 0.92);
    let anchored = camera.screen_point(CENTER);

    for now in [0.21, 0.3, 0.4, 0.5] {
        camera.update(CENTER, now, FRAME);
        assert_close(camera.screen_point(CENTER).x, anchored.x);
    }
    assert_eq!(camera.phase(), CameraPhase::Zoomed);
}

#[test]
fn pausing_during_ink_freezes_zoom_and_resumes_at_the_held_progress() {
    let mut camera = ZoomCamera::new(DISPLAY, CameraConfig::default());
    camera.zoom_in(2.0, CENTER, 0.0);
    camera.update(CENTER, 0.15, FRAME);
    let held = camera.viewport();
    let mut reference = camera.clone();

    camera.set_follow_paused(true);
    camera.adjust_zoom(1.5);
    camera.update(Point::ZERO, 0.50, FRAME);
    camera.update(Point::new(4400.0, 2900.0), 1.10, FRAME);
    assert_eq!(camera.viewport(), held);
    assert_eq!(camera.phase(), CameraPhase::ZoomingIn);
    assert_eq!(camera.target_zoom(), 2.0);

    camera.set_follow_paused(false);
    camera.update(CENTER, 1.12, 0.02);
    reference.update(CENTER, 0.17, 0.02);
    assert_close(camera.zoom(), reference.zoom());
    assert_eq!(camera.center(), reference.center());
    camera.update(CENTER, 1.45, FRAME);

    camera.adjust_zoom(1.5);
    let held = camera.viewport();
    camera.set_follow_paused(true);
    camera.update(Point::ZERO, 1.5, FRAME);
    assert_eq!(camera.viewport(), held);
    camera.set_follow_paused(false);
    camera.update(CENTER, 1.51, FRAME);
    assert!(camera.zoom() > 2.0);
}

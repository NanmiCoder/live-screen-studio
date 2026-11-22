use livezoom_core::core::annotation::{ArrowHead, HighlightKind, TextLines};
use livezoom_core::core::camera::{CameraConfig, CameraPhase, ViewportMath, ZoomCamera};
use livezoom_core::core::cursor::{ClickEffect, CursorMotion};
use livezoom_core::core::follow_preset::FollowPreset;
use livezoom_core::core::geometry::{Point, Rect, Size, Vector};
use livezoom_core::core::input_fsm::{InputAction, InputFsm, Modifiers};
use livezoom_core::core::settings::{KeyCombo, TriggerButton};
use livezoom_core::core::smooth_damp::smooth_damp_step;

const DISPLAY: Size = Size::new(2304.0, 1536.0);
const FRAME: f64 = 1.0 / 60.0;

fn run(
    camera: &mut ZoomCamera,
    cursor: Point,
    start: f64,
    seconds: f64,
    mut each: impl FnMut(f64, &ZoomCamera),
) -> f64 {
    let mut t = start;
    while t < start + seconds {
        t += FRAME;
        camera.update(cursor, t, FRAME);
        each(t, camera);
    }
    t
}

fn assert_inside_display(camera: &ZoomCamera) {
    let r = camera.viewport();
    let eps = 0.001;
    assert!(r.min_x() >= -eps, "min_x {}", r.min_x());
    assert!(r.min_y() >= -eps, "min_y {}", r.min_y());
    assert!(r.max_x() <= DISPLAY.width + eps, "max_x {}", r.max_x());
    assert!(r.max_y() <= DISPLAY.height + eps, "max_y {}", r.max_y());
}

fn calm_camera() -> ZoomCamera {
    let mut cfg = CameraConfig::default();
    cfg.follow = FollowPreset::CALM;
    ZoomCamera::new(DISPLAY, cfg)
}

#[test]
fn zoom_in_keeps_content_under_cursor_in_place() {
    let mut camera = ZoomCamera::new(DISPLAY, CameraConfig::default());
    let cursor = Point::new(1200.0, 800.0);
    camera.zoom_in(2.0, cursor, 0.0);
    assert_eq!(camera.phase(), CameraPhase::ZoomingIn);
    run(&mut camera, cursor, 0.0, 0.7, |_, cam| {
        let p = cam.screen_point(cursor);
        assert!((p.x - cursor.x).abs() < 0.01);
        assert!((p.y - cursor.y).abs() < 0.01);
    });
    assert_eq!(camera.phase(), CameraPhase::Zoomed);
    assert!((camera.zoom() - 2.0).abs() < 1e-9);
}

#[test]
fn zoom_in_near_edge_stays_inside_display() {
    let mut camera = ZoomCamera::new(DISPLAY, CameraConfig::default());
    let cursor = Point::new(10.0, 1530.0);
    camera.zoom_in(3.0, cursor, 0.0);
    run(&mut camera, cursor, 0.0, 1.0, |_, cam| {
        assert_inside_display(cam);
    });
    assert!(camera.viewport().inset_by(-0.01, -0.01).contains(cursor));
}

#[test]
fn edge_push_holds_viewport_still_inside_and_glides_at_edge() {
    let mut cfg = CameraConfig::default();
    cfg.follow = FollowPreset::EDGE;
    let mut camera = ZoomCamera::new(DISPLAY, cfg);
    let start = Point::new(1152.0, 768.0);
    camera.zoom_in(1.75, start, 0.0);
    let mut t = run(&mut camera, start, 0.0, 0.6, |_, _| {});
    assert!(camera.is_settled());
    let settled = camera.center();

    for offset in [
        Point::new(450.0, 0.0),
        Point::new(-450.0, 280.0),
        Point::new(200.0, -280.0),
    ] {
        let inside = Point::new(start.x + offset.x, start.y + offset.y);
        t = run(&mut camera, inside, t, 0.25, |_, _| {});
        assert!((camera.center().x - settled.x).abs() < 0.001);
        assert!((camera.center().y - settled.y).abs() < 0.001);
    }

    let rim_x = camera.viewport().max_x() - camera.viewport().width * FollowPreset::EDGE.margin;
    let mut last_center = camera.center();
    let mut steady_speeds = Vec::new();
    let pan_start = t;
    for i in 1..=45 {
        t += FRAME;
        let cursor = Point::new(rim_x + 300.0 * (t - pan_start), start.y);
        camera.update(cursor, t, FRAME);
        let speed = camera.center().distance_to(last_center) * camera.zoom() / FRAME;
        if i >= 20 {
            steady_speeds.push(speed);
        }
        last_center = camera.center();
    }
    let min_s = steady_speeds.iter().copied().fold(f64::INFINITY, f64::min);
    let max_s = steady_speeds.iter().copied().fold(0.0, f64::max);
    assert!(min_s > 450.0);
    assert!(max_s - min_s < 40.0);
}

#[test]
fn proportional_follow_has_zero_deadzone() {
    let mut cfg = CameraConfig::default();
    cfg.follow = FollowPreset::CONTINUOUS;
    let mut camera = ZoomCamera::new(DISPLAY, cfg);
    let start = Point::new(1152.0, 768.0);
    camera.zoom_in(1.75, start, 0.0);
    let mut t = run(&mut camera, start, 0.0, 0.6, |_, _| {});
    assert!(camera.is_settled());

    let mut last_center = camera.center();
    let pan_start = t;
    let mut steady = Vec::new();
    for i in 1..=90 {
        t += FRAME;
        let cursor = Point::new(start.x + 350.0 * (t - pan_start), start.y);
        camera.update(cursor, t, FRAME);
        let speed = camera.center().distance_to(last_center) * camera.zoom() / FRAME;
        if i == 1 {
            assert!(speed > 0.0);
        }
        if i >= 55 {
            steady.push(speed);
        }
        last_center = camera.center();
    }
    let min_s = steady.iter().copied().fold(f64::INFINITY, f64::min);
    let max_s = steady.iter().copied().fold(0.0, f64::max);
    assert!(min_s > 200.0);
    assert!(max_s - min_s < 25.0);
}

#[test]
fn calm_follow_and_wheel_zoom_parity() {
    let mut camera = calm_camera();
    let cursor = Point::new(1152.0, 768.0);
    camera.zoom_in(2.0, cursor, 0.0);
    let t = run(&mut camera, cursor, 0.0, 0.8, |_, _| {});
    let before = camera.screen_point(cursor);
    camera.adjust_zoom(1.5);
    let t = run(&mut camera, cursor, t, 1.0, |_, cam| {
        let p = cam.screen_point(cursor);
        assert!((p.x - before.x).abs() < 0.5);
        assert!((p.y - before.y).abs() < 0.5);
    });
    assert!((camera.zoom() - 3.0).abs() < 1e-6);

    camera.zoom_out(cursor, t);
    assert_eq!(camera.phase(), CameraPhase::ZoomingOut);
    run(&mut camera, cursor, t, 0.5, |_, cam| {
        assert_inside_display(cam);
    });
    assert_eq!(camera.phase(), CameraPhase::Idle);
    assert_eq!(camera.zoom(), 1.0);
    assert_eq!(camera.viewport(), Rect::from_origin_size(Point::ZERO, DISPLAY));
}

#[test]
fn smooth_damp_never_overshoots() {
    let mut v = Vector::ZERO;
    let mut p = Point::ZERO;
    let target = Point::new(100.0, -50.0);
    for _ in 0..600 {
        p = smooth_damp_step(p, target, &mut v, 0.3, 10_000.0, FRAME);
        assert!(p.x <= target.x + 1e-9);
        assert!(p.y >= target.y - 1e-9);
    }
    assert!((p.x - target.x).abs() < 0.01);
    assert!((p.y - target.y).abs() < 0.01);
}

#[test]
fn pixel_aligned_snaps_to_whole_output_pixels() {
    for zoom in [1.5, 2.0, 1.75] {
        let size = ViewportMath::size(DISPLAY, zoom);
        let mut x = 100.0;
        while x < 101.0 {
            let aligned = ViewportMath::pixel_aligned(
                Rect::from_origin_size(Point::new(x, 333.3), size),
                zoom,
                2.0,
                DISPLAY,
            );
            let px = aligned.min_x() * zoom * 2.0;
            assert!((px - px.round()).abs() < 1e-6);
            let py = aligned.min_y() * zoom * 2.0;
            assert!((py - py.round()).abs() < 1e-6);
            x += 0.037;
        }
    }
}

#[test]
fn text_lines_clustering_matches_macos() {
    let segments = [
        Rect::new(40.0, 100.0, 600.0, 30.0),
        Rect::new(680.0, 101.0, 320.0, 29.0),
        Rect::new(40.0, 140.0, 900.0, 30.0),
        Rect::new(1600.0, 100.0, 400.0, 30.0),
    ];
    let line = TextLines::line(Point::new(300.0, 115.0), &segments).unwrap();
    assert_eq!(line, Rect::new(40.0, 100.0, 960.0, 30.0));

    let after_end = TextLines::line(Point::new(1050.0, 112.0), &segments).unwrap();
    assert_eq!(after_end.min_y(), 100.0);
    assert_eq!(after_end.max_x(), 1000.0);

    let between = TextLines::line(Point::new(300.0, 132.0), &segments).unwrap();
    assert_eq!(between.min_y(), 100.0);

    assert!(TextLines::line(Point::new(300.0, 260.0), &segments).is_none());
    assert!(TextLines::line(Point::new(1300.0, 115.0), &segments).is_none());
}

#[test]
fn arrow_head_barbs_match_macos() {
    let points: Vec<Point> = (0..=20).map(|i| Point::new(i as f64 * 10.0, 50.0)).collect();
    let (a, b) = ArrowHead::barbs(&points, 20.0, ArrowHead::DEFAULT_ANGLE).unwrap();
    assert!(a.x < 200.0 && b.x < 200.0);
    assert!(((a.y - 50.0) + (b.y - 50.0)).abs() < 0.001);
    assert!((a.distance_to(Point::new(200.0, 50.0)) - 20.0).abs() < 0.001);
    assert!(ArrowHead::barbs(&[Point::new(5.0, 5.0)], 20.0, ArrowHead::DEFAULT_ANGLE).is_none());
}

#[test]
fn cursor_motion_and_click_effects_match_macos() {
    let mut motion = CursorMotion::new(Point::ZERO, 0.0);
    motion.idle_delay = Some(2.0);
    let mut t = 0.0;
    while t < 3.0 {
        t += FRAME;
        motion.update(Point::ZERO, false, t, FRAME);
        if t < 2.0 {
            assert_eq!(motion.opacity(), 1.0);
        }
    }
    assert_eq!(motion.opacity(), 0.0);

    for effect in [ClickEffect::Ripple, ClickEffect::Halo] {
        let mut last_r = 0.0;
        let mut last_o = 1.0;
        let mut age = 0.0;
        while let Some(look) = effect.appearance(age) {
            assert!(look.radius >= last_r);
            assert!(look.opacity <= last_o);
            last_r = look.radius;
            last_o = look.opacity;
            age += FRAME;
        }
        assert!((age - effect.duration()).abs() < 1.0 / 30.0);
    }
}

const DRAW_MODIFIERS: Modifiers = Modifiers {
    ctrl: true,
    alt: true,
    shift: false,
};

#[test]
fn zoom_trigger_keeps_its_release_and_event_position() {
    let mut fsm = InputFsm::default();
    let adjacent = Point::new(-1920.0, 200.0);
    let alt = Modifiers {
        alt: true,
        ..Modifiers::NONE
    };
    assert!(!fsm.on_trigger_down(TriggerButton::Middle, alt).swallow);
    assert!(
        fsm.on_trigger_down(TriggerButton::Middle, Modifiers::NONE)
            .swallow
    );
    let up = fsm.on_trigger_up(TriggerButton::Middle, adjacent);
    assert!(up.swallow);
    assert_eq!(up.actions, vec![InputAction::ToggleZoom(adjacent)]);
    let original_display = Rect::new(0.0, 0.0, 4608.0, 3072.0);
    let other_display = Rect::new(-1920.0, 0.0, 1920.0, 1080.0);
    assert!(!original_display.contains_pixel(adjacent));
    assert!(other_display.contains_pixel(adjacent));
    assert!(!other_display.contains_pixel(Point::new(0.0, 200.0)));

    assert!(
        fsm.on_trigger_down(TriggerButton::Middle, Modifiers::NONE)
            .swallow
    );
    assert!(fsm.configure_trigger(true, TriggerButton::Back).is_none());
    assert!(!fsm.on_wheel(1.0, adjacent).swallow);
    let old_release = fsm.on_trigger_up(TriggerButton::Middle, adjacent);
    assert!(old_release.swallow && old_release.actions.is_empty());
    assert!(
        fsm.on_trigger_down(TriggerButton::Back, Modifiers::NONE)
            .swallow
    );
    assert_eq!(
        fsm.on_wheel(1.0, adjacent).actions,
        vec![InputAction::AdjustZoom {
            steps: 1.0,
            at: adjacent
        }]
    );
    assert!(fsm
        .on_trigger_up(TriggerButton::Back, adjacent)
        .actions
        .is_empty());
}

#[test]
fn native_clicks_and_drags_pass_through_while_annotations_exist() {
    let mut fsm = InputFsm::default();
    fsm.set_drawing_armed(true);
    fsm.has_strokes = true;
    fsm.drawing_bounds = Some(Rect::new(0.0, 0.0, 4608.0, 2976.0));
    let position = Point::new(3783.0, 2742.0);
    let ctrl = Modifiers {
        ctrl: true,
        ..Modifiers::NONE
    };
    for mods in [Modifiers::NONE, ctrl] {
        let down = fsm.on_left_down(position, mods);
        assert!(!down.swallow);
        assert_eq!(down.actions, vec![InputAction::Click(position)]);
        assert!(!fsm.on_mouse_move(Point::new(3800.0, 2752.0), false).swallow);
        assert!(!fsm.on_left_up().swallow);
    }
    // Right-clicking an Explorer tray flyout inside rcWork still passes.
    assert!(!fsm.observe_click(position).swallow);
    assert!(
        !fsm.on_left_down(Point::new(3700.0, 2976.0), DRAW_MODIFIERS)
            .swallow
    );
}

#[test]
fn held_zoom_trigger_draws_without_keyboard_or_toggling_zoom_on_release() {
    let start = Point::new(100.0, 100.0);
    let end = Point::new(110.0, 120.0);
    for button in [
        TriggerButton::Middle,
        TriggerButton::Back,
        TriggerButton::Forward,
    ] {
        for release_trigger_first in [false, true] {
            let mut fsm = InputFsm::default();
            fsm.configure_trigger(true, button);
            fsm.set_drawing_armed(true);
            assert!(fsm.on_trigger_down(button, Modifiers::NONE).swallow);
            assert!(fsm.on_left_down(start, Modifiers::NONE).swallow);
            let movement = fsm.on_mouse_move(end, false);
            assert!(!movement.swallow);
            assert_eq!(
                movement.actions,
                vec![
                    InputAction::StrokeBegan(start),
                    InputAction::StrokeMoved {
                        point: end,
                        straight: false
                    },
                ]
            );
            let wheel = fsm.on_wheel(1.0, end);
            assert!(wheel.swallow && wheel.actions.is_empty());
            if release_trigger_first {
                let release = fsm.on_trigger_up(button, end);
                assert!(release.swallow && release.actions.is_empty());
            }
            let release = fsm.on_left_up();
            assert!(release.swallow);
            assert_eq!(release.actions, vec![InputAction::StrokeEnded]);
            if !release_trigger_first {
                let release = fsm.on_trigger_up(button, end);
                assert!(release.swallow && release.actions.is_empty());
            }
            assert!(!fsm.on_left_down(start, Modifiers::NONE).swallow);
            assert!(!fsm.on_left_up().swallow);
        }
    }
}

#[test]
fn cancelled_drawing_keeps_its_release_and_never_freezes_motion() {
    let mut fsm = InputFsm::default();
    fsm.set_drawing_armed(true);
    fsm.drag_threshold_px = 8.0;
    let start = Point::new(100.0, 100.0);
    let end = Point::new(112.0, 100.0);

    assert!(fsm.on_left_down(start, DRAW_MODIFIERS).swallow);
    assert!(fsm
        .on_mouse_move(Point::new(104.0, 100.0), false)
        .actions
        .is_empty());
    assert!(fsm.set_drawing_armed(false).is_none());
    assert!(!fsm.on_mouse_move(end, false).swallow);
    let release = fsm.on_left_up();
    assert!(release.swallow && release.actions.is_empty());
    assert!(!fsm.on_left_down(start, Modifiers::NONE).swallow);
    assert!(!fsm.on_left_up().swallow);

    fsm.set_drawing_armed(true);
    assert!(fsm.on_left_down(start, DRAW_MODIFIERS).swallow);
    let stroke = fsm.on_mouse_move(end, true);
    assert!(!stroke.swallow);
    assert_eq!(
        stroke.actions,
        vec![
            InputAction::StrokeBegan(start),
            InputAction::StrokeMoved {
                point: end,
                straight: true
            },
        ]
    );
    assert_eq!(fsm.set_suspended(true), Some(InputAction::StrokeEnded));
    assert!(fsm.on_left_up().swallow);
    fsm.set_suspended(false);
    let hover = fsm.on_mouse_move(end, false);
    assert!(!hover.swallow && hover.actions.is_empty());
}

#[test]
fn suspended_trigger_and_keys_finish_without_claiming_new_input() {
    let mut fsm = InputFsm::default();
    fsm.set_keys_armed(true);
    fsm.has_strokes = true;
    let position = Point::new(50.0, 50.0);

    assert!(
        fsm.on_trigger_down(TriggerButton::Middle, Modifiers::NONE)
            .swallow
    );
    assert_eq!(
        fsm.on_key_down(0x1B, Modifiers::NONE).actions,
        vec![InputAction::ClearStrokes]
    );
    fsm.set_suspended(true);
    assert!(!fsm.on_wheel(1.0, position).swallow);
    let release = fsm.on_trigger_up(TriggerButton::Middle, position);
    assert!(release.swallow && release.actions.is_empty());
    assert!(!fsm.on_left_down(position, DRAW_MODIFIERS).swallow);
    fsm.set_suspended(false);
    assert!(!fsm.on_wheel(1.0, position).swallow);
    fsm.set_keys_armed(false);
    let repeat = fsm.on_key_down(0x1B, Modifiers::NONE);
    assert!(repeat.swallow && repeat.actions.is_empty());
    assert!(fsm.on_key_up(0x1B).swallow);
    assert!(!fsm.on_key_down(0x1B, Modifiers::NONE).swallow);
    fsm.set_keys_armed(true);
    fsm.has_strokes = false;
    assert_eq!(
        fsm.on_key_down(0x1B, Modifiers::NONE).actions,
        vec![InputAction::CancelZoom]
    );
}

#[test]
fn highlight_and_undo_shortcuts_own_repeats_and_releases() {
    let mut fsm = InputFsm::default();
    fsm.set_keys_armed(true);
    fsm.shortcuts
        .insert(KeyCombo::new(0x31, KeyCombo::MOD_ALT), HighlightKind::Box);
    fsm.undo_shortcut = Some(KeyCombo::new(0x5A, KeyCombo::MOD_CTRL));
    let alt = Modifiers {
        alt: true,
        ..Modifiers::NONE
    };
    let ctrl = Modifiers {
        ctrl: true,
        ..Modifiers::NONE
    };
    assert_eq!(
        fsm.on_key_down(0x31, alt).actions,
        vec![InputAction::Highlight(HighlightKind::Box)]
    );
    assert!(fsm.on_key_down(0x31, alt).actions.is_empty());
    assert!(fsm.on_key_up(0x31).swallow);
    assert!(!fsm.on_key_down(0x5A, ctrl).swallow);
    fsm.has_strokes = true;
    assert_eq!(
        fsm.on_key_down(0x5A, ctrl).actions,
        vec![InputAction::UndoStroke]
    );
    fsm.has_strokes = false;
    let repeat = fsm.on_key_down(0x5A, ctrl);
    assert!(repeat.swallow && repeat.actions.is_empty());
    assert!(fsm.on_key_up(0x5A).swallow);
}

#[test]
fn fast_pointer_remains_in_the_submitted_crop_at_fractional_zooms() {
    let display = Size::new(4608.0, 3072.0);
    let center = Point::new(2304.0, 1536.0);
    for level in [1.25, 1.3, 2.0, 2.333, 4.0] {
        let mut camera = ZoomCamera::new(display, CameraConfig::default());
        camera.zoom_in(level, center, 0.0);
        camera.update(center, 0.6, FRAME);
        camera.set_follow_paused(true);
        for pointer in [
            Point::new(4400.0, 2900.0),
            Point::new(4607.0, 3071.0),
            Point::ZERO,
            Point::new(4607.0, 0.0),
            Point::new(0.0, 3071.0),
            center,
        ] {
            camera.update(pointer, 0.7, FRAME);
            camera.keep_cursor_visible(pointer);
            let viewport =
                ViewportMath::rect(camera.center(), camera.zoom() as f32 as f64, display);
            let origin = ViewportMath::magnifier_origin(viewport, display);
            let submitted = Rect::new(origin.x, origin.y, viewport.width, viewport.height);
            assert!(
                submitted.contains_pixel(pointer),
                "{level}x: {pointer:?} outside {submitted:?}"
            );
        }
    }
}

#[test]
fn settings_shortcut_conflict_resolution() {
    use livezoom_core::core::settings::{AppSettings, Shortcut};

    let mut s = AppSettings::default();
    let alt1 = Shortcut {
        vk: 0x31,
        modifiers: KeyCombo::MOD_ALT,
        display: "Alt+1".to_string(),
    };
    assert!(s.set_shortcut(HighlightKind::Box, Some(alt1.clone())).is_none());
    let displaced = s.set_shortcut(HighlightKind::Underline, Some(alt1.clone()));
    assert_eq!(displaced.as_deref(), Some("框住这一行"));
    assert!(!s.shortcuts.contains_key(&HighlightKind::Box));
    assert_eq!(s.shortcuts.get(&HighlightKind::Underline), Some(&alt1));

    // Rebinding undo to Alt+1 displaces Underline cleanly.
    let displaced_undo = s.set_undo_shortcut(Some(alt1.clone()));
    assert_eq!(displaced_undo.as_deref(), Some("给这一行划线"));
    assert!(!s.shortcuts.contains_key(&HighlightKind::Underline));
    assert_eq!(s.undo_shortcut, Some(alt1));
}

use crate::core::geometry::{Point, Vector};

/// Critically damped spring toward `target` (Game Programming Gems 4, 1.10).
/// Never overshoots, and moves at most `max_speed` units per second.
pub fn smooth_damp_step(
    current: Point,
    target: Point,
    velocity: &mut Vector,
    smooth_time: f64,
    max_speed: f64,
    dt: f64,
) -> Point {
    if dt <= 0.0 {
        return current;
    }
    let smooth_time = smooth_time.max(0.0001);
    let omega = 2.0 / smooth_time;
    let x = omega * dt;
    let decay = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x);

    let mut change = Vector::new(current.x - target.x, current.y - target.y);
    let max_change = max_speed * smooth_time;
    let change_len = change.length();
    if change_len > max_change && change_len > 0.0 {
        let scale = max_change / change_len;
        change.dx *= scale;
        change.dy *= scale;
    }
    let clamped_target = Point::new(current.x - change.dx, current.y - change.dy);

    let temp = Vector::new(
        (velocity.dx + omega * change.dx) * dt,
        (velocity.dy + omega * change.dy) * dt,
    );
    let mut new_velocity = Vector::new(
        (velocity.dx - omega * temp.dx) * decay,
        (velocity.dy - omega * temp.dy) * decay,
    );
    let mut output = Point::new(
        clamped_target.x + (change.dx + temp.dx) * decay,
        clamped_target.y + (change.dy + temp.dy) * decay,
    );

    // Stop exactly on the target instead of passing it.
    let to_target = Vector::new(target.x - current.x, target.y - current.y);
    let past = Vector::new(output.x - target.x, output.y - target.y);
    if to_target.dx * past.dx + to_target.dy * past.dy > 0.0 {
        output = target;
        new_velocity = Vector::ZERO;
    }

    // Hard speed cap so a sudden far target never produces a fast pan.
    let step_vec = Vector::new(output.x - current.x, output.y - current.y);
    let step_len = step_vec.length();
    let max_step = max_speed * dt;
    if step_len > max_step && step_len > 0.0 {
        let scale = max_step / step_len;
        output = Point::new(
            current.x + step_vec.dx * scale,
            current.y + step_vec.dy * scale,
        );
        new_velocity = Vector::new(step_vec.dx * scale / dt, step_vec.dy * scale / dt);
    }

    *velocity = new_velocity;
    output
}

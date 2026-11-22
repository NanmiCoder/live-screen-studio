#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

#[cfg(windows)]
mod platform;

#[cfg(windows)]
use livezoom_core::core;

#[cfg(windows)]
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 3 && args[1] == platform::watchdog::WATCHDOG_ARG {
        if let Ok(pid) = args[2].parse::<u32>() {
            platform::watchdog::run_watchdog_mode(pid);
        }
        return;
    }

    if let Err(err) = platform::app::run() {
        eprintln!("LiveZoom error: {err}");
        platform::watchdog::restore_system_cursors();
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("LiveZoom Windows binary must be executed on Windows (run `cargo test` for cross-platform core tests).");
}

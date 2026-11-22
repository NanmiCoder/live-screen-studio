use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::process::CommandExt;
use std::process::Command;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::System::Threading::{
    CreateEventW, OpenEventW, OpenProcess, SetEvent, WaitForMultipleObjects, WaitForSingleObject,
    CREATE_NO_WINDOW, EVENT_MODIFY_STATE, PROCESS_SYNCHRONIZE, SYNCHRONIZATION_ACCESS_RIGHTS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    SystemParametersInfoW, SPIF_SENDCHANGE, SPI_SETCURSORS,
};

pub const WATCHDOG_ARG: &str = "--cursor-watchdog";

fn shutdown_event_name(pid: u32) -> Vec<u16> {
    let s = format!("Local\\LiveZoomWatchdogCleanExit_{pid}");
    OsStr::new(&s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

/// Guard held by the main LiveZoom process. Spawns a tiny self-invoked watchdog process
/// that waits on our process handle and restores system cursors immediately if we ever crash
/// or are forcefully terminated (`taskkill /F`).
pub struct CursorWatchdogGuard {
    clean_event: HANDLE,
}

impl CursorWatchdogGuard {
    pub fn start() -> Option<Self> {
        let pid = std::process::id();
        let name = shutdown_event_name(pid);
        let clean_event = unsafe { CreateEventW(None, true, false, PCWSTR(name.as_ptr())).ok()? };

        if let Ok(exe) = std::env::current_exe() {
            let _ = Command::new(exe)
                .arg(WATCHDOG_ARG)
                .arg(pid.to_string())
                .creation_flags(CREATE_NO_WINDOW.0)
                .spawn();
        }

        Some(Self { clean_event })
    }

    pub fn signal_clean_exit(&self) {
        unsafe {
            let _ = SetEvent(self.clean_event);
        }
    }
}

impl Drop for CursorWatchdogGuard {
    fn drop(&mut self) {
        self.signal_clean_exit();
        unsafe {
            let _ = CloseHandle(self.clean_event);
        }
    }
}

/// Entrypoint for `LiveZoom.exe --cursor-watchdog <parent_pid>`.
/// Blocks with 0% CPU until the parent exits; if the parent did not signal a clean exit
/// (including if it already died before `OpenProcess`), restores system cursors via `SPI_SETCURSORS`.
pub fn run_watchdog_mode(parent_pid: u32) {
    unsafe {
        let name = shutdown_event_name(parent_pid);
        let clean = OpenEventW(
            SYNCHRONIZATION_ACCESS_RIGHTS(EVENT_MODIFY_STATE.0 | 0x0010_0000),
            false,
            PCWSTR(name.as_ptr()),
        )
        .ok();

        let Ok(parent) = OpenProcess(PROCESS_SYNCHRONIZE, false, parent_pid) else {
            // Parent exited before we opened its handle: restore unless clean-exit event is already signaled.
            let was_clean = clean
                .map(|ev| WaitForSingleObject(ev, 0) == WAIT_OBJECT_0)
                .unwrap_or(false);
            if let Some(ev) = clean {
                let _ = CloseHandle(ev);
            }
            if !was_clean {
                restore_system_cursors();
            }
            return;
        };

        let should_restore = if let Some(ev) = clean {
            let handles = [ev, parent];
            let wait = WaitForMultipleObjects(&handles, false, u32::MAX);
            let _ = CloseHandle(ev);
            wait != WAIT_OBJECT_0
        } else {
            let handles = [parent];
            let _ = WaitForMultipleObjects(&handles, false, u32::MAX);
            true
        };

        let _ = CloseHandle(parent);

        if should_restore {
            restore_system_cursors();
        }
    }
}

pub fn restore_system_cursors() {
    unsafe {
        let _ = SystemParametersInfoW(SPI_SETCURSORS, 0, None, SPIF_SENDCHANGE);
    }
}

use std::ffi::OsStr;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY,
    HKEY_CURRENT_USER, KEY_READ, KEY_WRITE, REG_SZ,
};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_SHOWTIP, NIF_TIP, NIM_ADD, NIM_DELETE,
    NIM_MODIFY, NIM_SETVERSION, NOTIFYICONDATAW, NOTIFYICON_VERSION_4,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, DestroyMenu, GetCursorPos, LoadIconW, PostMessageW,
    SetForegroundWindow, TrackPopupMenu, IDI_APPLICATION, MF_CHECKED, MF_SEPARATOR, MF_STRING,
    MF_UNCHECKED, TPM_BOTTOMALIGN, TPM_LEFTALIGN, TPM_RETURNCMD, TPM_RIGHTBUTTON, WM_APP, WM_NULL,
};

use crate::core::settings::TriggerButton;

pub const WM_TRAY_ICON: u32 = WM_APP + 1;
pub const WM_ACTIVATE_EXISTING: u32 = WM_APP + 2;
pub const MENU_OPEN_CONSOLE: u32 = 1001;
pub const MENU_TOGGLE_ENABLED: u32 = 1002;
pub const MENU_TOGGLE_AUTOSTART: u32 = 1003;
pub const MENU_QUIT: u32 = 1004;

pub struct TrayIcon {
    hwnd: HWND,
    id: u32,
}

impl TrayIcon {
    pub fn new(hwnd: HWND) -> Result<Self, String> {
        let mut nid = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP,
            uCallbackMessage: WM_TRAY_ICON,
            ..Default::default()
        };

        unsafe {
            let hinst = GetModuleHandleW(None)
                .map(HINSTANCE::from)
                .unwrap_or_default();
            nid.hIcon = LoadIconW(hinst, PCWSTR(1 as *const u16))
                .or_else(|_| LoadIconW(None, IDI_APPLICATION))
                .unwrap_or_default();
        }
        set_tip(&mut nid, "LiveZoom — 实时屏幕放大与标注");

        unsafe {
            if !Shell_NotifyIconW(NIM_ADD, &nid).as_bool() {
                return Err("Shell_NotifyIconW(NIM_ADD) failed".to_string());
            }
            nid.Anonymous.uVersion = NOTIFYICON_VERSION_4;
            let _ = Shell_NotifyIconW(NIM_SETVERSION, &nid);
        }
        Ok(Self { hwnd, id: 1 })
    }

    pub fn update_tooltip(&self, enabled: bool, trigger: TriggerButton) {
        let mut nid = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.hwnd,
            uID: self.id,
            uFlags: NIF_TIP | NIF_SHOWTIP,
            ..Default::default()
        };
        let trigger_name = match trigger {
            TriggerButton::Middle => "中键",
            TriggerButton::Back => "后退侧键",
            TriggerButton::Forward => "前进侧键",
        };
        let tip = if enabled {
            format!("LiveZoom — 就绪（单击{trigger_name}放大）")
        } else {
            "LiveZoom — 已暂停".to_string()
        };
        set_tip(&mut nid, &tip);
        unsafe {
            let _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
        }
    }

    pub fn show_menu(&self, enabled: bool, autostart: bool) -> Option<u32> {
        unsafe {
            let menu = CreatePopupMenu().ok()?;
            let _ = AppendMenuW(menu, MF_STRING, MENU_OPEN_CONSOLE as usize, w!("打开控制台"));
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
            let _ = AppendMenuW(
                menu,
                MF_STRING | if enabled { MF_CHECKED } else { MF_UNCHECKED },
                MENU_TOGGLE_ENABLED as usize,
                w!("启用实时放大"),
            );
            let _ = AppendMenuW(
                menu,
                MF_STRING | if autostart { MF_CHECKED } else { MF_UNCHECKED },
                MENU_TOGGLE_AUTOSTART as usize,
                w!("开机自启"),
            );
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
            let _ = AppendMenuW(menu, MF_STRING, MENU_QUIT as usize, w!("退出 LiveZoom"));

            let mut pt = POINT::default();
            let _ = GetCursorPos(&mut pt);
            let _ = SetForegroundWindow(self.hwnd);
            let cmd = TrackPopupMenu(
                menu,
                TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RETURNCMD | TPM_RIGHTBUTTON,
                pt.x,
                pt.y,
                0,
                self.hwnd,
                None,
            );
            // Required by Microsoft Shell_NotifyIcon docs so clicking outside dismisses future menus properly.
            let _ = PostMessageW(self.hwnd, WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(menu);
            if cmd.as_bool() {
                Some(cmd.0 as u32)
            } else {
                None
            }
        }
    }
}

impl Drop for TrayIcon {
    fn drop(&mut self) {
        let nid = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.hwnd,
            uID: self.id,
            ..Default::default()
        };
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
        }
    }
}

fn set_tip(nid: &mut NOTIFYICONDATAW, text: &str) {
    let wide: Vec<u16> = OsStr::new(text).encode_wide().collect();
    let len = wide.len().min(nid.szTip.len() - 1);
    nid.szTip[..len].copy_from_slice(&wide[..len]);
    nid.szTip[len] = 0;
}

const RUN_KEY: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const RUN_VALUE: PCWSTR = w!("LiveZoom");

pub fn is_launch_at_login_enabled() -> bool {
    unsafe {
        let mut hkey = HKEY::default();
        if RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_READ, &mut hkey).is_err() {
            return false;
        }
        let exists = RegQueryValueExW(hkey, RUN_VALUE, None, None, None, None).is_ok();
        let _ = RegCloseKey(hkey);
        exists
    }
}

pub fn set_launch_at_login(enable: bool) -> bool {
    unsafe {
        let mut hkey = HKEY::default();
        if RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_WRITE, &mut hkey).is_err() {
            return false;
        }
        let ok = if enable {
            if let Ok(exe) = std::env::current_exe() {
                let cmd = format!("\"{}\"", exe.display());
                let wide: Vec<u16> = OsStr::new(&cmd)
                    .encode_wide()
                    .chain(std::iter::once(0))
                    .collect();
                let bytes = std::slice::from_raw_parts(
                    wide.as_ptr() as *const u8,
                    wide.len() * size_of::<u16>(),
                );
                RegSetValueExW(hkey, RUN_VALUE, 0, REG_SZ, Some(bytes)).is_ok()
            } else {
                false
            }
        } else {
            let _ = RegDeleteValueW(hkey, RUN_VALUE);
            true
        };
        let _ = RegCloseKey(hkey);
        ok
    }
}

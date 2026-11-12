//! Cleanup for the elevated NSIS uninstaller, without the application runtime.
//! Never derive the user's profile from the elevated process environment:
//! over-the-shoulder UAC can run us as a different administrator.

use std::{ffi::OsString, os::windows::ffi::OsStringExt, path::PathBuf, ptr};

use windows_sys::{
    core::GUID,
    Win32::{
        Foundation::{
            CloseHandle, GetLastError, ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_SUCCESS,
            HANDLE,
        },
        Security::{
            AdjustTokenPrivileges, ImpersonateLoggedOnUser, LookupPrivilegeValueW, RevertToSelf,
            SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES, TOKEN_DUPLICATE, TOKEN_IMPERSONATE,
            TOKEN_PRIVILEGES, TOKEN_QUERY,
        },
        System::{
            Com::CoTaskMemFree,
            Registry::{
                RegCloseKey, RegDeleteKeyExW, RegDeleteValueW, RegOpenCurrentUser, RegOpenKeyExW,
                RegQueryInfoKeyW, HKEY, KEY_READ, KEY_WRITE,
            },
            Threading::{
                GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
        UI::{
            Shell::{
                FOLDERID_LocalAppData, FOLDERID_RoamingAppData, SHGetKnownFolderPath,
                KF_FLAG_DONT_VERIFY,
            },
            WindowsAndMessaging::{GetShellWindow, GetWindowThreadProcessId},
        },
    },
};

use crate::{cleanup, options::Options};

struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

struct ShellUser;

impl Drop for ShellUser {
    fn drop(&mut self) {
        // Do not continue with an unexpected security context if reverting fails.
        if unsafe { RevertToSelf() } == 0 {
            std::process::abort();
        }
    }
}

struct DebugPrivilege {
    token: Handle,
    previous: TOKEN_PRIVILEGES,
}

impl DebugPrivilege {
    fn enable_if_available() -> Option<Self> {
        unsafe {
            let mut token = ptr::null_mut();
            if OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
                &mut token,
            ) == 0
            {
                return None;
            }
            let token = Handle(token);
            let mut requested: TOKEN_PRIVILEGES = std::mem::zeroed();
            let name: Vec<u16> = "SeDebugPrivilege\0".encode_utf16().collect();
            if LookupPrivilegeValueW(
                ptr::null(),
                name.as_ptr(),
                &mut requested.Privileges[0].Luid,
            ) == 0
            {
                return None;
            }
            requested.PrivilegeCount = 1;
            requested.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
            let mut previous = std::mem::zeroed();
            let mut length = 0;
            if AdjustTokenPrivileges(
                token.0,
                0,
                &requested,
                std::mem::size_of::<TOKEN_PRIVILEGES>() as u32,
                &mut previous,
                &mut length,
            ) == 0
                || GetLastError() != ERROR_SUCCESS
            {
                return None;
            }
            Some(Self { token, previous })
        }
    }
}

impl Drop for DebugPrivilege {
    fn drop(&mut self) {
        if unsafe {
            AdjustTokenPrivileges(
                self.token.0,
                0,
                &self.previous,
                0,
                ptr::null_mut(),
                ptr::null_mut(),
            )
        } == 0
        {
            std::process::abort();
        }
    }
}

fn shell_token() -> Result<Handle, i32> {
    unsafe {
        // GetShellWindow identifies the shell on this desktop, including RDP.
        // Do not use the console session or enumerate other users' profiles.
        let shell = GetShellWindow();
        if shell.is_null() {
            return Err(43);
        }

        let mut process_id = 0;
        if GetWindowThreadProcessId(shell, &mut process_id) == 0 || process_id == 0 {
            return Err(43);
        }

        // A different UAC administrator needs this privilege to query the
        // desktop user's process token. Restore it before touching user files.
        // Same-user, unelevated execution can work without the privilege.
        let _debug = DebugPrivilege::enable_if_available();
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id);
        if process.is_null() {
            return Err(43);
        }
        let process = Handle(process);
        let mut token = ptr::null_mut();
        if OpenProcessToken(
            process.0,
            TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_IMPERSONATE,
            &mut token,
        ) == 0
        {
            return Err(43);
        }
        Ok(Handle(token))
    }
}

fn known_folder(token: &Handle, folder: &GUID) -> Result<PathBuf, i32> {
    let mut path = ptr::null_mut();
    let result =
        unsafe { SHGetKnownFolderPath(folder, KF_FLAG_DONT_VERIFY as u32, token.0, &mut path) };
    let directory = if result >= 0 && !path.is_null() {
        // SHGetKnownFolderPath returns an allocated, NUL-terminated UTF-16 path.
        let mut length = 0;
        unsafe {
            while *path.add(length) != 0 {
                length += 1;
            }
            Some(PathBuf::from(OsString::from_wide(
                std::slice::from_raw_parts(path, length),
            )))
        }
    } else {
        None
    };
    unsafe { CoTaskMemFree(path.cast()) };
    directory.filter(|path| path.is_absolute()).ok_or(43)
}

pub fn clear_user_data(options: &Options) -> Result<(), i32> {
    let token = shell_token()?;
    if unsafe { ImpersonateLoggedOnUser(token.0) } == 0 {
        return Err(43);
    }
    let _user = ShellUser;

    // Both path resolution and file operations run as the shell user. Merely
    // finding their path then deleting as admin would follow user-controlled
    // junctions with elevated privileges. Keep this entire scope synchronous.
    let local = known_folder(&token, &FOLDERID_LocalAppData)?;
    let roaming = if options.delete_app_data {
        Some(known_folder(&token, &FOLDERID_RoamingAppData)?)
    } else {
        None
    };
    cleanup::clear_files(&local, roaming.as_deref(), &options.bundle_id)?;
    clear_user_registry(options)
}

struct RegistryKey(HKEY);

impl Drop for RegistryKey {
    fn drop(&mut self) {
        unsafe { RegCloseKey(self.0) };
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

fn open_key(root: HKEY, name: &str) -> Result<Option<RegistryKey>, i32> {
    let mut key = ptr::null_mut();
    match unsafe { RegOpenKeyExW(root, wide(name).as_ptr(), 0, KEY_READ | KEY_WRITE, &mut key) } {
        ERROR_SUCCESS => Ok(Some(RegistryKey(key))),
        ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => Ok(None),
        _ => Err(40),
    }
}

fn delete_value(key: &RegistryKey, name: &str) -> Result<(), i32> {
    match unsafe { RegDeleteValueW(key.0, wide(name).as_ptr()) } {
        ERROR_SUCCESS | ERROR_FILE_NOT_FOUND => Ok(()),
        _ => Err(40),
    }
}

fn delete_key_if_empty(root: &RegistryKey, name: &str) -> Result<(), i32> {
    let Some(key) = open_key(root.0, name)? else {
        return Ok(());
    };
    let mut subkeys = 0;
    let mut values = 0;
    let result = unsafe {
        RegQueryInfoKeyW(
            key.0,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null(),
            &mut subkeys,
            ptr::null_mut(),
            ptr::null_mut(),
            &mut values,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
        )
    };
    if result != ERROR_SUCCESS {
        return Err(40);
    }
    drop(key);
    if subkeys == 0 && values == 0 {
        // RegDeleteKeyExW never recursively removes subkeys.
        match unsafe { RegDeleteKeyExW(root.0, wide(name).as_ptr(), 0, 0) } {
            ERROR_SUCCESS | ERROR_FILE_NOT_FOUND => (),
            _ => return Err(40),
        }
    }
    Ok(())
}

fn clear_user_registry(options: &Options) -> Result<(), i32> {
    // HKEY_CURRENT_USER can be cached for the elevated account. This API opens
    // the current impersonated user's hive explicitly instead.
    let mut root = ptr::null_mut();
    if unsafe { RegOpenCurrentUser(KEY_READ | KEY_WRITE, &mut root) } != ERROR_SUCCESS {
        return Err(40);
    }
    let root = RegistryKey(root);
    if let Some(run) = open_key(root.0, r"Software\Microsoft\Windows\CurrentVersion\Run")? {
        delete_value(&run, &options.product_name)?;
    }
    if options.delete_app_data {
        let manufacturer = format!(r"Software\{}", options.manufacturer);
        let product = format!(r"{}\{}", manufacturer, options.product_name);
        if let Some(key) = open_key(root.0, &product)? {
            delete_value(&key, "Installer Language")?;
        }
        delete_key_if_empty(&root, &product)?;
        delete_key_if_empty(&root, &manufacturer)?;
    }
    Ok(())
}

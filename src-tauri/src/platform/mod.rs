#[derive(Debug, serde::Serialize)]
pub struct RustDeskStatus {
    pub installed: bool,
    pub version: Option<String>,
    pub service_running: bool,
    pub configured: bool,
    pub id: Option<String>,
}

#[derive(Debug, serde::Serialize)]
pub struct RustDeskPermissionsStatus {
    pub accessibility: bool,
    pub screen_recording: bool,
    pub input_monitoring: bool,
}

#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "macos")]
mod macos;

mod headless;

#[cfg(any(target_os = "windows", test))]
mod windows_install_config;

#[cfg(target_os = "windows")]
pub(crate) fn disable_legacy_install_config(directory: &std::path::Path) -> Result<(), i32> {
    windows_install_config::disable_legacy_fallback(directory)
}

#[cfg(any(target_os = "windows", test))]
mod windows_rustdesk;

#[cfg(target_os = "windows")]
pub use windows::*;

#[cfg(target_os = "macos")]
pub use macos::*;

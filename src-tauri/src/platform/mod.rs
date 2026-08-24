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

#[cfg(target_os = "windows")]
pub use windows::*;

#[cfg(target_os = "macos")]
pub use macos::*;

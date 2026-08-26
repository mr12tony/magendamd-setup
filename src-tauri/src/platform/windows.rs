use super::RustDeskPermissionsStatus;
use super::RustDeskStatus;

use serde::{Deserialize, Serialize};

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

const RUSTDESK_EXE: &str =
    r"C:\Program Files\RustDesk\rustdesk.exe";

const ID_SERVER: &str = "rustdesk.magendamd.com";
const RELAY_SERVER: &str = "rustdesk.magendamd.com";
const RENDEZVOUS_PORT: &str = "21116";
const RUSTDESK_KEY: &str =
    "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc=";

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum InstallMode {
    Dev,
    Prod,
    Local,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct InstallConfig {
    pub install_token: String,
    pub mode: InstallMode,
}

// ============================================================
// INSTALL TOKEN
// ============================================================

fn install_config_path() -> Result<PathBuf, String> {
    let program_data =
        std::env::var("PROGRAMDATA")
            .map_err(|_| {
                "PROGRAMDATA environment variable not found"
                    .to_string()
            })?;

    Ok(
        PathBuf::from(program_data)
            .join("Magendamd")
            .join("install.json"),
    )
}

pub fn get_install_config() -> Result<Option<InstallConfig>, String> {
    let path = install_config_path()?;

    if !path.exists() {
        return Ok(None);
    }

    let content = fs::read_to_string(&path)
        .map_err(|e| {
            format!(
                "Cannot read install config {}: {e}",
                path.display()
            )
        })?;

    let config: InstallConfig =
        serde_json::from_str(&content)
            .map_err(|e| {
                format!(
                    "Invalid install config: {e}"
                )
            })?;

    if config.install_token.trim().is_empty() {
        return Ok(None);
    }

    Ok(Some(config))
}

pub fn save_install_config(
    token: &str,
    mode: InstallMode,
) -> Result<(), String> {
    let token = token.trim();

    if token.is_empty() {
        return Err(
            "Install token is empty.".to_string()
        );
    }

    if !token
        .chars()
        .all(|c| {
            c.is_ascii_alphanumeric()
                || c == '-'
                || c == '_'
        })
    {
        return Err(
            "Install token contains invalid characters."
                .to_string()
        );
    }

    let path = install_config_path()?;

    let parent = path
        .parent()
        .ok_or_else(|| {
            "Invalid install config path.".to_string()
        })?;

    fs::create_dir_all(parent)
        .map_err(|e| {
            format!(
                "Failed to create {}: {e}",
                parent.display()
            )
        })?;

    let config = InstallConfig {
        install_token: token.to_string(),
        mode,
    };

    let json =
        serde_json::to_string_pretty(&config)
            .map_err(|e| {
                format!(
                    "Failed to serialize install config: {e}"
                )
            })?;

    fs::write(&path, json)
        .map_err(|e| {
            format!(
                "Failed to write {}: {e}",
                path.display()
            )
        })?;

    Ok(())
}

pub fn get_rustdesk_id() -> Result<Option<String>, String> {
    if !Path::new(RUSTDESK_EXE).exists() {
        return Ok(None);
    }

    let output = Command::new(RUSTDESK_EXE)
        .arg("--get-id")
        .output()
        .map_err(|e| format!("Failed to run RustDesk: {e}"))?;

    if !output.status.success() {
        return Ok(None);
    }

    let id = String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_string();

    if id.is_empty() {
        Ok(None)
    } else {
        Ok(Some(id))
    }
}

pub fn configure_rustdesk(_app: &tauri::AppHandle) -> Result<(), String> {
    Ok(())
}

pub fn get_rustdesk_permissions_status() -> Result<RustDeskPermissionsStatus, String> {
    Ok(RustDeskPermissionsStatus {
        accessibility: true,
        screen_recording: true,
        input_monitoring: true,
    })
}

pub fn open_accessibility_settings() -> Result<(), String> {
    Ok(())
}

pub fn open_screen_recording_settings() -> Result<(), String> {
    Ok(())
}

pub fn open_input_monitoring_settings() -> Result<(), String> {
    Ok(())
}

fn get_rustdesk_version() -> Option<String> {
    let script = format!(
        "(Get-Item '{}').VersionInfo.ProductVersion",
        RUSTDESK_EXE.replace('\'', "''")
    );

    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();

    // 1.4.9+67 -> 1.4.9
    let version = raw.split('+').next().unwrap_or("").trim().to_string();

    if version.is_empty() {
        None
    } else {
        Some(version)
    }
}

fn is_rustdesk_service_running() -> bool {
    let output = match Command::new("sc.exe").args(["query", "Rustdesk"]).output() {
        Ok(output) => output,
        Err(_) => return false,
    };

    if !output.status.success() {
        return false;
    }

    String::from_utf8_lossy(&output.stdout).contains("RUNNING")
}

fn is_rustdesk_configured() -> bool {
    let windows = std::env::var("WINDIR").unwrap_or_else(|_| r"C:\Windows".to_string());

    let path = Path::new(&windows)
        .join("ServiceProfiles")
        .join("LocalService")
        .join("AppData")
        .join("Roaming")
        .join("RustDesk")
        .join("config")
        .join("RustDesk2.toml");

    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        Err(_) => return false,
    };

    let rendezvous = format!("{ID_SERVER}:{RENDEZVOUS_PORT}");

    content.contains(&format!("rendezvous_server = '{rendezvous}'"))
        && content.contains(&format!("custom-rendezvous-server = '{ID_SERVER}'"))
        && content.contains(&format!("relay-server = '{RELAY_SERVER}'"))
        && content.contains(&format!("key = '{RUSTDESK_KEY}'"))
}

pub fn get_rustdesk_status() -> Result<RustDeskStatus, String> {
    let installed = Path::new(RUSTDESK_EXE).exists();

    if !installed {
        return Ok(RustDeskStatus {
            installed: false,
            version: None,
            service_running: false,
            configured: false,
            id: None,
        });
    }

    let version = get_rustdesk_version();
    let service_running = is_rustdesk_service_running();
    let configured = is_rustdesk_configured();
    let id = get_rustdesk_id()?;

    Ok(RustDeskStatus {
        installed: true,
        version,
        service_running,
        configured,
        id,
    })
}

pub fn open_rustdesk() -> Result<(), String> {
    if !Path::new(RUSTDESK_EXE).exists() {
        return Err("RustDesk is not installed.".to_string());
    }

    Command::new(RUSTDESK_EXE)
        .spawn()
        .map_err(|e| format!("Failed to open RustDesk: {e}"))?;

    Ok(())
}
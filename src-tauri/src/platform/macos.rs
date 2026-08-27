use super::RustDeskPermissionsStatus;
use super::RustDeskStatus;

use serde::{Deserialize, Serialize};

use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

use tauri::Manager;

const RUSTDESK_APP: &str = "/Applications/RustDesk.app";
const RUSTDESK_EXE: &str = "/Applications/RustDesk.app/Contents/MacOS/RustDesk";

const ID_SERVER: &str = "rustdesk.magendamd.com";
const RELAY_SERVER: &str = "rustdesk.magendamd.com";
const RENDEZVOUS_PORT: &str = "21116";
const RUSTDESK_KEY: &str = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc=";

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
    let home = env::var("HOME").map_err(|_| "HOME environment variable not found".to_string())?;

    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("MagendaSupport")
        .join("install.json"))
}

pub fn get_install_config() -> Result<Option<InstallConfig>, String> {
    let path = install_config_path()?;

    if !path.exists() {
        return Ok(None);
    }

    let content = fs::read_to_string(&path)
        .map_err(|e| format!("Cannot read install config {}: {e}", path.display()))?;

    let config: InstallConfig =
        serde_json::from_str(&content).map_err(|e| format!("Invalid install config: {e}"))?;

    if config.install_token.trim().is_empty() {
        return Ok(None);
    }

    Ok(Some(config))
}

pub fn save_install_config(token: &str, mode: InstallMode) -> Result<(), String> {
    let token = token.trim();

    if token.is_empty() {
        return Err("Install token is empty.".to_string());
    }

    if !token
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("Install token contains invalid characters.".to_string());
    }

    let path = install_config_path()?;

    let parent = path
        .parent()
        .ok_or_else(|| "Invalid install config path.".to_string())?;

    fs::create_dir_all(parent)
        .map_err(|e| format!("Failed to create {}: {e}", parent.display()))?;

    let config = InstallConfig {
        install_token: token.to_string(),
        mode,
    };

    let json = serde_json::to_string_pretty(&config)
        .map_err(|e| format!("Failed to serialize install config: {e}"))?;

    fs::write(&path, json).map_err(|e| format!("Failed to write {}: {e}", path.display()))?;

    Ok(())
}

// ============================================================
// RUSTDESK ID
// ============================================================

pub fn get_rustdesk_id() -> Result<Option<String>, String> {
    if !Path::new(RUSTDESK_EXE).exists() {
        return Ok(None);
    }

    let output = Command::new(RUSTDESK_EXE)
        .arg("--get-id")
        .output()
        .map_err(|e| format!("Failed to run RustDesk --get-id: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

        if stderr.is_empty() {
            return Err(format!(
                "RustDesk --get-id failed with status: {}",
                output.status
            ));
        }

        return Err(format!("RustDesk --get-id failed: {stderr}"));
    }

    let id = String::from_utf8_lossy(&output.stdout).trim().to_string();

    if id.is_empty() {
        return Ok(None);
    }

    Ok(Some(id))
}

pub fn configure_rustdesk(app: &tauri::AppHandle) -> Result<(), String> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("Failed to resolve resource directory: {e}"))?;

    let script = resource_dir
        .join("resources")
        .join("macos")
        .join("configure-rustdesk.sh");

    if !script.exists() {
        return Err(format!(
            "configure-rustdesk.sh not found: {}",
            script.display()
        ));
    }

    let script_str = script
        .to_str()
        .ok_or_else(|| "Invalid configure script path".to_string())?;

    // Передаём path как argv в AppleScript,
    // чтобы не заниматься ручным quoting shell path.
    let apple_script = r#"
on run argv
    set scriptPath to item 1 of argv
    do shell script quoted form of scriptPath with administrator privileges
end run
"#;

    let output = std::process::Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(apple_script)
        .arg(script_str)
        .output()
        .map_err(|e| format!("Failed to start RustDesk installer: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

        return Err(if stderr.is_empty() {
            format!(
                "RustDesk configuration failed with status {}",
                output.status
            )
        } else {
            format!("RustDesk configuration failed: {stderr}")
        });
    }

    Ok(())
}

pub fn open_accessibility_settings() -> Result<(), String> {
    let status = Command::new("/usr/bin/open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        .status()
        .map_err(|e| format!("Failed to open Accessibility settings: {e}"))?;

    if !status.success() {
        return Err("Failed to open Accessibility settings.".to_string());
    }

    Ok(())
}

pub fn open_screen_recording_settings() -> Result<(), String> {
    let status = Command::new("/usr/bin/open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        .status()
        .map_err(|e| format!("Failed to open Screen Recording settings: {e}"))?;

    if !status.success() {
        return Err("Failed to open Screen Recording settings.".to_string());
    }

    Ok(())
}

pub fn open_input_monitoring_settings() -> Result<(), String> {
    let status = Command::new("/usr/bin/open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        .status()
        .map_err(|e| format!("Failed to open Input Monitoring settings: {e}"))?;

    if !status.success() {
        return Err("Failed to open Input Monitoring settings.".to_string());
    }

    Ok(())
}

pub fn get_rustdesk_permissions_status() -> Result<RustDeskPermissionsStatus, String> {
    Ok(RustDeskPermissionsStatus {
        accessibility: false,
        screen_recording: false,
        input_monitoring: false,
    })
}

fn get_rustdesk_version() -> Option<String> {
    let plist = format!("{RUSTDESK_APP}/Contents/Info.plist");

    if !Path::new(&plist).exists() {
        return None;
    }

    let output = Command::new("/usr/libexec/PlistBuddy")
        .arg("-c")
        .arg("Print :CFBundleShortVersionString")
        .arg(plist)
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();

    if version.is_empty() {
        None
    } else {
        Some(version)
    }
}

fn is_rustdesk_service_running() -> bool {
    Command::new("/bin/launchctl")
        .arg("print")
        .arg("system/com.carriez.RustDesk_service")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn is_rustdesk_configured() -> bool {
    let home = match std::env::var("HOME") {
        Ok(home) => home,
        Err(_) => return false,
    };

    let path = Path::new(&home)
        .join("Library")
        .join("Preferences")
        .join("com.carriez.RustDesk")
        .join("RustDesk2.toml");

    let content = match fs::read_to_string(path) {
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
    let app = "/Applications/RustDesk.app";

    if !std::path::Path::new(app).exists() {
        return Err("RustDesk is not installed.".to_string());
    }

    let status = Command::new("/usr/bin/open")
        .arg(app)
        .status()
        .map_err(|e| format!("Failed to open RustDesk: {e}"))?;

    if !status.success() {
        return Err("Failed to open RustDesk.".to_string());
    }

    Ok(())
}

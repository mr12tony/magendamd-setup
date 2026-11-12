use super::RustDeskPermissionsStatus;
use super::RustDeskStatus;
use super::windows_rustdesk::find_rustdesk_exe;

pub use super::windows_install_config::{InstallConfig, InstallMode};

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

const ID_SERVER: &str = "rustdesk.magendamd.com";
const RELAY_SERVER: &str = "rustdesk.magendamd.com";
const RENDEZVOUS_PORT: &str = "21116";
const RUSTDESK_KEY: &str = "+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc=";

// ============================================================
// INSTALL TOKEN
// ============================================================

fn install_config_path() -> Result<PathBuf, String> {
    let program_data = std::env::var("PROGRAMDATA")
        .map_err(|_| "PROGRAMDATA environment variable not found".to_string())?;

    Ok(PathBuf::from(program_data)
        .join("Magendamd")
        .join("install.json"))
}

fn user_install_config_path() -> Result<PathBuf, String> {
    let local_app_data = std::env::var_os("LOCALAPPDATA")
        .ok_or_else(|| {
            "LOCALAPPDATA environment variable not found".to_owned()
        })?;

    Ok(PathBuf::from(local_app_data)
        .join("MagendaSupport")
        .join("install.json"))
}

pub fn get_install_config() -> Result<Option<InstallConfig>, String> {
    super::windows_install_config::get_install_config(
        &user_install_config_path()?,
        install_config_path,
    )
}

pub fn save_install_config(
    token: &str,
    mode: InstallMode,
) -> Result<(), String> {
    use std::io::Write;

    let token = token.trim();

    if token.is_empty() {
        return Err("Install token is empty.".to_owned());
    }

    if !token
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("Install token contains invalid characters.".to_owned());
    }

    let path = user_install_config_path()?;

    let parent = path
        .parent()
        .ok_or_else(|| {
            "Invalid installation configuration path.".to_owned()
        })?;

    fs::create_dir_all(parent)
        .map_err(|_| {
            "Cannot create installation configuration directory.".to_owned()
        })?;

    let config = InstallConfig {
        install_token: token.to_owned(),
        mode,
    };

    let content = serde_json::to_vec_pretty(&config)
        .map_err(|_| {
            "Cannot serialize installation configuration.".to_owned()
        })?;

    let mut temporary = tempfile::NamedTempFile::new_in(parent)
        .map_err(|_| {
            "Cannot create temporary installation configuration.".to_owned()
        })?;

    temporary
        .write_all(&content)
        .and_then(|_| temporary.as_file().sync_all())
        .map_err(|_| {
            "Cannot write installation configuration.".to_owned()
        })?;

    temporary
        .persist(&path)
        .map_err(|_| {
            "Cannot save installation configuration.".to_owned()
        })?;

    Ok(())
}

pub fn get_rustdesk_id() -> Result<Option<String>, String> {
    let Some(executable) = find_rustdesk_exe() else {
        return Ok(None);
    };

    get_rustdesk_id_from(&executable)
}

fn get_rustdesk_id_from(executable: &Path) -> Result<Option<String>, String> {
    let output = Command::new(executable)
        .arg("--get-id")
        .output()
        .map_err(|e| format!("Failed to run RustDesk: {e}"))?;

    if !output.status.success() {
        return Ok(None);
    }

    let id = String::from_utf8_lossy(&output.stdout).trim().to_string();

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

fn get_rustdesk_version(executable: &Path) -> Option<String> {
    let script = format!(
        "(Get-Item -LiteralPath '{}').VersionInfo.ProductVersion",
        executable.to_string_lossy().replace('\'', "''")
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
    let Some(executable) = find_rustdesk_exe() else {
        return Ok(RustDeskStatus {
            installed: false,
            version: None,
            service_running: false,
            configured: false,
            id: None,
        });
    };

    let version = get_rustdesk_version(&executable);
    let service_running = is_rustdesk_service_running();
    let configured = is_rustdesk_configured();
    let id = get_rustdesk_id_from(&executable)?;

    Ok(RustDeskStatus {
        installed: true,
        version,
        service_running,
        configured,
        id,
    })
}

pub fn open_rustdesk() -> Result<(), String> {
    let executable = find_rustdesk_exe()
        .ok_or_else(|| "RustDesk is not installed.".to_owned())?;

    Command::new(executable)
        .spawn()
        .map_err(|e| format!("Failed to open RustDesk: {e}"))?;

    Ok(())
}

pub fn get_rustdesk_id_headless() -> Result<Option<String>, String> {
    let Some(executable) = find_rustdesk_exe() else {
        return Ok(None);
    };
    super::headless::get_id(executable)
}

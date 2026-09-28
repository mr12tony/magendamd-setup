use super::RustDeskPermissionsStatus;
use super::RustDeskStatus;

use serde::{Deserialize, Serialize};

use std::{
    env, fs,
    io::{ErrorKind, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::{Mutex, OnceLock},
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

// Cache successes, missing files and errors so startup cannot repeatedly scan Downloads.
static DOWNLOADS_IMPORT: OnceLock<Result<bool, String>> = OnceLock::new();
static INSTALL_CONFIG_WRITE: Mutex<()> = Mutex::new(());

pub fn get_install_config() -> Result<Option<InstallConfig>, String> {
    read_install_config(&install_config_path()?)
}

fn read_install_config_contents(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match fs::read(path) {
        Ok(content) => Ok(Some(content)),
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(None),
        Err(err) => Err(format!(
            "Cannot read install config {}: {err}",
            path.display()
        )),
    }
}

fn validate_install_config(token: &str, mode: InstallMode) -> Result<InstallConfig, String> {
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

    Ok(InstallConfig {
        install_token: token.to_string(),
        mode,
    })
}

fn parse_install_config(content: &[u8], path: &Path) -> Result<InstallConfig, String> {
    let config: InstallConfig = serde_json::from_slice(content)
        .map_err(|err| format!("Invalid install config {}: {err}", path.display()))?;

    validate_install_config(&config.install_token, config.mode)
        .map_err(|err| format!("Invalid install config {}: {err}", path.display()))
}

fn read_install_config(path: &Path) -> Result<Option<InstallConfig>, String> {
    read_install_config_contents(path)?
        .map(|content| parse_install_config(&content, path))
        .transpose()
}

fn has_valid_install_config(path: &Path) -> Result<bool, String> {
    // A malformed config can be repaired by importing a valid download.
    // Filesystem errors must still be reported rather than treated as missing files.
    Ok(read_install_config_contents(path)?
        .is_some_and(|content| parse_install_config(&content, path).is_ok()))
}

fn write_install_config(path: &Path, config: &InstallConfig) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "Invalid install config path.".to_string())?;

    fs::create_dir_all(parent)
        .map_err(|err| format!("Failed to create {}: {err}", parent.display()))?;

    let json = serde_json::to_string_pretty(config)
        .map_err(|err| format!("Failed to serialize install config: {err}"))?;

    // Keep the old file intact until the replacement is fully written.
    let mut temporary = tempfile::NamedTempFile::new_in(parent)
        .map_err(|err| format!("Failed to create temporary install config: {err}"))?;
    temporary
        .write_all(json.as_bytes())
        .and_then(|_| temporary.as_file().sync_all())
        .map_err(|err| format!("Failed to write install config {}: {err}", path.display()))?;
    temporary
        .persist(path)
        .map_err(|err| format!("Failed to save install config {}: {err}", path.display()))?;

    Ok(())
}

pub fn save_install_config(token: &str, mode: InstallMode) -> Result<(), String> {
    let config = validate_install_config(token, mode)?;
    let path = install_config_path()?;
    let _guard = INSTALL_CONFIG_WRITE
        .lock()
        .map_err(|_| "Install config write lock is unavailable.".to_string())?;

    write_install_config(&path, &config)
}

pub fn import_install_config_from_downloads() -> Result<bool, String> {
    let home = env::var("HOME").map_err(|_| "HOME environment variable not found".to_string())?;
    let downloads = PathBuf::from(home).join("Downloads");
    import_install_config_once(&DOWNLOADS_IMPORT, &downloads, &install_config_path()?)
}

fn import_install_config_once(
    attempt: &OnceLock<Result<bool, String>>,
    downloads: &Path,
    destination: &Path,
) -> Result<bool, String> {
    // A later deep link takes precedence even if the cached import attempt failed.
    if has_valid_install_config(destination)? {
        return Ok(false);
    }

    attempt
        .get_or_init(|| import_install_config_from_directory(downloads, destination))
        .clone()
}

fn import_install_config_from_directory(
    downloads: &Path,
    destination: &Path,
) -> Result<bool, String> {
    if has_valid_install_config(destination)? {
        return Ok(false);
    }

    let entries = match fs::read_dir(downloads) {
        Ok(entries) => entries,
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(false),
        Err(err) => {
            return Err(format!(
                "Cannot read Downloads directory {}: {err}. Check MagendaSupport's Downloads access in macOS System Settings > Privacy & Security > Files and Folders.",
                downloads.display()
            ));
        }
    };

    let mut candidates = Vec::new();

    for entry in entries {
        let entry = entry
            .map_err(|err| format!("Cannot read an entry in {}: {err}", downloads.display()))?;
        let filename = entry.file_name();
        let Some(name) = filename.to_str() else {
            continue;
        };
        if !is_install_json_filename(name) {
            continue;
        }

        let path = entry.path();
        let metadata = entry
            .metadata()
            .map_err(|err| format!("Cannot read metadata for {}: {err}", path.display()))?;
        if !metadata.is_file() {
            continue;
        }
        let modified = metadata.modified().map_err(|err| {
            format!(
                "Cannot read modification time for {}: {err}",
                path.display()
            )
        })?;
        candidates.push((path, modified));
    }

    // Choose by modification time, with a deterministic tie-breaker.
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let Some((source, _)) = candidates.first() else {
        return Ok(false);
    };

    // Do not silently fall back to an older token if the newest download is invalid.
    let config = read_install_config(source)?.ok_or_else(|| {
        format!(
            "Install config disappeared before import: {}",
            source.display()
        )
    })?;

    // A deep link may have saved a config while Downloads access was being granted.
    let _guard = INSTALL_CONFIG_WRITE
        .lock()
        .map_err(|_| "Install config write lock is unavailable.".to_string())?;
    if has_valid_install_config(destination)? {
        return Ok(false);
    }

    write_install_config(destination, &config)?;
    Ok(true)
}

pub fn is_install_json_filename(name: &str) -> bool {
    if name == "install.json" {
        return true;
    }

    let number = name
        .strip_prefix("install (")
        .and_then(|value| value.strip_suffix(").json"))
        .or_else(|| {
            name.strip_prefix("install-")
                .and_then(|value| value.strip_suffix(".json"))
        });

    number.is_some_and(|value| !value.is_empty() && value.bytes().all(|c| c.is_ascii_digit()))
}

#[cfg(test)]
mod install_config_tests;

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

pub fn get_rustdesk_id_headless() -> Result<Option<String>, String> {
    super::headless::get_id(RUSTDESK_EXE)
}

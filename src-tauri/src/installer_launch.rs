use crate::platform::{InstallConfig, InstallMode};
use serde::Serialize;
use std::{
    ffi::OsString,
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
    sync::Mutex,
};

type InstallerPath = Result<PathBuf, String>;

// Kept in memory until the GUI queue consumes it; never overwrites active config.
pub struct PendingLaunch(Mutex<(u64, Option<InstallerPath>)>);

impl PendingLaunch {
    pub fn new(request: Option<InstallerPath>) -> Self {
        Self(Mutex::new((1, request)))
    }

    pub fn replace(&self, request: InstallerPath) -> Result<(), String> {
        let mut pending = self
            .0
            .lock()
            .map_err(|_| "Cannot read the installer request.")?;
        pending.0 += 1;
        pending.1 = Some(request);
        Ok(())
    }

    pub fn current(&self) -> Result<Option<(u64, InstallerPath)>, String> {
        let pending = self
            .0
            .lock()
            .map_err(|_| "Cannot read the installer request.")?;
        Ok(pending.1.clone().map(|request| (pending.0, request)))
    }

    pub fn clear(&self, request_id: u64) -> Result<(), String> {
        let mut pending = self
            .0
            .lock()
            .map_err(|_| "Cannot read the installer request.")?;
        if pending.0 == request_id {
            pending.1 = None;
        }
        Ok(())
    }
}

#[derive(Serialize)]
pub struct InstallerLaunch {
    pub request_id: u64,
    pub config: Option<InstallConfig>,
    pub error: Option<String>,
}

pub fn from_args(args: &[OsString]) -> Option<InstallerPath> {
    if !args.iter().any(|arg| arg == "--auto-register") {
        return None;
    }
    let index = args.iter().position(|arg| arg == "--installer-path")?;
    Some(match args.get(index + 1) {
        Some(path) if !path.is_empty() && !path.to_string_lossy().starts_with("--") => {
            Ok(PathBuf::from(path))
        }
        _ => Err(
            "The installer path is missing. Open the Magenda platform to connect this computer."
                .into(),
        ),
    })
}

pub fn resolve(request_id: u64, path: InstallerPath) -> InstallerLaunch {
    match path.and_then(|path| {
        config_from_installer(&path)?.ok_or_else(|| {
            "No installation token was found. Download a personalized installer or connect through the Magenda platform."
                .to_owned()
        })
    }) {
        Ok(config) => InstallerLaunch {
            request_id,
            config: Some(config),
            error: None,
        },
        Err(error) => InstallerLaunch {
            request_id,
            config: None,
            error: Some(error),
        },
    }
}

fn validate(config: InstallConfig) -> Result<InstallConfig, String> {
    let token = config.install_token.trim();
    if token.is_empty()
        || !token
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err("The installation token is invalid. Download a new installer or connect through the Magenda platform.".into());
    }
    Ok(InstallConfig {
        install_token: token.to_owned(),
        mode: config.mode,
    })
}

fn config_from_filename(filename: &str) -> Result<Option<InstallConfig>, String> {
    let Some(extension) = filename.get(filename.len().saturating_sub(4)..) else {
        return Ok(None);
    };
    if !extension.eq_ignore_ascii_case(".exe") {
        return Ok(None);
    }
    let mut stem = &filename[..filename.len() - 4];
    // Chrome/Edge append " (N)" when downloading the same filename again.
    while let Some((base, suffix)) = stem.rsplit_once(" (") {
        let Some(number) = suffix.strip_suffix(')') else {
            break;
        };
        if number.is_empty() || !number.bytes().all(|c| c.is_ascii_digit()) {
            break;
        }
        stem = base;
    }
    const PREFIX: &str = "MagendaSupport-";
    if !stem
        .get(..PREFIX.len())
        .is_some_and(|s| s.eq_ignore_ascii_case(PREFIX))
    {
        return Ok(None);
    }
    let value = &stem[PREFIX.len()..];
    let invalid_name = || {
        "The installer filename is invalid. Download a new installer or connect through the Magenda platform.".to_owned()
    };
    let (token, mode) = value.rsplit_once('-').ok_or_else(invalid_name)?;
    let mode = match mode {
        "prod" => InstallMode::Prod,
        "dev" => InstallMode::Dev,
        "local" => InstallMode::Local,
        _ => return Err(invalid_name()),
    };
    validate(InstallConfig {
        install_token: token.to_owned(),
        mode,
    })
    .map(Some)
}

fn is_companion_name(name: &str) -> bool {
    let Some(stem) = name.strip_suffix(".json") else {
        return false;
    };
    let Some(suffix) = stem
        .strip_prefix("install")
        .or_else(|| stem.strip_prefix("MagendaConfig-user"))
    else {
        return false;
    };
    if suffix.is_empty() {
        return true;
    }
    let number = suffix
        .strip_prefix(" (")
        .and_then(|s| s.strip_suffix(')'))
        .or_else(|| suffix.strip_prefix('-'));
    number.is_some_and(|s| !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()))
}

fn config_from_installer(path: &Path) -> Result<Option<InstallConfig>, String> {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("Cannot read the installer filename.")?;
    // A recognized but malformed personalized name must not fall back to JSON.
    if let Some(config) = config_from_filename(name)? {
        return Ok(Some(config));
    }

    let directory = path.parent().ok_or("Cannot locate the installer folder.")?;
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(_) => {
            return Err("Cannot read installation configuration next to the installer.".into())
        }
    };
    let mut candidates = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|_| "Cannot read the installer folder.")?;
        if !entry.file_name().to_str().is_some_and(is_companion_name) {
            continue;
        }
        let metadata = entry
            .metadata()
            .map_err(|_| "Cannot read installation configuration metadata.")?;
        if metadata.is_file() {
            candidates.push((
                metadata
                    .modified()
                    .map_err(|_| "Cannot date installation configuration.")?,
                entry.path(),
            ));
        }
    }
    candidates.sort();
    let Some((_, path)) = candidates.pop() else {
        return Ok(None);
    };
    let bytes =
        fs::read(path).map_err(|_| "Cannot read the selected installation configuration.")?;
    let config = serde_json::from_slice(&bytes)
        .map_err(|_| "The selected installation configuration is invalid. Download it again or connect through the Magenda platform.")?;
    validate(config).map(Some)
}

#[cfg(test)]
#[path = "installer_launch_tests.rs"]
mod tests;

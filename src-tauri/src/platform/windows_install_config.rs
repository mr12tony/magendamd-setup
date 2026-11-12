//! Windows token lookup, including opt-out from the legacy machine-wide file.
//! Kept platform-independent so the reset/restart behavior is tested on any OS.
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

const IGNORE_LEGACY_FILE: &str = "ignore-legacy-install-config";

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

fn read_install_config(path: &Path) -> Result<Option<InstallConfig>, String> {
    let content = match fs::read(path) {
        Ok(content) => content,

        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(None);
        }

        Err(_) => {
            return Err("Cannot read installation configuration.".to_owned());
        }
    };

    let config: InstallConfig = serde_json::from_slice(&content)
        .map_err(|_| "Invalid installation configuration.".to_owned())?;

    let token = config.install_token.trim();

    if token.is_empty()
        || !token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("Invalid installation token.".to_owned());
    }

    Ok(Some(config))
}

pub(super) fn get_install_config(
    user_path: &Path,
    legacy_path: impl FnOnce() -> Result<PathBuf, String>,
) -> Result<Option<InstallConfig>, String> {
    if let Some(config) = read_install_config(user_path)? {
        return Ok(Some(config));
    }

    let directory = user_path
        .parent()
        .ok_or_else(|| "Invalid installation configuration path.".to_owned())?;
    match fs::metadata(directory.join(IGNORE_LEGACY_FILE)) {
        Ok(_) => return Ok(None),
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(_) => return Err("Cannot read installation configuration.".to_owned()),
    }
    read_install_config(&legacy_path()?)
}

pub(super) fn disable_legacy_fallback(directory: &Path) -> Result<(), i32> {
    // Write before clearing the JSON files. The marker survives app restarts and
    // prevents a reset user from falling back to another account in ProgramData.
    // No admin rights or changes to other users' machine-wide data are needed.
    fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(directory.join(IGNORE_LEGACY_FILE))
        .and_then(|file| file.sync_all())
        .map_err(|_| 40)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_config(path: &Path, token: &str) {
        let config = InstallConfig {
            install_token: token.to_owned(),
            mode: InstallMode::Dev,
        };
        fs::write(path, serde_json::to_vec(&config).unwrap()).unwrap();
    }

    #[test]
    fn legacy_installations_still_work_until_explicit_reset() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("legacy.json");
        let user = root.path().join("install.json");
        write_config(&legacy, "LEGACY");
        assert_eq!(
            get_install_config(&user, || Ok(legacy.clone()))
                .unwrap()
                .unwrap()
                .install_token,
            "LEGACY"
        );
        write_config(&user, "USER");
        let current = get_install_config(&user, || panic!("must prefer user config"))
            .unwrap()
            .unwrap();
        assert_eq!(current.install_token, "USER");
        assert!(matches!(current.mode, InstallMode::Dev));
    }

    #[test]
    fn reset_does_not_restore_a_legacy_token_on_the_next_read() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("user");
        fs::create_dir(&directory).unwrap();
        let user = directory.join("install.json");
        let legacy = root.path().join("legacy.json");
        write_config(&user, "OLD_USER");
        write_config(&legacy, "OLD_MACHINE");
        fs::write(directory.join("registration.json"), b"old registration").unwrap();

        disable_legacy_fallback(&directory).unwrap();
        crate::registration_files::clear_files_in(&directory).unwrap();
        assert!(!user.exists());
        assert!(!directory.join("registration.json").exists());
        // All state is read from disk, just as after restarting the app. Do not
        // even resolve PROGRAMDATA once the current user explicitly reset.
        assert!(
            get_install_config(&user, || panic!("legacy fallback after reset"))
                .unwrap()
                .is_none()
        );
        assert_eq!(
            read_install_config(&legacy).unwrap().unwrap().install_token,
            "OLD_MACHINE"
        );

        write_config(&user, "NEW_LINK");
        assert_eq!(
            get_install_config(&user, || panic!("legacy fallback after new link"))
                .unwrap()
                .unwrap()
                .install_token,
            "NEW_LINK"
        );
        disable_legacy_fallback(&directory).unwrap();
        crate::registration_files::clear_files_in(&directory).unwrap();
        assert!(
            get_install_config(&user, || panic!("legacy fallback after another reset"))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn an_unregistered_user_can_opt_out_without_a_machine_config() {
        let root = tempfile::tempdir().unwrap();
        disable_legacy_fallback(root.path()).unwrap();
        let user = root.path().join("install.json");
        assert!(
            get_install_config(&user, || Err("PROGRAMDATA unavailable".to_owned()))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn a_bad_local_config_never_falls_back_to_the_machine_token() {
        let root = tempfile::tempdir().unwrap();
        let user = root.path().join("install.json");
        for content in [
            b"invalid json".as_slice(),
            br#"{"install_token":"bad token","mode":"prod"}"#,
        ] {
            fs::write(&user, content).unwrap();
            assert!(get_install_config(&user, || panic!(
                "invalid user config must not use legacy"
            ))
            .is_err());
        }
    }

    #[test]
    fn failure_to_disable_legacy_fallback_is_reported() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join(IGNORE_LEGACY_FILE)).unwrap();
        assert_eq!(disable_legacy_fallback(root.path()), Err(40));
    }
}

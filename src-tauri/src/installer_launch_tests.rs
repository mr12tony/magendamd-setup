use super::*;
use std::{
    fs::FileTimes,
    time::{Duration, UNIX_EPOCH},
};

fn json_file(directory: &Path, name: &str, content: &str, modified: u64) {
    let path = directory.join(name);
    fs::write(&path, content).unwrap();
    fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_times(FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(modified)))
        .unwrap();
}

#[test]
fn parses_modes_and_preserves_hyphens_and_token_case() {
    for mode in ["dev", "prod", "local"] {
        let config =
            config_from_filename(&format!("MagendaSupport-AbC_12-with-hyphens-{mode}.exe"))
                .unwrap()
                .unwrap();
        assert_eq!(config.install_token, "AbC_12-with-hyphens");
        assert_eq!(serde_json::to_value(config.mode).unwrap(), mode);
    }
}

#[test]
fn accepts_browser_duplicate_suffixes_without_modifying_the_token() {
    for name in [
        "MagendaSupport-TOKEN-prod (1).exe",
        "MagendaSupport-TOKEN-prod (12) (2).exe",
        "magendasupport-TOKEN-prod.EXE",
    ] {
        assert_eq!(
            config_from_filename(name).unwrap().unwrap().install_token,
            "TOKEN"
        );
    }
}

#[test]
fn ordinary_installer_names_have_no_embedded_config() {
    for name in [
        "MagendaSupport.exe",
        "MagendaSupport_0.0.5_x64-setup.exe",
        "setup (1).exe",
        "🖥️.exe",
        "x",
    ] {
        assert!(config_from_filename(name).unwrap().is_none());
    }
}

#[test]
fn malformed_personalized_names_are_errors_without_leaking_tokens() {
    for name in [
        "MagendaSupport-SECRET-staging.exe",
        "MagendaSupport--prod.exe",
        "MagendaSupport-SECRET.prod-prod.exe",
        "MagendaSupport-SECRET prod.exe",
        "MagendaSupport-SECRET-prod (x).exe",
    ] {
        let error = config_from_filename(name).unwrap_err();
        assert!(!error.contains("SECRET"));
    }
}

#[test]
fn filename_wins_even_when_the_companion_json_is_invalid() {
    let directory = tempfile::tempdir().unwrap();
    json_file(directory.path(), "install.json", "{invalid", 1000);
    json_file(directory.path(), "MagendaConfig-user.json", "{invalid", 2000);
    let config = config_from_installer(&directory.path().join("MagendaSupport-FILENAME-dev.exe"))
        .unwrap()
        .unwrap();
    assert_eq!(config.install_token, "FILENAME");
    assert!(matches!(config.mode, InstallMode::Dev));
    // Resolving only reads sources; it does not create an active config.
    assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 2);
}

#[test]
fn malformed_filename_does_not_fall_back_to_a_valid_json() {
    let directory = tempfile::tempdir().unwrap();
    json_file(
        directory.path(),
        "install.json",
        r#"{"install_token":"OLD","mode":"prod"}"#,
        1000,
    );
    assert!(config_from_installer(&directory.path().join("MagendaSupport-NEW-wrong.exe")).is_err());
}

#[test]
fn ordinary_installer_uses_newest_supported_companion() {
    let directory = tempfile::tempdir().unwrap();
    json_file(
        directory.path(),
        "install.json",
        r#"{"install_token":"OLD","mode":"prod"}"#,
        1000,
    );
    json_file(
        directory.path(),
        "install (2).json",
        r#"{"install_token":" NEW ","mode":"dev"}"#,
        2000,
    );
    json_file(directory.path(), "install-backup.json", "{invalid", 3000);
    fs::create_dir(directory.path().join("install (3).json")).unwrap();
    let config = config_from_installer(&directory.path().join("MagendaSupport.exe"))
        .unwrap()
        .unwrap();
    assert_eq!(config.install_token, "NEW");
    assert!(matches!(config.mode, InstallMode::Dev));
}

#[test]
fn new_and_legacy_companions_share_modification_time_priority() {
    for name in [
        "MagendaConfig-user.json",
        "MagendaConfig-user (1).json",
        "MagendaConfig-user-2.json",
    ] {
        for (older, newer) in [("install.json", name), (name, "install-1.json")] {
            let directory = tempfile::tempdir().unwrap();
            json_file(
                directory.path(),
                older,
                r#"{"install_token":"OLD","mode":"prod"}"#,
                1000,
            );
            json_file(
                directory.path(),
                newer,
                r#"{"install_token":"NEW","mode":"dev"}"#,
                2000,
            );
            for ignored in [
                "MagendaConfig-user-backup.json",
                "MagendaConfig-user ().json",
                "MagendaConfig-user-.json",
                "MagendaConfig-user (a).json",
                "MagendaConfig-user (１).json",
                "MagendaConfig-user--1.json",
                "MagendaConfig-user.json.txt",
                "MagendaConfig-user (2).json.crdownload",
            ] {
                json_file(directory.path(), ignored, "{invalid", 3000);
            }
            fs::create_dir(directory.path().join("MagendaConfig-user (3).json")).unwrap();
            let config = config_from_installer(&directory.path().join("MagendaSupport.exe"))
                .unwrap()
                .unwrap();
            assert_eq!(config.install_token, "NEW", "{older} -> {newer}");
            assert!(matches!(config.mode, InstallMode::Dev));
            assert!(directory.path().join(newer).is_file());
        }
    }
}

#[test]
fn invalid_newest_json_never_falls_back_to_an_older_account() {
    for (older, newer) in [
        ("install.json", "install-2.json"),
        ("install.json", "MagendaConfig-user (1).json"),
        ("MagendaConfig-user.json", "install-2.json"),
    ] {
        let directory = tempfile::tempdir().unwrap();
        json_file(
            directory.path(),
            older,
            r#"{"install_token":"OLD","mode":"prod"}"#,
            1000,
        );
        for invalid in [
            "{invalid",
            r#"{"install_token":"NEW","mode":"staging"}"#,
            r#"{"install_token":"BAD TOKEN","mode":"prod"}"#,
        ] {
            json_file(directory.path(), newer, invalid, 2000);
            assert!(config_from_installer(&directory.path().join("MagendaSupport.exe")).is_err());
        }
    }
}

#[test]
fn absent_sources_require_a_new_connection_instead_of_saved_config_lookup() {
    let directory = tempfile::tempdir().unwrap();
    let launch = resolve(1, Ok(directory.path().join("MagendaSupport.exe")));
    assert!(launch.config.is_none());
    assert!(launch.error.unwrap().contains("No installation token was found"));
}

#[test]
fn installer_path_arguments_preserve_spaces_and_require_the_launch_flag() {
    let args: Vec<OsString> = [
        "app.exe",
        "--auto-register",
        "--installer-path",
        r"C:\Downloads folder\MagendaSupport-TOKEN-prod (1).exe",
    ]
    .into_iter()
    .map(Into::into)
    .collect();
    assert_eq!(from_args(&args).unwrap().unwrap(), PathBuf::from(&args[3]));
    assert!(from_args(&args[..3]).unwrap().is_err());
    assert!(from_args(&["app.exe".into(), "--auto-register".into()]).is_none());
    assert!(from_args(&[
        "app.exe".into(),
        "--installer-path".into(),
        "file.exe".into()
    ])
    .is_none());
}

#[test]
fn acknowledging_an_old_request_does_not_drop_a_newer_installer() {
    let pending = PendingLaunch::new(Some(Ok(PathBuf::from("first.exe"))));
    let (first, _) = pending.current().unwrap().unwrap();
    // Reading is repeatable until the frontend has accepted the request.
    assert_eq!(pending.current().unwrap().unwrap().0, first);
    pending.replace(Ok(PathBuf::from("second.exe"))).unwrap();
    pending.clear(first).unwrap();
    let (second, path) = pending.current().unwrap().unwrap();
    assert!(second > first);
    assert_eq!(path.unwrap(), PathBuf::from("second.exe"));
    pending.clear(second).unwrap();
    assert!(pending.current().unwrap().is_none());
}

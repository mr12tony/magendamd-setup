use super::*;
use std::time::{Duration, SystemTime};

struct ConfigFiles {
    _root: tempfile::TempDir,
    downloads: PathBuf,
    destination: PathBuf,
}

impl ConfigFiles {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let downloads = root.path().join("Downloads");
        let destination = root
            .path()
            .join("Application Support/MagendaSupport/install.json");
        fs::create_dir(&downloads).unwrap();
        Self {
            _root: root,
            downloads,
            destination,
        }
    }

    fn download(&self, name: &str, content: &[u8], modified: u64) {
        let path = self.downloads.join(name);
        fs::write(&path, content).unwrap();
        fs::File::open(path)
            .unwrap()
            .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(modified))
            .unwrap();
    }

    fn import(&self) -> Result<bool, String> {
        import_install_config_from_directory(&self.downloads, &self.destination)
    }
}

const VALID: &[u8] = br#"{"install_token":"VALID_TOKEN","mode":"prod"}"#;

#[test]
fn accepts_supported_browser_filenames_only() {
    for name in [
        "install.json",
        "install (1).json",
        "install (001).json",
        "install-2.json",
    ] {
        assert!(is_install_json_filename(name), "{name}");
    }
    for name in [
        "",
        "install ().json",
        "install-.json",
        "install (a).json",
        "install (１).json",
        "install--1.json",
        "INSTALL.JSON",
        "install.json.txt",
        "install (1).json.crdownload",
    ] {
        assert!(!is_install_json_filename(name), "{name}");
    }
}

#[test]
fn imports_newest_by_modification_time_and_normalizes_token() {
    let files = ConfigFiles::new();
    files.download("install (99).json", VALID, 1000);
    files.download(
        "install-2.json",
        br#"{"install_token":"  NEW_TOKEN  ","mode":"dev"}"#,
        2000,
    );
    assert!(files.import().unwrap());
    let config = read_install_config(&files.destination).unwrap().unwrap();
    assert_eq!(config.install_token, "NEW_TOKEN");
    assert!(matches!(config.mode, InstallMode::Dev));
    assert!(files.downloads.join("install-2.json").is_file());
}

#[test]
fn rejects_invalid_newest_without_saving_or_using_an_older_token() {
    for invalid in [
        b"{incomplete".as_slice(),
        br#"{"install_token":"  ","mode":"prod"}"#,
        br#"{"install_token":"BAD\nTOKEN","mode":"prod"}"#,
        br#"{"install_token":"TOKEN","mode":"unknown"}"#,
    ] {
        let files = ConfigFiles::new();
        files.download("install.json", VALID, 1000);
        files.download("install (1).json", invalid, 2000);
        let error = files.import().unwrap_err();
        assert!(error.contains("install (1).json"));
        assert!(!files.destination.exists());
    }
}

#[test]
fn repairs_a_corrupt_local_config_only_with_a_valid_download() {
    let files = ConfigFiles::new();
    fs::create_dir_all(files.destination.parent().unwrap()).unwrap();
    fs::write(&files.destination, [0xff, 0xfe]).unwrap();
    files.download("install.json", b"{incomplete", 1000);
    assert!(files.import().is_err());
    assert_eq!(fs::read(&files.destination).unwrap(), [0xff, 0xfe]);

    files.download("install.json", VALID, 2000);
    assert!(files.import().unwrap());
    assert_eq!(
        read_install_config(&files.destination)
            .unwrap()
            .unwrap()
            .install_token,
        "VALID_TOKEN"
    );
}

#[test]
fn valid_local_config_prevents_any_downloads_scan() {
    let files = ConfigFiles::new();
    let config = validate_install_config("EXISTING_TOKEN", InstallMode::Local).unwrap();
    write_install_config(&files.destination, &config).unwrap();
    fs::remove_dir(&files.downloads).unwrap();
    fs::write(&files.downloads, b"not a directory").unwrap();
    assert!(!files.import().unwrap());
    assert_eq!(
        read_install_config(&files.destination)
            .unwrap()
            .unwrap()
            .install_token,
        "EXISTING_TOKEN"
    );
}

#[test]
fn filesystem_errors_are_distinct_from_absent_configs() {
    let files = ConfigFiles::new();
    assert!(read_install_config(&files.destination).unwrap().is_none());
    assert!(!files.import().unwrap());
    fs::remove_dir(&files.downloads).unwrap();
    fs::write(&files.downloads, b"not a directory").unwrap();
    assert!(files
        .import()
        .unwrap_err()
        .contains("Cannot read Downloads directory"));
    fs::create_dir_all(&files.destination).unwrap();
    assert!(read_install_config(&files.destination).is_err());
}

#[test]
fn failed_import_is_not_retried_until_a_new_startup() {
    let files = ConfigFiles::new();
    let attempt = OnceLock::new();
    files.download("install.json", b"{incomplete", 1000);
    let error =
        import_install_config_once(&attempt, &files.downloads, &files.destination).unwrap_err();
    files.download("install.json", VALID, 2000);
    assert_eq!(
        import_install_config_once(&attempt, &files.downloads, &files.destination).unwrap_err(),
        error
    );
    assert!(!files.destination.exists());
    assert!(
        import_install_config_once(&OnceLock::new(), &files.downloads, &files.destination).unwrap()
    );
}

#[test]
fn deep_link_config_takes_precedence_over_a_cached_import_error() {
    let files = ConfigFiles::new();
    let attempt = OnceLock::new();
    files.download("install.json", b"{incomplete", 1000);
    assert!(import_install_config_once(&attempt, &files.downloads, &files.destination).is_err());

    let config = validate_install_config("DEEP_LINK_TOKEN", InstallMode::Prod).unwrap();
    write_install_config(&files.destination, &config).unwrap();
    assert!(!import_install_config_once(&attempt, &files.downloads, &files.destination).unwrap());
    assert_eq!(
        read_install_config(&files.destination)
            .unwrap()
            .unwrap()
            .install_token,
        "DEEP_LINK_TOKEN"
    );
}

#[test]
fn failed_atomic_save_preserves_destination_and_cleans_up_temporary_file() {
    let files = ConfigFiles::new();
    fs::create_dir_all(&files.destination).unwrap();
    let config = validate_install_config("VALID_TOKEN", InstallMode::Prod).unwrap();
    assert!(write_install_config(&files.destination, &config).is_err());
    assert!(files.destination.is_dir());
    assert_eq!(
        fs::read_dir(files.destination.parent().unwrap())
            .unwrap()
            .count(),
        1
    );
}

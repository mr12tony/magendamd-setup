use crate::registration_files;
use std::{fs, io::ErrorKind, path::Path};

// NSIS stops the running app first. If another registration still holds the
// lock, fail before uninstalling rather than wait indefinitely or race its save.
pub(crate) fn clear_for_uninstall_in(directory: &Path) -> Result<(), i32> {
    if !directory.try_exists().map_err(|_| 40)? {
        return Ok(());
    }

    let file = registration_files::open_lock_in(directory)?;
    fs2::FileExt::try_lock_exclusive(&file).map_err(|_| 42)?;
    registration_files::clear_files_in(directory)
}

pub fn clear_files(local: &Path, roaming: Option<&Path>, bundle_id: &str) -> Result<(), i32> {
    clear_for_uninstall_in(&local.join("MagendaSupport"))?;
    if let Some(roaming) = roaming {
        remove_app_directory(&local.join(bundle_id))?;
        remove_app_directory(&roaming.join(bundle_id))?;
    }
    Ok(())
}

fn remove_app_directory(path: &Path) -> Result<(), i32> {
    // remove_dir_all does not follow directory symlinks/junctions. All calls
    // additionally run impersonating the desktop user, without admin file access.
    match fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(_) => Err(40),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BUNDLE: &str = "com.magendamd.support";

    fn seed_profile(profile: &Path) {
        for path in [
            "Local/MagendaSupport",
            "Local/com.magendamd.support/WebView",
            "Roaming/com.magendamd.support",
            "Roaming/RustDesk",
        ] {
            let directory = profile.join(path);
            fs::create_dir_all(&directory).unwrap();
            fs::write(directory.join("keep"), b"data").unwrap();
        }
        for name in ["install.json", "registration.json"] {
            fs::write(profile.join("Local/MagendaSupport").join(name), b"old").unwrap();
        }
    }

    #[test]
    fn checkbox_cleans_only_the_selected_users_app_data() {
        for delete_app_data in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let user = root.path().join("desktop-user");
            let admin = root.path().join("uac-admin");
            seed_profile(&user);
            seed_profile(&admin);
            let local = user.join("Local");
            let roaming = user.join("Roaming");
            clear_files(&local, delete_app_data.then_some(roaming.as_path()), BUNDLE).unwrap();
            clear_files(&local, delete_app_data.then_some(roaming.as_path()), BUNDLE).unwrap();

            assert!(!local.join("MagendaSupport/install.json").exists());
            assert!(!local.join("MagendaSupport/registration.json").exists());
            assert!(local.join("MagendaSupport/keep").exists());
            assert!(roaming.join("RustDesk/keep").exists());
            assert_eq!(local.join(BUNDLE).exists(), !delete_app_data);
            assert_eq!(roaming.join(BUNDLE).exists(), !delete_app_data);
            assert!(admin.join("Local/MagendaSupport/install.json").exists());
            assert!(admin
                .join("Local/com.magendamd.support/WebView/keep")
                .exists());
            assert!(admin.join("Roaming/com.magendamd.support/keep").exists());
        }
    }

    #[test]
    fn missing_data_is_not_created_even_with_checkbox() {
        let root = tempfile::tempdir().unwrap();
        let local = root.path().join("Local");
        let roaming = root.path().join("Roaming");
        clear_files(&local, Some(&roaming), BUNDLE).unwrap();
        assert!(!local.exists());
        assert!(!roaming.exists());
    }

    #[test]
    fn busy_registration_preserves_optional_app_data() {
        let root = tempfile::tempdir().unwrap();
        seed_profile(root.path());
        let local = root.path().join("Local");
        let roaming = root.path().join("Roaming");
        let lock = registration_files::open_lock_in(&local.join("MagendaSupport")).unwrap();
        fs2::FileExt::lock_exclusive(&lock).unwrap();
        assert_eq!(clear_files(&local, Some(&roaming), BUNDLE), Err(42));
        assert!(local.join("MagendaSupport/install.json").exists());
        assert!(local.join("com.magendamd.support/WebView/keep").exists());
        assert!(roaming.join("com.magendamd.support/keep").exists());
        fs2::FileExt::unlock(&lock).unwrap();
    }

    #[cfg(unix)]
    fn directory_link(target: &Path, link: &Path) {
        std::os::unix::fs::symlink(target, link).unwrap();
    }

    #[cfg(windows)]
    fn directory_link(target: &Path, link: &Path) {
        // Junctions work without Developer Mode or symbolic-link privileges.
        assert!(std::process::Command::new("cmd.exe")
            .args(["/D", "/C", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .output()
            .unwrap()
            .status
            .success());
    }

    #[test]
    fn app_data_cleanup_does_not_follow_directory_links() {
        let root = tempfile::tempdir().unwrap();
        let local = root.path().join("Local");
        let roaming = root.path().join("Roaming");
        let external = root.path().join("unrelated");
        for directory in [&local, &roaming, &external] {
            fs::create_dir(directory).unwrap();
        }
        fs::write(external.join("keep"), b"keep").unwrap();
        directory_link(&external, &local.join(BUNDLE));
        fs::create_dir(roaming.join(BUNDLE)).unwrap();
        directory_link(&external, &roaming.join(BUNDLE).join("nested-link"));

        clear_files(&local, Some(&roaming), BUNDLE).unwrap();
        assert!(!local.join(BUNDLE).exists());
        assert!(!roaming.join(BUNDLE).exists());
        assert_eq!(fs::read(external.join("keep")).unwrap(), b"keep");
    }

    #[test]
    fn unexpected_file_instead_of_app_directory_is_reported() {
        let root = tempfile::tempdir().unwrap();
        let local = root.path().join("Local");
        let roaming = root.path().join("Roaming");
        fs::create_dir(&local).unwrap();
        fs::write(local.join(BUNDLE), b"unexpected file").unwrap();
        assert_eq!(clear_files(&local, Some(&roaming), BUNDLE), Err(40));
        assert_eq!(fs::read(local.join(BUNDLE)).unwrap(), b"unexpected file");
    }

    #[test]
    fn uninstall_removes_only_registration_files_and_is_repeatable() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("desktop-user");
        let other_user = root.path().join("uac-admin");
        for path in [&directory, &other_user] {
            fs::create_dir(path).unwrap();
            fs::write(path.join("install.json"), b"token").unwrap();
            fs::write(path.join("registration.json"), b"registration").unwrap();
            fs::write(path.join("other.json"), b"keep").unwrap();
        }

        clear_for_uninstall_in(&directory).unwrap();
        clear_for_uninstall_in(&directory).unwrap();

        assert!(!directory.join("install.json").exists());
        assert!(!directory.join("registration.json").exists());
        assert!(directory.join("registration.lock").exists());
        assert_eq!(fs::read(directory.join("other.json")).unwrap(), b"keep");
        assert_eq!(fs::read(other_user.join("install.json")).unwrap(), b"token");
        assert_eq!(
            fs::read(other_user.join("registration.json")).unwrap(),
            b"registration"
        );
    }

    #[test]
    fn uninstall_leaves_missing_profile_directory_absent() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("MagendaSupport");
        clear_for_uninstall_in(&directory).unwrap();
        assert!(!directory.exists());
    }

    #[test]
    fn uninstall_fails_without_deleting_data_while_registration_is_locked() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("install.json"), b"token").unwrap();
        fs::write(directory.path().join("registration.json"), b"registration").unwrap();
        let lock = registration_files::open_lock_in(directory.path()).unwrap();
        fs2::FileExt::lock_exclusive(&lock).unwrap();

        assert_eq!(clear_for_uninstall_in(directory.path()), Err(42));
        assert_eq!(
            fs::read(directory.path().join("install.json")).unwrap(),
            b"token"
        );
        assert_eq!(
            fs::read(directory.path().join("registration.json")).unwrap(),
            b"registration"
        );
        fs2::FileExt::unlock(&lock).unwrap();
        drop(lock);
        clear_for_uninstall_in(directory.path()).unwrap();
        assert!(!directory.path().join("install.json").exists());
        assert!(!directory.path().join("registration.json").exists());
    }

    #[test]
    fn uninstall_reports_deletion_errors_without_recursive_cleanup() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("install.json");
        fs::create_dir(&config).unwrap();
        fs::write(config.join("keep"), b"keep").unwrap();
        fs::write(directory.path().join("registration.json"), b"registration").unwrap();

        assert_eq!(clear_for_uninstall_in(directory.path()), Err(40));
        assert_eq!(fs::read(config.join("keep")).unwrap(), b"keep");
        assert_eq!(
            fs::read(directory.path().join("registration.json")).unwrap(),
            b"registration"
        );
    }
}

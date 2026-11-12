use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};

#[cfg(target_os = "windows")]
pub(super) fn find_rustdesk_exe() -> Option<PathBuf> {
    find_with(|name| std::env::var_os(name), Path::is_file)
}

fn find_with(
    mut get_env: impl FnMut(&str) -> Option<OsString>,
    mut is_file: impl FnMut(&Path) -> bool,
) -> Option<PathBuf> {
    // Keep the order aligned with Find-RustDeskExe in configure-rustdesk.ps1.
    // ProgramW6432 also resolves native Program Files from a 32-bit process.
    ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"]
        .into_iter()
        .filter_map(|name| get_env(name))
        .filter(|root| !root.to_string_lossy().trim().is_empty())
        .map(|root| PathBuf::from(root).join("RustDesk").join("rustdesk.exe"))
        .chain([
            PathBuf::from(r"C:\Program Files\RustDesk\rustdesk.exe"),
            PathBuf::from(r"C:\Program Files (x86)\RustDesk\rustdesk.exe"),
        ])
        .find(|path| is_file(path))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn install(root: &Path) -> PathBuf {
        let executable = root.join("RustDesk").join("rustdesk.exe");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        fs::write(&executable, b"test executable").unwrap();
        executable
    }

    #[test]
    fn discovers_an_installation_in_each_program_files_location() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("Програми (x86)");
        let executable = install(&root);
        for variable in ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"] {
            assert_eq!(
                find_with(
                    |name| (name == variable).then(|| root.clone().into_os_string()),
                    |path| path.starts_with(directory.path()) && path.is_file(),
                ),
                Some(executable.clone()),
                "{variable}"
            );
        }
    }

    #[test]
    fn prefers_native_installation_and_skips_missing_files_and_directories() {
        let directory = tempfile::tempdir().unwrap();
        let native = directory.path().join("native");
        let process = directory.path().join("process");
        let x86 = directory.path().join("x86");
        let native_exe = install(&native);
        let process_exe = install(&process);
        let x86_exe = install(&x86);
        let find = || {
            find_with(
                |name| {
                    Some(match name {
                        "ProgramW6432" => native.clone().into_os_string(),
                        "ProgramFiles" => process.clone().into_os_string(),
                        "ProgramFiles(x86)" => x86.clone().into_os_string(),
                        _ => unreachable!(),
                    })
                },
                |path| path.starts_with(directory.path()) && path.is_file(),
            )
        };
        assert_eq!(find(), Some(native_exe.clone()));
        fs::remove_file(&native_exe).unwrap();
        assert_eq!(find(), Some(process_exe.clone()));
        fs::remove_file(&process_exe).unwrap();
        fs::create_dir(&process_exe).unwrap();
        assert_eq!(find(), Some(x86_exe.clone()));
        fs::remove_file(x86_exe).unwrap();
        assert_eq!(find(), None);
    }

    #[test]
    fn uses_standard_fallbacks_when_environment_is_missing_or_blank() {
        for fallback in [
            r"C:\Program Files\RustDesk\rustdesk.exe",
            r"C:\Program Files (x86)\RustDesk\rustdesk.exe",
        ] {
            for value in [None, Some(OsString::new()), Some(OsString::from("  "))] {
                assert_eq!(
                    find_with(|_| value.clone(), |path| path == Path::new(fallback)),
                    Some(PathBuf::from(fallback)),
                );
            }
        }
    }
}

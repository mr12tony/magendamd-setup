use std::{env, fs, path::PathBuf, process::Command};

fn main() {
    prepare_registration_password();
    prepare_windows_uninstaller();
    tauri_build::build();
}

fn prepare_windows_uninstaller() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    for path in [
        "windows/uninstall-helper/Cargo.toml",
        "windows/uninstall-helper/Cargo.lock",
        "windows/uninstall-helper/src",
        "src/registration_files.rs",
    ] {
        println!("cargo:rerun-if-changed={path}");
    }

    let target = env::var("TARGET").expect("TARGET is missing");
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is missing"));
    // A separate target directory avoids recursively waiting for Cargo's parent
    // build lock. The helper has its own small, locked dependency graph.
    let helper_target = out.join("uninstall-helper");
    let mut command = Command::new(env::var_os("CARGO").expect("CARGO is missing"));
    command
        .args([
            "build",
            "--locked",
            "--release",
            "--manifest-path",
            "windows/uninstall-helper/Cargo.toml",
            "--jobs",
            "1",
            "--target",
            &target,
            "--target-dir",
        ])
        .arg(&helper_target)
        .env_remove("CARGO_MAKEFLAGS")
        .env_remove("MAKEFLAGS")
        .env_remove("MFLAGS");
    if target.ends_with("-msvc") {
        // The uninstaller must not require a separately installed VC++ runtime.
        let mut flags = env::var("CARGO_ENCODED_RUSTFLAGS").unwrap_or_default();
        if !flags.is_empty() {
            flags.push('\u{1f}');
        }
        flags.push_str("-Ctarget-feature=+crt-static");
        command.env("CARGO_ENCODED_RUSTFLAGS", flags);
    }
    let status = command
        .status()
        .expect("Cannot build the Windows uninstall helper");
    assert!(status.success(), "Windows uninstall helper build failed");

    // Tauri uses this same OUT_DIR ancestry to find the main binary's directory,
    // including --target, custom target directories and debug/release profiles.
    let binary_directory = out
        .ancestors()
        .nth(3)
        .expect("Cargo output directory is invalid");
    fs::copy(
        helper_target
            .join(&target)
            .join("release/magenda-uninstall-cleanup.exe"),
        binary_directory.join("magenda-uninstall-cleanup.exe"),
    )
    .expect("Cannot prepare the embedded Windows uninstall helper");
}

fn prepare_registration_password() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=MAGENDA_BUILD_MODE");
    println!("cargo:rerun-if-env-changed=VITE_PERMANENT_PASSWORD");

    let root = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR")
            .expect("CARGO_MANIFEST_DIR is missing"),
    )
    .parent()
    .expect("Project root is missing")
    .to_path_buf();

    let mode = env::var("MAGENDA_BUILD_MODE").unwrap_or_else(|_| {
        if env::var("PROFILE").as_deref() == Ok("release") {
            "production".to_owned()
        } else {
            "development".to_owned()
        }
    });

    if !matches!(mode.as_str(), "development" | "production") {
        panic!("MAGENDA_BUILD_MODE must be development or production");
    }

    let env_file = root.join(format!(".env.{mode}"));

    println!("cargo:rerun-if-changed={}", env_file.display());

    // Значение из окружения сборки имеет приоритет над файлом.
    let password = match env::var("VITE_PERMANENT_PASSWORD") {
        Ok(value) => value,

        Err(env::VarError::NotPresent) => {
            let entries = dotenvy::from_path_iter(&env_file)
                .unwrap_or_else(|_| {
                    panic!("Cannot read the selected environment file")
                });

            let mut password = None;

            for entry in entries {
                let (key, value) = entry.unwrap_or_else(|_| {
                    panic!("Invalid environment file")
                });

                if key == "VITE_PERMANENT_PASSWORD" {
                    password = Some(value);
                }
            }

            password.expect(
                "VITE_PERMANENT_PASSWORD is missing from the environment file",
            )
        }

        Err(_) => {
            panic!("VITE_PERMANENT_PASSWORD is not valid Unicode");
        }
    };

    if password.is_empty() {
        panic!("VITE_PERMANENT_PASSWORD is empty");
    }

    let output = PathBuf::from(
        env::var_os("OUT_DIR").expect("OUT_DIR is missing"),
    )
    .join("registration-password.txt");

    // Не выводим пароль в stdout или сообщения об ошибках.
    fs::write(output, password.as_bytes())
        .expect("Cannot prepare registration configuration");
}

use std::{env, fs, path::PathBuf};

fn main() {
    prepare_registration_password();
    tauri_build::build();
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
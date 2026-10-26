// use serde::Deserialize;
// use std::path::PathBuf;

// #[derive(Deserialize)]
// struct InstallConfig {
//     install_token: String,
// }

// fn install_config_path() -> Result<PathBuf, String> {
//     let program_data = std::env::var("PROGRAMDATA")
//         .map_err(|_| "PROGRAMDATA environment variable not found".to_string())?;

//     Ok(
//         PathBuf::from(program_data)
//             .join("Magendamd")
//             .join("install.json")
//     )
// }

// #[tauri::command]
// fn get_install_token() -> Result<String, String> {
//     let path = install_config_path()?;

//     let content = std::fs::read_to_string(&path)
//         .map_err(|e| {
//             format!(
//                 "Cannot read install config {}: {e}",
//                 path.display()
//             )
//         })?;

//     let config: InstallConfig = serde_json::from_str(&content)
//         .map_err(|e| format!("Invalid install config: {e}"))?;

//     Ok(config.install_token)
// }

use tauri_plugin_updater::UpdaterExt;

#[derive(serde::Serialize)]
struct UpdateInfo {
    available: bool,
    version: Option<String>,
    notes: Option<String>,
}

mod platform;

mod auto_register;

mod registration_state;

mod installer_launch;

#[tauri::command]
async fn get_installer_launch(
    pending: tauri::State<'_, installer_launch::PendingLaunch>,
) -> Result<Option<installer_launch::InstallerLaunch>, String> {
    let request = pending.current()?;
    tauri::async_runtime::spawn_blocking(move || {
        request.map(|(id, path)| installer_launch::resolve(id, path))
    })
        .await
        .map_err(|_| "Cannot read installation configuration.".to_owned())
}

#[tauri::command]
fn clear_installer_launch(
    pending: tauri::State<'_, installer_launch::PendingLaunch>,
    request_id: u64,
) -> Result<(), String> {
    pending.clear(request_id)
}

#[tauri::command]
fn get_install_config() -> Result<Option<platform::InstallConfig>, String> {
    platform::get_install_config()
}

#[tauri::command]
async fn initialize_install_config() -> Result<Option<platform::InstallConfig>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        #[cfg(target_os = "macos")]
        platform::import_install_config_from_downloads()?;

        platform::get_install_config()
    })
    .await
    .map_err(|err| format!("Failed to initialize install config: {err}"))?
}

#[tauri::command]
fn save_install_config(token: String, mode: platform::InstallMode) -> Result<(), String> {
    platform::save_install_config(&token, mode)
}

#[tauri::command]
fn get_rustdesk_id() -> Result<Option<String>, String> {
    platform::get_rustdesk_id()
}

static RUSTDESK_SETUP_LOCK: std::sync::Mutex<()> =
    std::sync::Mutex::new(());

#[tauri::command]
async fn configure_rustdesk(
    app: tauri::AppHandle,
) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = RUSTDESK_SETUP_LOCK
            .try_lock()
            .map_err(|_| {
                "RustDesk installation is already running. \
                 Please wait for it to finish and try again."
                    .to_owned()
            })?;

        platform::configure_rustdesk(&app)
    })
    .await
    .map_err(|_| "RustDesk installation task failed.".to_owned())?
}

#[tauri::command]
fn get_rustdesk_permissions_status() -> Result<platform::RustDeskPermissionsStatus, String> {
    platform::get_rustdesk_permissions_status()
}

#[tauri::command]
fn open_accessibility_settings() -> Result<(), String> {
    platform::open_accessibility_settings()
}

#[tauri::command]
fn open_screen_recording_settings() -> Result<(), String> {
    platform::open_screen_recording_settings()
}

#[tauri::command]
fn open_input_monitoring_settings() -> Result<(), String> {
    platform::open_input_monitoring_settings()
}

#[tauri::command]
fn get_rustdesk_status() -> Result<platform::RustDeskStatus, String> {
    platform::get_rustdesk_status()
}

#[tauri::command]
fn open_rustdesk() -> Result<(), String> {
    platform::open_rustdesk()
}

#[tauri::command]
async fn check_for_updates(
    app: tauri::AppHandle,
) -> Result<UpdateInfo, String> {
    let config = platform::get_install_config()?
        .ok_or_else(|| {
            "Install configuration is missing.".to_string()
        })?;

    let endpoint = match config.mode {
        platform::InstallMode::Dev => {
            "https://dev.magendamd.com/api/app-updates/{{target}}/{{arch}}/{{current_version}}"
        }

        platform::InstallMode::Prod => {
            "https://app.magendamd.com/api/app-updates/{{target}}/{{arch}}/{{current_version}}"
        }

        platform::InstallMode::Local => {
            "http://127.0.0.1:3000/api/app-updates/{{target}}/{{arch}}/{{current_version}}"
        }
    };

    let endpoint = endpoint
        .parse()
        .map_err(|e| {
            format!("Invalid updater endpoint: {e}")
        })?;

    let updater = app
        .updater_builder()
        .endpoints(vec![endpoint])
        .map_err(|e| e.to_string())?
        .build()
        .map_err(|e| e.to_string())?;

    let update = updater
        .check()
        .await
        .map_err(|e| e.to_string())?;

    match update {
        Some(update) => {
            Ok(UpdateInfo {
                available: true,
                version: Some(
                    update.version.clone(),
                ),
                notes: update.body.clone(),
            })
        }

        None => {
            Ok(UpdateInfo {
                available: false,
                version: None,
                notes: None,
            })
        }
    }
}

#[tauri::command]
async fn download_and_install_update(
    app: tauri::AppHandle,
) -> Result<(), String> {
    let config = platform::get_install_config()?
        .ok_or_else(|| {
            "Install configuration is missing.".to_string()
        })?;

    let endpoint = match config.mode {
        platform::InstallMode::Dev => {
            "https://dev.magendamd.com/api/app-updates/{{target}}/{{arch}}/{{current_version}}"
        }

        platform::InstallMode::Prod => {
            "https://app.magendamd.com/api/app-updates/{{target}}/{{arch}}/{{current_version}}"
        }

        platform::InstallMode::Local => {
            "http://127.0.0.1:3000/api/app-updates/{{target}}/{{arch}}/{{current_version}}"
        }
    };

    let endpoint = endpoint
        .parse()
        .map_err(|e| {
            format!("Invalid updater endpoint: {e}")
        })?;

    let updater = app
        .updater_builder()
        .endpoints(vec![endpoint])
        .map_err(|e| e.to_string())?
        .build()
        .map_err(|e| e.to_string())?;

    let Some(update) = updater
        .check()
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(());
    };

    update
        .download_and_install(
            |_chunk_length, _content_length| {
                // при желании потом добавим progress channel
            },
            || {
                println!("Update download finished.");
            },
        )
        .await
        .map_err(|e| e.to_string())?;

    app.restart()
}

fn registration_error(code: i32) -> String {
    match code {
        10 => "Installation configuration is missing.",
        11 => "Installation configuration is invalid.",
        12 => "Registration password is missing.",
        13 => "Computer name is missing.",
        20 => "RustDesk ID is unavailable.",
        30 => "Cannot connect to the registration server.",
        31 => "The server rejected device registration.",
        40 => "Cannot read or save registration state.",
        41 => "Installation configuration changed. Please try again.",
        42 => "Cannot acquire the registration lock. Please try again.",
        _ => "Device registration failed.",
    }
    .to_owned()
}

#[tauri::command]
async fn get_registration_state(
) -> Result<Option<registration_state::RegistrationData>, String> {
    tauri::async_runtime::spawn_blocking(
        registration_state::current,
    )
    .await
    .map_err(|_| "Cannot read registration state.".to_owned())?
    .map_err(registration_error)
}

#[tauri::command]
async fn auto_register_device(
    config: Option<platform::InstallConfig>,
) -> Result<registration_state::RegistrationData, String> {
    tauri::async_runtime::spawn_blocking(move || {
        auto_register::register(None, config)
    })
    .await
    .map_err(|_| "Automatic registration failed.".to_owned())?
    .map_err(registration_error)
}

#[tauri::command]
async fn register_device(
    computer_name: String,
    token: String,
    mode: platform::InstallMode,
) -> Result<registration_state::RegistrationData, String> {
    tauri::async_runtime::spawn_blocking(move || {
        auto_register::register(
            Some(computer_name),
            Some(platform::InstallConfig {
                install_token: token,
                mode,
            }),
        )
    })
    .await
    .map_err(|_| "Device registration failed.".to_owned())?
    .map_err(registration_error)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let args: Vec<_> = std::env::args_os().collect();
    let auto_register = args.iter().any(|arg| arg == "--auto-register");
    let installer_request = if cfg!(target_os = "windows") {
        installer_launch::from_args(&args)
    } else {
        None
    };

    if auto_register && installer_request.is_none() {
        let exit_code = auto_register::run();

        if exit_code == 0 || !cfg!(target_os = "windows") {
            std::process::exit(exit_code);
        }

        // Preserve the legacy headless command. On Windows a failed registration
        // opens the GUI for retry; new NSIS launches use the hidden queue below.
    }

    let mut context = tauri::generate_context!();
    if installer_request.is_some() {
        // Run the frontend registration queue without displaying a window.
        // A failure or a manual deep link makes it visible; success closes it.
        for window in &mut context.config_mut().app.windows {
            window.visible = false;
        }
    }

    tauri::Builder::default()
        .manage(installer_launch::PendingLaunch::new(installer_request))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            // The deep-link feature forwards URLs to the running instance.
            if cfg!(target_os = "windows")
                && argv.iter().any(|arg| arg == "--auto-register")
            {
                use tauri::{Emitter, Manager};

                let args: Vec<_> = argv.iter().map(std::ffi::OsString::from).collect();
                if let Some(request) = installer_launch::from_args(&args) {
                    let pending = app.state::<installer_launch::PendingLaunch>();
                    let _ = pending.replace(request);
                    // The stored request covers the interval before the UI subscribes.
                    let _ = app.emit("installer-launch", ());
                    return;
                }

                // A failed NSIS registration may find an existing GUI instance.
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.unminimize();
                    let _ = window.set_focus();
                }
            }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            // get_install_token,
            get_install_config,
            initialize_install_config,
            save_install_config,
            get_rustdesk_id,
            get_rustdesk_status,
            get_rustdesk_permissions_status,
            configure_rustdesk,
            check_for_updates,
            download_and_install_update,
            open_rustdesk,
            open_accessibility_settings,
            open_screen_recording_settings,
            open_input_monitoring_settings,
            get_registration_state,
            register_device,
            auto_register_device,
            get_installer_launch,
            clear_installer_launch,
        ])
        .run(context)
        .expect("error while running tauri application");
}

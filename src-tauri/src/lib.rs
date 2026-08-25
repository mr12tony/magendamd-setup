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

mod platform;

#[tauri::command]
fn get_install_token()
    -> Result<Option<String>, String>
{
    platform::get_install_token()
}

#[tauri::command]
fn save_install_token(
    token: String,
) -> Result<(), String>
{
    platform::save_install_token(&token)
}

#[tauri::command]
fn get_rustdesk_id() -> Result<Option<String>, String> {
    platform::get_rustdesk_id()
}

#[tauri::command]
fn configure_rustdesk(app: tauri::AppHandle) -> Result<(), String> {
    platform::configure_rustdesk(&app)
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|_app, argv, _cwd| {
          println!("a new app instance was opened with {argv:?} and the deep link event was already triggered");
          // when defining deep link schemes at runtime, you must also check `argv` here
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        // .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            // get_install_token,
            get_install_token,
            save_install_token,
            get_rustdesk_id,
            get_rustdesk_status,
            get_rustdesk_permissions_status,
            configure_rustdesk,
            open_rustdesk,
            open_accessibility_settings,
            open_screen_recording_settings,
            open_input_monitoring_settings,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

use serde::Deserialize;
use std::path::PathBuf;

#[derive(Deserialize)]
struct InstallConfig {
    install_token: String,
}

fn install_config_path() -> Result<PathBuf, String> {
    let program_data = std::env::var("PROGRAMDATA")
        .map_err(|_| "PROGRAMDATA environment variable not found".to_string())?;

    Ok(
        PathBuf::from(program_data)
            .join("Magendamd")
            .join("install.json")
    )
}

#[tauri::command]
fn get_install_token() -> Result<String, String> {
    let path = install_config_path()?;

    let content = std::fs::read_to_string(&path)
        .map_err(|e| {
            format!(
                "Cannot read install config {}: {e}",
                path.display()
            )
        })?;

    let config: InstallConfig = serde_json::from_str(&content)
        .map_err(|e| format!("Invalid install config: {e}"))?;

    Ok(config.install_token)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            get_install_token,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

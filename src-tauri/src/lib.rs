use std::fs::OpenOptions;
use std::io::Write;

fn debug_log(message: impl AsRef<str>) {
    let Ok(exe_path) = std::env::current_exe() else {
        return;
    };

    let Some(exe_dir) = exe_path.parent() else {
        return;
    };

    #[cfg(target_os = "macos")]
    let log_dir = exe_dir
        .parent() // Contents
        .and_then(|p| p.parent()) // Magendamd.app
        .and_then(|p| p.parent()); // parent of .app

    #[cfg(target_os = "windows")]
    let log_dir = Some(exe_dir);

    let Some(log_dir) = log_dir else {
        return;
    };

    let log_path = log_dir.join("debug.log");

    let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    else {
        return;
    };

    let _ = writeln!(
        file,
        "{}",
        message.as_ref()
    );
}

#[tauri::command]
fn debug_log_command(message: String) -> Result<(), String> {
    debug_log(message);
    Ok(())
}

// #[tauri::command]
// fn get_current_exe() -> Result<String, String> {
//     std::env::current_exe()
//         .map(|path| path.to_string_lossy().to_string())
//         .map_err(|e| e.to_string())
// }

use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
struct AppConfig {
    token: String,
    password: String,
    api: String,
}

#[tauri::command]
fn get_config() -> Result<AppConfig, String> {
    let exe_path = std::env::current_exe()
        .map_err(|e| format!("Failed to get executable path: {e}"))?;

    let exe_dir = exe_path
        .parent()
        .ok_or_else(|| "Failed to get executable directory".to_string())?;

    #[cfg(target_os = "macos")]
    let config_dir = exe_dir
        .parent() // Contents
        .and_then(|p| p.parent()) // .app
        .and_then(|p| p.parent()) // directory next to .app
        .ok_or_else(|| "Failed to determine config directory".to_string())?;

    #[cfg(target_os = "windows")]
    let config_dir = exe_dir;

    let config_path = config_dir.join("config.json");

    println!("Config path: {}", config_path.display());

    let content = std::fs::read_to_string(&config_path)
        .map_err(|e| {
            format!(
                "Failed to read config.json at {}: {}",
                config_path.display(),
                e
            )
        })?;

    let config: AppConfig = serde_json::from_str(&content)
        .map_err(|e| {
            format!(
                "Failed to parse config.json at {}: {}",
                config_path.display(),
                e
            )
        })?;

    if config.token.trim().is_empty() {
        return Err("config.json: token is empty".to_string());
    }

    if config.password.trim().is_empty() {
        return Err("config.json: password is empty".to_string());
    }

    if config.api.trim().is_empty() {
        return Err("config.json: config is empty".to_string());
    }

    Ok(config)
}

// #[tauri::command]
// fn get_access_token() -> Result<String, String> {
//     let exe_path =
//         std::env::current_exe().map_err(|e| format!("Failed to get executable path: {e}"))?;

//     let exe_dir = exe_path
//         .parent()
//         .ok_or_else(|| "Failed to get executable directory".to_string())?;

//     #[cfg(target_os = "macos")]
//     let token_dir = exe_dir
//         .parent() // Contents
//         .and_then(|p| p.parent()) // magendamd-setup.app
//         .and_then(|p| p.parent()) // directory next to .app
//         .ok_or_else(|| "Failed to determine token directory".to_string())?;

//     #[cfg(target_os = "windows")]
//     let token_dir = exe_dir;

//     let token_path = token_dir.join("access-token.txt");

//     println!("Access token path: {}", token_path.display());

//     let token = std::fs::read_to_string(&token_path)
//         .map_err(|e| {
//             format!(
//                 "Failed to read access-token.txt at {}: {}",
//                 token_path.display(),
//                 e
//             )
//         })?
//         .trim()
//         .to_string();

//     if token.is_empty() {
//         return Err("access-token.txt is empty".to_string());
//     }

//     Ok(token)
// }

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // .plugin(
        //     tauri_plugin_log::Builder::new()
        //         .level(tauri_plugin_log::log::LevelFilter::Info)
        //         .target(
        //             tauri_plugin_log::Target::new(
        //                 tauri_plugin_log::TargetKind::LogDir {
        //                     file_name: Some("logs".to_string()),
        //                 },
        //             ),
        //         )
        //         .build(),
        // )
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            // get_current_exe,
            // get_access_token,
            get_config,
            debug_log_command,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

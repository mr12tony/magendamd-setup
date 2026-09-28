use crate::platform;
use crate::registration_state::{self, RegistrationData};

use reqwest::{
    blocking::Client,
    header::{HeaderMap, HeaderValue},
};

use std::{thread, time::Duration};

// Файл создаётся build.rs при сборке.
// Значение не выводится в логи.
const REGISTRATION_PASSWORD: &str = include_str!(
    concat!(env!("OUT_DIR"), "/registration-password.txt")
);

pub fn run() -> i32 {
    match register(None) {
        Ok(_) => 0,
        Err(code) => code,
    }
}

pub fn register(
    requested_name: Option<String>,
) -> Result<RegistrationData, i32> {
    let _registration_lock = registration_state::lock()?;

    let config = platform::get_install_config()
        .map_err(|_| 11)?;

    let Some(config) = config else {
        return Err(10);
    };

    let token = config.install_token.trim();

    if token.is_empty() {
        return Err(11);
    }

    if REGISTRATION_PASSWORD.is_empty() {
        return Err(12);
    }

    let rustdesk_id = wait_for_rustdesk_id()?;

    let context = registration_state::context_hash(
        &config,
        &rustdesk_id,
    )?;

    let saved_registration = registration_state::read(&context)?;

    // Headless: если эта установка уже зарегистрирована,
    // повторный POST не нужен.
    if requested_name.is_none() {
        if let Some(saved) = saved_registration {
            return Ok(saved);
        }
    }

    let computer_name = match requested_name {
        Some(name) => {
            let name = name.trim().to_owned();

            if name.is_empty() {
                return Err(13);
            }

            name
        }

        None => hostname::get()
            .map_err(|_| 13)?
            .into_string()
            .map_err(|_| 13)?
            .trim()
            .to_owned(),
    };

    if computer_name.is_empty() {
        return Err(13);
    }

    let backend_url = match config.mode {
        platform::InstallMode::Dev => {
            "https://apidev.magendamd.com/api/v1"
        }

        platform::InstallMode::Prod => {
            "https://api.magendamd.com/api/v1"
        }

        platform::InstallMode::Local => {
            "http://127.0.0.1:8000/api/v1"
        }
    };

    let mut key = HeaderValue::from_str(token)
        .map_err(|_| 11)?;

    key.set_sensitive(true);

    let mut headers = HeaderMap::new();
    headers.insert("X-RustDesk-Key", key);

    let client = Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| 30)?;

    let response = client
        .post(format!("{backend_url}/rustdesk/devices"))
        .headers(headers)
        .json(&serde_json::json!({
            "device_id": rustdesk_id,
            "password": REGISTRATION_PASSWORD,
            "name": computer_name,
        }))
        .send()
        .map_err(|_| 30)?;

    if !response.status().is_success() {
        return Err(31);
    }

    // Config мог измениться через deep link, пока выполнялся POST.
    // В таком случае не сохраняем старую регистрацию как текущую.
    let latest_config = platform::get_install_config()
        .map_err(|_| 41)?
        .ok_or(41)?;

    let latest_context = registration_state::context_hash(
        &latest_config,
        &rustdesk_id,
    )?;

    if latest_context != context {
        return Err(41);
    }

    let registration = RegistrationData {
        registered: true,
        current_rustdesk_id: rustdesk_id,
        computer_name,
        registered_at: chrono::Utc::now().to_rfc3339(),
    };

    registration_state::save(
        context,
        registration.clone(),
    )?;

    Ok(registration)
}

fn wait_for_rustdesk_id() -> Result<String, i32> {
    const ATTEMPTS: usize = 12;

    for attempt in 0..ATTEMPTS {
        if let Ok(Some(id)) = platform::get_rustdesk_id_headless() {
            let id = id.trim();

            if !id.is_empty() {
                return Ok(id.to_owned());
            }
        }

        if attempt + 1 < ATTEMPTS {
            thread::sleep(Duration::from_secs(2));
        }
    }

    Err(20)
}
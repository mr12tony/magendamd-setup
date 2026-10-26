use crate::platform;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{ErrorKind, Write},
    path::{Path, PathBuf},
};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistrationData {
    pub registered: bool,
    pub current_rustdesk_id: String,
    pub computer_name: String,
    pub registered_at: String,
}

#[derive(Serialize, Deserialize)]
struct StoredRegistration {
    version: u32,
    context_hash: String,
    registration: RegistrationData,
}

fn directory() -> Result<PathBuf, i32> {
    #[cfg(target_os = "windows")]
    {
        let base = env::var_os("LOCALAPPDATA").ok_or(40)?;
        Ok(PathBuf::from(base).join("MagendaSupport"))
    }

    #[cfg(target_os = "macos")]
    {
        let home = env::var_os("HOME").ok_or(40)?;

        Ok(PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("MagendaSupport"))
    }
}

pub fn context_hash(
    config: &platform::InstallConfig,
    rustdesk_id: &str,
) -> Result<String, i32> {
    let context = serde_json::to_vec(&(
        config.install_token.trim(),
        &config.mode,
        rustdesk_id.trim(),
    ))
    .map_err(|_| 40)?;

    Ok(format!("{:x}", Sha256::digest(context)))
}

// Возвращённый File держит блокировку до конца своего scope.
// Файл registration.lock удалять не нужно.
pub fn lock() -> Result<File, i32> {
    lock_in(&directory()?)
}

fn lock_in(directory: &Path) -> Result<File, i32> {
    fs::create_dir_all(directory).map_err(|_| 40)?;

    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(directory.join("registration.lock"))
        .map_err(|_| 40)?;

    // GUI commands run in spawn_blocking. Wait for headless registration
    // instead of losing the manual request while another process holds the lock.
    fs2::FileExt::lock_exclusive(&file).map_err(|_| 42)?;

    Ok(file)
}

pub fn read(
    expected_context: &str,
) -> Result<Option<RegistrationData>, i32> {
    let path = directory()?.join("registration.json");

    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Ok(None);
        }
        Err(_) => return Err(40),
    };

    // Повреждённый или устаревший файл не подтверждает регистрацию.
    let stored: StoredRegistration = match serde_json::from_slice(&bytes) {
        Ok(stored) => stored,
        Err(_) => return Ok(None),
    };

    if stored.version != 1
        || stored.context_hash != expected_context
        || !stored.registration.registered
    {
        return Ok(None);
    }

    Ok(Some(stored.registration))
}

pub fn save(
    context_hash: String,
    registration: RegistrationData,
) -> Result<(), i32> {
    let directory = directory()?;

    fs::create_dir_all(&directory).map_err(|_| 40)?;

    let stored = StoredRegistration {
        version: 1,
        context_hash,
        registration,
    };

    let bytes = serde_json::to_vec_pretty(&stored)
        .map_err(|_| 40)?;

    let mut temporary = tempfile::NamedTempFile::new_in(&directory)
        .map_err(|_| 40)?;

    temporary
        .write_all(&bytes)
        .and_then(|_| temporary.as_file().sync_all())
        .map_err(|_| 40)?;

    temporary
        .persist(directory.join("registration.json"))
        .map_err(|_| 40)?;

    Ok(())
}

pub fn current() -> Result<Option<RegistrationData>, i32> {
    let Some(config) = platform::get_install_config()
        .map_err(|_| 11)?
    else {
        return Ok(None);
    };

    let Some(id) = platform::get_rustdesk_id_headless()
        .map_err(|_| 20)?
    else {
        return Ok(None);
    };

    if id.trim().is_empty() {
        return Ok(None);
    }

    let context = context_hash(&config, &id)?;

    read(&context)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{process::{Command, Stdio}, thread, time::{Duration, Instant}};

    #[test]
    fn registration_lock_waits_for_another_process() {
        const CHILD_DIRECTORY: &str = "MAGENDA_REGISTRATION_LOCK_TEST_DIRECTORY";

        // The child runs this same test with an isolated directory, never user data.
        if let Some(directory) = env::var_os(CHILD_DIRECTORY) {
            let directory = PathBuf::from(directory);
            fs::write(directory.join("started"), b"").unwrap();
            let _lock = lock_in(&directory).expect("wait for the parent's registration");
            fs::write(directory.join("acquired"), b"").unwrap();
            return;
        }

        let directory = tempfile::tempdir().unwrap();
        let held = lock_in(directory.path()).unwrap();
        let mut child = Command::new(env::current_exe().unwrap())
            .args(["--exact", "registration_state::tests::registration_lock_waits_for_another_process"])
            .env(CHILD_DIRECTORY, directory.path())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();

        let started = directory.path().join("started");
        let deadline = Instant::now() + Duration::from_secs(5);
        while !started.exists() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        thread::sleep(Duration::from_millis(100));
        let exited_while_locked = child.try_wait().unwrap().is_some();
        let acquired_while_locked = directory.path().join("acquired").exists();
        drop(held);

        let deadline = Instant::now() + Duration::from_secs(5);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("registration did not resume after the lock was released");
            }
            thread::sleep(Duration::from_millis(10));
        };

        assert!(started.exists());
        assert!(!exited_while_locked, "a waiting registration must not fail as busy");
        assert!(!acquired_while_locked, "registrations must not overlap");
        assert!(status.success());
        assert!(directory.path().join("acquired").exists());
    }
}

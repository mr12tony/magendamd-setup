use std::{
    io::{Read, Seek, SeekFrom},
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub(super) fn get_id(
    executable: &str,
) -> Result<Option<String>, String> {
    if !Path::new(executable).is_file() {
        return Ok(None);
    }

    let failure = || "RustDesk ID probe failed".to_owned();

    // stdout направлен в файл, чтобы заполненный pipe
    // не заблокировал дочерний процесс.
    let mut output = tempfile::tempfile()
        .map_err(|_| failure())?;

    let stdout = output.try_clone()
        .map_err(|_| failure())?;

    let mut command = Command::new(executable);

    command
        .arg("--get-id")
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::null());

    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;

        // CREATE_NO_WINDOW
        command.creation_flags(0x08000000);
    }

    let mut child = command.spawn()
        .map_err(|_| failure())?;

    let started = Instant::now();

    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,

            Ok(None)
                if started.elapsed() < Duration::from_secs(3) =>
            {
                thread::sleep(Duration::from_millis(50));
            }

            _ => {
                let _ = child.kill();
                let _ = child.wait();

                return Err(failure());
            }
        }
    };

    if !status.success() {
        return Ok(None);
    }

    output
        .seek(SeekFrom::Start(0))
        .map_err(|_| failure())?;

    let mut bytes = Vec::new();

    output
        .take(4097)
        .read_to_end(&mut bytes)
        .map_err(|_| failure())?;

    if bytes.len() > 4096 {
        return Err(failure());
    }

    let id = String::from_utf8(bytes)
        .map_err(|_| failure())?;

    let id = id.trim();

    Ok((!id.is_empty()).then(|| id.to_owned()))
}
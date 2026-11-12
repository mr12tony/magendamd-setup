//! Shared file format and lock location for registration and the standalone uninstaller.
use std::{
    fs::{self, File, OpenOptions},
    io::ErrorKind,
    path::Path,
};

pub(crate) fn clear_files_in(directory: &Path) -> Result<(), i32> {
    remove_if_exists(&directory.join("install.json"))?;
    remove_if_exists(&directory.join("registration.json"))
}

fn remove_if_exists(path: &Path) -> Result<(), i32> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(_) => Err(40),
    }
}

pub(crate) fn open_lock_in(directory: &Path) -> Result<File, i32> {
    fs::create_dir_all(directory).map_err(|_| 40)?;
    OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(directory.join("registration.lock"))
        .map_err(|_| 40)
}

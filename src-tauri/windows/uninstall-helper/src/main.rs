//! Embedded in the NSIS uninstaller; independent of the installed app and WebView.
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(any(windows, test))]
mod cleanup;
#[cfg(any(windows, test))]
mod options;
#[cfg(any(windows, test))]
#[path = "../../../src/registration_files.rs"]
mod registration_files;
#[cfg(windows)]
mod windows;

fn main() {
    #[cfg(windows)]
    let result = options::Options::parse(std::env::args_os().skip(1))
        .and_then(|options| windows::clear_user_data(&options));
    #[cfg(not(windows))]
    let result: Result<(), i32> = Err(43);

    std::process::exit(result.err().unwrap_or(0));
}

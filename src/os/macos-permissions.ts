import { Command } from "@tauri-apps/plugin-shell";

async function openSettings(url: string) {
  await Command.create("open", [url]).execute();
}

/**
 * Общий раздел Privacy & Security
 */
export async function openPrivacySecurity() {
  await openSettings(
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
  );
}

/**
 * Accessibility
 */
export async function openAccessibility() {
  await openSettings(
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
  );
}

/**
 * Screen Recording
 */
export async function openScreenRecording() {
  await openSettings(
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
  );
}

/**
 * Microphone
 */
export async function openMicrophone() {
  await openSettings(
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
  );
}

/**
 * Camera
 */
export async function openCamera() {
  await openSettings(
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
  );
}

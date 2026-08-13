import { invoke } from "@tauri-apps/api/core";

export async function debugLog(message: string) {
  await invoke("debug_log_command", {
    message,
  });
}

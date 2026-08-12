import { invoke } from "@tauri-apps/api/core";

export async function debugLog(message: string) {
  const timestamp = new Date().toISOString();

  try {
    await invoke("write_debug_log", {
      message: `[${timestamp}] ${message}`,
    });
  } catch {
    // Не ломаем приложение из-за ошибки логирования
  }
}

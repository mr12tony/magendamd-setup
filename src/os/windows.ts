import { exists } from "@tauri-apps/plugin-fs";

export const RUSTDESK_PATH = "C:\\Program Files\\RustDesk\\RustDesk.exe";

export async function getRustDeskPath(): Promise<string | null> {
  const installed = await exists(RUSTDESK_PATH);

  return installed ? RUSTDESK_PATH : null;
}

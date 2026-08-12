import { exists } from "@tauri-apps/plugin-fs";

export const RUSTDESK_APP_PATH = "/Applications/RustDesk.app";

export const RUSTDESK_PATH =
  "/Applications/RustDesk.app/Contents/MacOS/RustDesk";

export async function getRustDeskPath(): Promise<string | null> {
  const installed = await exists(RUSTDESK_PATH);

  return installed ? RUSTDESK_PATH : null;
}

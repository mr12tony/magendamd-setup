import { hostname } from "@tauri-apps/plugin-os";

export async function getSystemInfo() {
  const computerName = await hostname();

  return {
    hostname: computerName,
  };
}

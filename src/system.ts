import { hostname } from "@tauri-apps/plugin-os";
import { Command } from "@tauri-apps/plugin-shell";

export async function getSystemInfo() {
  const computerName = await hostname();

  const result = await Command.create("whoami").execute();

  const username = result.stdout.trim();

  return {
    hostname: computerName,
    username,
  };
}

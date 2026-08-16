import { platform, arch } from "@tauri-apps/plugin-os";
import { resolveResource } from "@tauri-apps/api/path";
import { dirname, join } from "@tauri-apps/api/path";
import { invoke } from "@tauri-apps/api/core";

export async function getEmbeddedRustDesk(): Promise<string> {
  const os = platform();
  const cpu = arch();

  // if (os === "windows") {
  //   if (cpu === "aarch64") {
  //     return await resolveResource("resources/windows/rustdesk-aarch64.exe");
  //   }

  //   return await resolveResource("resources/windows/rustdesk-x86_64.exe");
  // }

  // if (os === "macos") {
  if (cpu === "aarch64") {
    return await resolveResource("resources/macos/rustdesk-aarch64.dmg");
  }

  // return
  await resolveResource("resources/macos/rustdesk-x86_64.dmg");
  // }

  throw new Error(`Unsupported OS: ${os}`);
}

export async function getRustDeskInstallerPath(): Promise<string> {
  const exePath = await invoke<string>("get_current_exe");
  const appDir = await dirname(exePath);
  const architecture = arch();

  let filename: string;

  switch (architecture) {
    case "x86_64":
      filename = "rustdesk-x86_64.exe";
      break;

    case "aarch64":
      filename = "rustdesk-aarch64.exe";
      break;

    default:
      throw new Error(`Unsupported Windows architecture: ${architecture}`);
  }

  return join(appDir, "resources", "windows", filename);
}

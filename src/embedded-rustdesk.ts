import { platform, arch } from "@tauri-apps/plugin-os";
import { resolveResource } from "@tauri-apps/api/path";

export async function getEmbeddedRustDesk(): Promise<string> {
  const os = platform();
  const cpu = arch();

  if (os === "windows") {
    if (cpu === "aarch64") {
      return await resolveResource("resources/windows/rustdesk-aarch64.exe");
    }

    return await resolveResource("resources/windows/rustdesk-x86_64.exe");
  }

  if (os === "macos") {
    if (cpu === "aarch64") {
      return await resolveResource("resources/macos/rustdesk-aarch64.dmg");
    }

    return await resolveResource("resources/macos/rustdesk-x86_64.dmg");
  }

  throw new Error(`Unsupported OS: ${os}`);
}

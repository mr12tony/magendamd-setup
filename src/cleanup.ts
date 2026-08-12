import { platform } from "@tauri-apps/plugin-os";
import { cleanupMacOS } from "./os/macos-cleanup";
import { cleanupWindows } from "./os/windows-cleanup";

export async function cleanupInstaller(): Promise<void> {
  const os = platform();

  if (os === "macos") {
    await cleanupMacOS();
    return;
  }

  if (os === "windows") {
    await cleanupWindows();
    return;
  }

  throw new Error(`Unsupported OS: ${os}`);
}

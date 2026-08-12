import { platform } from "@tauri-apps/plugin-os";

import * as macos from "./macos";
import * as windows from "./windows";

export async function getRustDeskPath(): Promise<string | null> {
  const os = platform();

  if (os === "macos") {
    return macos.getRustDeskPath();
  }

  if (os === "windows") {
    return windows.getRustDeskPath();
  }

  return null;
}

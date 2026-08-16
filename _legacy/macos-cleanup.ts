import { Command } from "@tauri-apps/plugin-shell";
import { executableDir } from "@tauri-apps/api/path";

export async function cleanupMacOS(): Promise<void> {
  const dir = await executableDir();

  // Например:
  // /Users/user/Downloads/MagendaSetup.app/Contents/MacOS/
  //
  // Поднимаемся:
  // MacOS -> Contents -> MagendaSetup.app

  const appPath = dir.replace(/\/Contents\/MacOS\/?$/, "");

  console.log("Installer app:", appPath);

  await Command.create("sh", [
    "-c",
    `
sleep 2
rm -rf "$1"
`,
    "cleanup",
    appPath,
  ]).execute();
}

import { Command } from "@tauri-apps/plugin-shell";
import { executableDir } from "@tauri-apps/api/path";

export async function cleanupWindows(): Promise<void> {
  const dir = await executableDir();

  // Например:
  // C:\Users\User\Downloads\MagendaSetup\

  const exePath = `${dir}magendamd-setup.exe`;

  console.log("Installer exe:", exePath);

  await Command.create("cmd", [
    "/C",
    `start "" /B cmd /C "timeout /t 2 /nobreak >nul & del /F /Q "${exePath}""`,
  ]).execute();
}

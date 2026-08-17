import { Command } from "@tauri-apps/plugin-shell";
import { resolveResource } from "@tauri-apps/api/path";
import { platform } from "@tauri-apps/plugin-os";
// import { exists } from "@tauri-apps/plugin-fs";
import { debugLog } from "./debugLog";
// import { sleep } from "./sleep";

type AppConfig = {
  config: string;
  password: string;
};

export const RUSTDESK_WINDOWS_PATH =
  "C:\\Program Files\\RustDesk\\RustDesk.exe";
export const RUSTDESK_MACOS_PATH = "/Applications/RustDesk.app";

export async function installRustDeskMacOS(config: AppConfig): Promise<void> {
  const script = await resolveResource("resources/macos/install.sh");

  await debugLog(`macOS installer: ${script}`);

  const result = await Command.create("bash", [
    script,
    config.password,
    config.config,
  ]).execute();

  await debugLog(
    `macOS installer exit=${result.code}\n` +
      `stdout=${result.stdout}\n` +
      `stderr=${result.stderr}`,
  );

  if (result.code !== 0) {
    throw new Error(
      result.stderr ||
        result.stdout ||
        `macOS RustDesk installer failed: ${result.code}`,
    );
  }
}

export async function installRustDeskWindows(config: AppConfig): Promise<void> {
  const script = await resolveResource("resources/windows/install.ps1");

  await debugLog(`Windows installer: ${script}`);

  const result = await Command.create("powershell", [
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-WindowStyle",
    "Hidden",
    "-File",
    script,
    config.password,
    config.config,
  ]).execute();

  await debugLog(
    `Windows installer exit=${result.code}\n` +
      `stdout=${result.stdout}\n` +
      `stderr=${result.stderr}`,
  );

  if (result.code !== 0) {
    throw new Error(
      result.stderr ||
        result.stdout ||
        `Windows RustDesk installer failed: ${result.code}`,
    );
  }
}

export async function installRustDesk(config: AppConfig): Promise<void> {
  const os = platform();

  if (os === "macos") {
    await installRustDeskMacOS(config);
    return;
  }

  if (os === "windows") {
    await installRustDeskWindows(config);
    return;
  }

  throw new Error(`Unsupported OS: ${os}`);
}

// export async function uninstallRustDesk(): Promise<void> {
//   const os = platform();

//   if (os === "windows") {
//     await uninstallRustDeskWindows();
//     return;
//   }

//   if (os === "macos") {
//     await uninstallRustDeskMacOS();
//     return;
//   }

//   throw new Error(`Unsupported OS: ${os}`);
// }

// ─────────────────────────────────────────────
// Windows
// ─────────────────────────────────────────────

// async function uninstallRustDeskWindows(): Promise<void> {
//   console.log("=== Windows RustDesk uninstall ===");

//   const psCommand =
//     `Start-Process ` +
//     `-FilePath '${RUSTDESK_WINDOWS_PATH.replace(/'/g, "''")}' ` +
//     `-ArgumentList '--uninstall' ` +
//     `-Verb RunAs`;

//   console.log("Uninstall command:", psCommand);

//   const result = await Command.create("powershell", [
//     "-NoProfile",
//     "-NonInteractive",
//     "-ExecutionPolicy",
//     "Bypass",
//     "-Command",
//     psCommand,
//   ]).execute();

//   console.log("PowerShell exit:", result.code);
//   console.log("stdout:", result.stdout);
//   console.log("stderr:", result.stderr);

//   if (result.code !== 0) {
//     throw new Error(
//       result.stderr || result.stdout || "Failed to start RustDesk uninstall",
//     );
//   }

//   // Ждём фактического удаления RustDesk.exe
//   for (let i = 0; i < 30; i++) {
//     const installed = await exists(RUSTDESK_WINDOWS_PATH);

//     if (!installed) {
//       console.log("RustDesk successfully removed");
//       return;
//     }

//     await sleep(1000);
//   }

//   throw new Error(
//     "RustDesk uninstall started, but RustDesk.exe is still present",
//   );
// }

// ─────────────────────────────────────────────
// macOS
// ─────────────────────────────────────────────

// async function uninstallRustDeskMacOS(): Promise<void> {
//   console.log("=== macOS RustDesk uninstall ===");

//   // Останавливаем RustDesk.
//   // Если он не запущен — это нормально.
//   try {
//     const result = await Command.create("killall", ["RustDesk"]).execute();

//     console.log("killall exit:", result.code);
//   } catch {
//     console.log("RustDesk was not running");
//   }

//   await sleep(500);

//   const result = await Command.create("rm", [
//     "-rf",
//     RUSTDESK_MACOS_PATH,
//   ]).execute();

//   console.log("rm exit:", result.code);
//   console.log("stdout:", result.stdout);
//   console.log("stderr:", result.stderr);

//   if (result.code !== 0) {
//     throw new Error(result.stderr || "Failed to uninstall RustDesk on macOS");
//   }

//   // Проверяем, что приложение действительно удалено
//   for (let i = 0; i < 10; i++) {
//     const installed = await exists(RUSTDESK_MACOS_PATH);

//     if (!installed) {
//       console.log("RustDesk successfully removed");
//       return;
//     }

//     await sleep(500);
//   }

//   throw new Error(
//     "RustDesk uninstall finished, but RustDesk.app is still present",
//   );
// }

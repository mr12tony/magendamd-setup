import { Command } from "@tauri-apps/plugin-shell";
import { platform } from "@tauri-apps/plugin-os";
import { exists } from "@tauri-apps/plugin-fs";
import {
  getEmbeddedRustDesk,
  getRustDeskInstallerPath,
} from "./embedded-rustdesk";
import { RUSTDESK_APP_PATH as MACOS_RUSTDESK_PATH } from "./os/macos";
// import { RUSTDESK_PATH as WINDOWS_RUSTDESK_PATH } from "./os/windows";

export async function installRustDesk(): Promise<void> {
  const os = platform();

  if (os === "macos") {
    const installer = await getEmbeddedRustDesk();

    await installMacOS(installer);
    return;
  }

  if (os === "windows") {
    await installWindows();
    return;
  }

  throw new Error(`Unsupported OS: ${os}`);
}

// ─────────────────────────────────────────────
// macOS INSTALL
// ─────────────────────────────────────────────

async function installMacOS(dmg: string): Promise<void> {
  console.log("Installing RustDesk from:", dmg);

  const mountResult = await Command.create("hdiutil", [
    "attach",
    dmg,
    "-nobrowse",
    "-plist",
  ]).execute();

  if (mountResult.code !== 0) {
    throw new Error(mountResult.stderr || "Failed to mount RustDesk DMG");
  }

  const volumePath = extractMountPoint(mountResult.stdout);

  if (!volumePath) {
    throw new Error("Could not determine mounted DMG path");
  }

  console.log("Mounted:", volumePath);

  try {
    // Удаляем старую установку
    await Command.create("rm", ["-rf", MACOS_RUSTDESK_PATH]).execute();

    // Копируем новую
    const copyResult = await Command.create("ditto", [
      `${volumePath}/RustDesk.app`,
      MACOS_RUSTDESK_PATH,
    ]).execute();

    if (copyResult.code !== 0) {
      throw new Error(copyResult.stderr || "Failed to copy RustDesk.app");
    }

    console.log("RustDesk installed:", MACOS_RUSTDESK_PATH);
  } finally {
    const unmountResult = await Command.create("hdiutil", [
      "detach",
      volumePath,
    ]).execute();

    if (unmountResult.code !== 0) {
      console.warn("Failed to unmount DMG:", unmountResult.stderr);
    }
  }
}

// ─────────────────────────────────────────────
// WINDOWS INSTALL
// ─────────────────────────────────────────────

// async function installWindows(exe: string): Promise<void> {
//   console.log("Installing RustDesk from:", exe);

//   const command = Command.create("windows-installer", [
//     "/C",
//     `"${exe}" --silent-install`,
//   ]);

//   const result = await command.execute();

//   console.log("Installer exit code:", result.code);
//   console.log("Installer stdout:", result.stdout);
//   console.log("Installer stderr:", result.stderr);

//   if (result.code !== 0) {
//     throw new Error(result.stderr || "RustDesk installation failed");
//   }

//   console.log("RustDesk installed");
// }

// async function installWindows(): Promise<void> {
//   const exe = await getRustDeskInstallerPath();

//   console.log("Installing RustDesk from:", exe);

//   const command = Command.create("windows-installer", [
//     "/C",
//     `"${exe}" --silent-install`,
//   ]);

//   const result = await command.execute();

//   console.log("Installer exit code:", result.code);
//   console.log("stdout:", result.stdout);
//   console.log("stderr:", result.stderr);

//   if (result.code !== 0) {
//     throw new Error(
//       result.stderr || result.stdout || "RustDesk installation failed",
//     );
//   }

//   console.log("RustDesk installed");
// }

async function installWindows(): Promise<void> {
  const exe = await getRustDeskInstallerPath();

  console.log("RustDesk path:", exe);

  if (!(await exists(exe))) {
    throw new Error(`RustDesk executable not found: ${exe}`);
  }

  const psCommand =
    `Start-Process ` +
    `-FilePath '${exe.replace(/'/g, "''")}' ` +
    `-ArgumentList '--silent-install' ` +
    `-Verb RunAs ` +
    `-Wait`;

  console.log("PowerShell command:", psCommand);

  const command = Command.create("powershell", [
    "-NoProfile",
    "-NonInteractive",
    "-Command",
    psCommand,
  ]);

  const result = await command.execute();

  console.log("exit:", result.code);
  console.log("stdout:", result.stdout);
  console.log("stderr:", result.stderr);

  if (result.code !== 0) {
    throw new Error(
      result.stderr || result.stdout || "RustDesk installation failed",
    );
  }

  console.log("RustDesk installed successfully");
}

// ─────────────────────────────────────────────
// UNINSTALL
// ─────────────────────────────────────────────

export async function uninstallRustDesk(): Promise<void> {
  const os = platform();

  if (os === "macos") {
    await uninstallMacOS();
    return;
  }

  if (os === "windows") {
    await uninstallWindows();
    return;
  }

  throw new Error(`Unsupported OS: ${os}`);
}

// ─────────────────────────────────────────────
// macOS UNINSTALL
// ─────────────────────────────────────────────

async function uninstallMacOS(): Promise<void> {
  // RustDesk может быть запущен.
  // Если процесса нет — игнорируем ошибку.

  try {
    await Command.create("killall", ["RustDesk"]).execute();
  } catch {
    // RustDesk не запущен
  }

  const result = await Command.create("rm", [
    "-rf",
    MACOS_RUSTDESK_PATH,
  ]).execute();

  if (result.code !== 0) {
    throw new Error(result.stderr || "Failed to uninstall RustDesk on macOS");
  }

  console.log("RustDesk removed from macOS");
}

// ─────────────────────────────────────────────
// WINDOWS UNINSTALL
// ─────────────────────────────────────────────

async function uninstallWindows(): Promise<void> {
  const result = await Command.create("rustdesk-windows", [
    "--uninstall",
  ]).execute();

  if (result.code !== 0) {
    throw new Error(result.stderr || "Failed to uninstall RustDesk on Windows");
  }

  console.log("RustDesk removed from Windows");
}

// ─────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────

function extractMountPoint(output: string): string | null {
  const match = output.match(
    /<key>mount-point<\/key>\s*<string>(.*?)<\/string>/,
  );

  return match?.[1] ?? null;
}

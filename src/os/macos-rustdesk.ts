import { Command } from "@tauri-apps/plugin-shell";
import { exists } from "@tauri-apps/plugin-fs";
import { arch } from "@tauri-apps/plugin-os";
import { resolveResource } from "@tauri-apps/api/path";
import { debugLog } from "../debugLog";
import { sleep } from "../sleep";

export const RUSTDESK_MACOS_PATH =
  "/Applications/RustDesk.app/Contents/MacOS/RustDesk";

/**
 * Запускает RustDesk CLI напрямую.
 */
async function runRustDesk(args: string[]) {
  await debugLog(`RustDesk command: ${args.join(" ")}`);

  const result = await Command.create("rustdesk-macos", args).execute();

  await debugLog(
    `RustDesk exit=${result.code}\nstdout=${result.stdout}\nstderr=${result.stderr}`,
  );

  if (result.code !== 0) {
    throw new Error(
      result.stderr ||
        result.stdout ||
        `RustDesk failed with code ${result.code}`,
    );
  }

  return result;
}

/**
 * Проверка установки.
 */
export async function isRustDeskInstalledMacOS(): Promise<boolean> {
  const installed = await exists(RUSTDESK_MACOS_PATH);

  await debugLog(`isRustDeskInstalledMacOS: ${installed}`);

  return installed;
}

/**
 * Ждём появления RustDesk.
 */
export async function waitForRustDeskMacOS(timeoutMs = 30000): Promise<void> {
  await debugLog("Waiting for RustDesk macOS...");

  const started = Date.now();

  while (Date.now() - started < timeoutMs) {
    if (await exists(RUSTDESK_MACOS_PATH)) {
      await debugLog("RustDesk macOS found");
      return;
    }

    await sleep(500);
  }

  throw new Error(`RustDesk was not found after ${timeoutMs}ms`);
}

/**
 * Запускает RustDesk server/backend.
 *
 * Аналог:
 *
 * ./RustDesk --server &
 */
export async function startRustDeskServerMacOS(): Promise<void> {
  await debugLog("=== Start RustDesk server ===");

  // Не используем --Wait.
  await Command.create("rustdesk-macos", ["--server"]).execute();

  await debugLog("RustDesk server command executed");

  await sleep(1000);
}

/**
 * Устанавливает permanent password.
 */
export async function setRustDeskPasswordMacOS(
  password: string,
): Promise<void> {
  await debugLog("=== Set RustDesk password ===");

  await startRustDeskServerMacOS();

  await runRustDesk(["--password", password]);

  await debugLog("RustDesk password configured");
}

/**
 * Применяет RustDesk config.
 */
export async function configureRustDeskMacOS(
  configString: string,
): Promise<void> {
  await debugLog("=== Configure RustDesk ===");

  await runRustDesk(["--config", configString]);

  await debugLog("RustDesk config applied");
}

/**
 * Получает RustDesk ID.
 */
export async function getRustDeskIdMacOS(): Promise<string | null> {
  await debugLog("=== Get RustDesk ID ===");

  await waitForRustDeskMacOS();

  const result = await runRustDesk(["--get-id"]);

  const id = result.stdout.trim();

  await debugLog(`RustDesk ID: ${id}`);

  return id || null;
}

/**
 * Убивает RustDesk processes.
 *
 * Аналог:
 *
 * rdpid=$(pgrep RustDesk)
 * kill $rdpid
 */
export async function killRustDeskMacOS(): Promise<void> {
  await debugLog("=== Kill RustDesk macOS ===");

  try {
    const result = await Command.create("killall", ["RustDesk"]).execute();

    await debugLog(
      `killall RustDesk exit=${result.code}\n` +
        `stdout=${result.stdout}\n` +
        `stderr=${result.stderr}`,
    );
  } catch (error) {
    await debugLog(`RustDesk was not running: ${String(error)}`);
  }
}

/**
 * Перезапуск RustDesk.
 */
export async function restartRustDeskMacOS(): Promise<void> {
  await debugLog("=== Restart RustDesk macOS ===");

  await killRustDeskMacOS();

  await sleep(1000);

  const result = await Command.create("open", [
    "-n",
    "/Applications/RustDesk.app",
  ]).execute();

  await debugLog(
    `open RustDesk exit=${result.code}\n` +
      `stdout=${result.stdout}\n` +
      `stderr=${result.stderr}`,
  );

  if (result.code !== 0) {
    throw new Error(result.stderr || "Failed to start RustDesk");
  }

  await debugLog("RustDesk restarted");
}

/**
 * Полная настройка RustDesk.
 */
export async function setupRustDeskMacOS(params: {
  password: string;
  configString?: string;
}): Promise<string> {
  await debugLog("==============================");
  await debugLog("=== FULL macOS RUSTDESK SETUP ===");
  await debugLog("==============================");

  await waitForRustDeskMacOS();

  await startRustDeskServerMacOS();

  if (params.configString) {
    await configureRustDeskMacOS(params.configString);
  }

  await setRustDeskPasswordMacOS(params.password);

  const id = await getRustDeskIdMacOS();

  if (!id) {
    throw new Error("Failed to get RustDesk ID");
  }

  await debugLog(`FULL macOS SETUP SUCCESS. ID=${id}`);

  return id;
}

export async function getRustDeskInstallerPathMacOS(): Promise<string> {
  const cpu = arch();

  if (cpu === "aarch64") {
    return await resolveResource("resources/macos/rustdesk-aarch64.dmg");
  }

  if (cpu === "x86_64") {
    return await resolveResource("resources/macos/rustdesk-x86_64.dmg");
  }

  throw new Error(`Unsupported macOS architecture: ${cpu}`);
}

export async function installRustDeskMacOS(): Promise<void> {
  const dmg = await getRustDeskInstallerPathMacOS();

  await debugLog(`RustDesk DMG: ${dmg}`);

  const mountPoint = "/Volumes/RustDesk";

  // Если старый mount остался
  try {
    await Command.create("hdiutil", ["detach", mountPoint, "-force"]).execute();
  } catch {
    // Нормально, если не был смонтирован
  }

  await debugLog("Mounting DMG...");

  const mountResult = await Command.create("hdiutil", [
    "attach",
    dmg,
    "-mountpoint",
    mountPoint,
    "-nobrowse",
  ]).execute();

  await debugLog(
    `hdiutil attach: ${mountResult.code}\n${mountResult.stdout}\n${mountResult.stderr}`,
  );

  if (mountResult.code !== 0) {
    throw new Error(mountResult.stderr || "Failed to mount RustDesk DMG");
  }

  try {
    await debugLog("Copying RustDesk.app to /Applications...");

    const copyResult = await Command.create("ditto", [
      `${mountPoint}/RustDesk.app`,
      "/Applications/RustDesk.app",
    ]).execute();

    await debugLog(
      `ditto: ${copyResult.code}\n${copyResult.stdout}\n${copyResult.stderr}`,
    );

    if (copyResult.code !== 0) {
      throw new Error(copyResult.stderr || "Failed to install RustDesk.app");
    }
  } finally {
    await debugLog("Unmounting DMG...");

    await Command.create("hdiutil", ["detach", mountPoint, "-force"]).execute();
  }

  await sleep(1000);

  await debugLog("RustDesk.app installed");
}

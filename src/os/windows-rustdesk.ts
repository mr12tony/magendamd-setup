import { Command } from "@tauri-apps/plugin-shell";
import { exists } from "@tauri-apps/plugin-fs";
import { debugLog } from "../debugLog";
import { sleep } from "../sleep";

export const RUSTDESK_WINDOWS_PATH =
  "C:\\Program Files\\RustDesk\\RustDesk.exe";

const RUSTDESK_SERVICE = "RustDesk";

async function runPowerShell(script: string) {
  await debugLog(`PowerShell:\n${script}`);

  const result = await Command.create("powershell", [
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    script,
  ]).execute();

  await debugLog(
    `PowerShell exit=${result.code}\nstdout=${result.stdout}\nstderr=${result.stderr}`,
  );

  if (result.code !== 0) {
    throw new Error(
      result.stderr ||
        result.stdout ||
        `PowerShell failed with code ${result.code}`,
    );
  }

  return result;
}

function escapePowerShell(value: string): string {
  return value.replace(/'/g, "''");
}

/**
 * Проверяет, установлен ли RustDesk.
 */
export async function isRustDeskInstalledWindows(): Promise<boolean> {
  const installed = await exists(RUSTDESK_WINDOWS_PATH);

  await debugLog(
    `isRustDeskInstalledWindows: ${installed} (${RUSTDESK_WINDOWS_PATH})`,
  );

  return installed;
}

/**
 * Устанавливает RustDesk из bundled installer.
 *
 * ВАЖНО:
 * getRustDeskInstallerPath() должен вернуть путь к
 * rustdesk-x86_64.exe / rustdesk-aarch64.exe из resources.
 */
export async function installRustDeskWindows(
  installerPath: string,
): Promise<void> {
  await debugLog(`=== Windows RustDesk install ===`);
  await debugLog(`Installer: ${installerPath}`);

  const installer = escapePowerShell(installerPath);

  await runPowerShell(
    `
Start-Process ` +
      `-FilePath '${installer}' ` +
      `-ArgumentList '--silent-install' ` +
      `-Verb RunAs
`,
  );

  await debugLog("RustDesk installer started");

  await waitForRustDeskWindows();

  await ensureRustDeskServiceWindows();

  await debugLog("RustDesk installation completed");
}

/**
 * Удаление RustDesk.
 */
export async function uninstallRustDeskWindows(): Promise<void> {
  await debugLog("=== Windows RustDesk uninstall ===");

  if (!(await exists(RUSTDESK_WINDOWS_PATH))) {
    await debugLog("RustDesk.exe does not exist, nothing to uninstall");
    return;
  }

  const exe = escapePowerShell(RUSTDESK_WINDOWS_PATH);

  await runPowerShell(
    `
Start-Process ` +
      `-FilePath '${exe}' ` +
      `-ArgumentList '--uninstall' ` +
      `-Verb RunAs
`,
  );

  await debugLog("RustDesk uninstall started");

  // Даём uninstall process время удалить service/files.
  await sleep(3000);

  await debugLog("RustDesk uninstall wait finished");
}

/**
 * Ждёт появления установленного RustDesk.exe.
 */
export async function waitForRustDeskWindows(timeoutMs = 30000): Promise<void> {
  await debugLog("Waiting for RustDesk.exe...");

  const started = Date.now();

  while (Date.now() - started < timeoutMs) {
    if (await exists(RUSTDESK_WINDOWS_PATH)) {
      await debugLog("RustDesk.exe found");
      return;
    }

    await sleep(500);
  }

  throw new Error(
    `RustDesk.exe was not found after ${timeoutMs}ms: ${RUSTDESK_WINDOWS_PATH}`,
  );
}

/**
 * Проверяет состояние RustDesk service.
 */
export async function getRustDeskServiceStatusWindows(): Promise<string> {
  const result = await runPowerShell(
    `
$service = Get-Service ` +
      `-Name '${RUSTDESK_SERVICE}' ` +
      `-ErrorAction SilentlyContinue

if ($null -eq $service) {
    Write-Output "NotInstalled"
} else {
    Write-Output $service.Status
}
`,
  );

  return result.stdout.trim();
}

/**
 * Устанавливает RustDesk Windows service, если его ещё нет.
 */
export async function ensureRustDeskServiceWindows(): Promise<void> {
  await debugLog("=== Ensure RustDesk service ===");

  let status = await getRustDeskServiceStatusWindows();

  await debugLog(`Initial service status: ${status}`);

  if (status === "NotInstalled") {
    await debugLog("RustDesk service not installed");

    const exe = escapePowerShell(RUSTDESK_WINDOWS_PATH);

    await runPowerShell(
      `
Start-Process ` +
        `-FilePath '${exe}' ` +
        `-ArgumentList '--install-service' ` +
        `-Verb RunAs
`,
    );

    await debugLog("RustDesk --install-service started");

    await sleep(3000);

    status = await getRustDeskServiceStatusWindows();

    await debugLog(`Service status after install: ${status}`);
  }

  if (status !== "Running") {
    await debugLog("Starting RustDesk service");

    await runPowerShell(
      `
Start-Service ` +
        `-Name '${RUSTDESK_SERVICE}'
`,
    );

    await debugLog("Start-Service executed");
  }

  await waitForRustDeskServiceWindows();

  await debugLog("RustDesk service is running");
}

/**
 * Ждёт, пока service RustDesk станет Running.
 */
export async function waitForRustDeskServiceWindows(
  timeoutMs = 30000,
): Promise<void> {
  await debugLog("Waiting for RustDesk service Running...");

  const started = Date.now();

  while (Date.now() - started < timeoutMs) {
    const status = await getRustDeskServiceStatusWindows();

    await debugLog(`RustDesk service status: ${status}`);

    if (status === "Running") {
      return;
    }

    await sleep(1000);
  }

  throw new Error(
    `RustDesk service did not become Running within ${timeoutMs}ms`,
  );
}

/**
 * Получает RustDesk ID.
 *
 * Не запускаем RustDesk как обычный Tauri shell command.
 * Используем PowerShell, как в официальном сценарии RustDesk.
 */
export async function getRustDeskIdWindows(): Promise<string | null> {
  await debugLog("=== Get RustDesk ID ===");

  await ensureRustDeskServiceWindows();

  const exe = escapePowerShell(RUSTDESK_WINDOWS_PATH);

  const result = await runPowerShell(`
$id = & '${exe}' --get-id | Out-String

$id = $id.Trim()

if ([string]::IsNullOrWhiteSpace($id)) {
    exit 2
}

Write-Output $id
`);

  const id = result.stdout.trim();

  await debugLog(`RustDesk ID: ${id}`);

  return id || null;
}

/**
 * Устанавливает permanent password.
 */
export async function setRustDeskPasswordWindows(
  password: string,
): Promise<void> {
  await debugLog("=== Set RustDesk password ===");

  await ensureRustDeskServiceWindows();

  const exe = escapePowerShell(RUSTDESK_WINDOWS_PATH);
  const escapedPassword = escapePowerShell(password);

  await runPowerShell(`
& '${exe}' --password '${escapedPassword}'
`);

  await debugLog("RustDesk password configured");
}

/**
 * Применяет RustDesk config string.
 *
 * configString должен быть тем значением,
 * которое RustDesk ожидает в --config.
 */
export async function configureRustDeskWindows(
  configString: string,
): Promise<void> {
  await debugLog("=== Configure RustDesk ===");

  await ensureRustDeskServiceWindows();

  const exe = escapePowerShell(RUSTDESK_WINDOWS_PATH);
  const config = escapePowerShell(configString);

  await runPowerShell(`
& '${exe}' --config '${config}'
`);

  await debugLog("RustDesk config applied");
}

/**
 * Перезапуск Windows service.
 *
 * Это предпочтительнее, чем kill + Start-Process RustDesk.exe.
 */
export async function restartRustDeskWindows(): Promise<void> {
  await debugLog("=== Restart RustDesk service ===");

  await runPowerShell(
    `
Restart-Service ` +
      `-Name '${RUSTDESK_SERVICE}' ` +
      `-Force
`,
  );

  await waitForRustDeskServiceWindows();

  await debugLog("RustDesk service restarted");
}

/**
 * Остановка RustDesk.
 */
export async function killRustDeskWindows(): Promise<void> {
  await debugLog("=== Stop RustDesk ===");

  const status = await getRustDeskServiceStatusWindows();

  if (status === "NotInstalled") {
    await debugLog("RustDesk service is not installed");
    return;
  }

  if (status !== "Stopped") {
    await runPowerShell(
      `
Stop-Service ` +
        `-Name '${RUSTDESK_SERVICE}' ` +
        `-Force
`,
    );

    await debugLog("RustDesk service stopped");
  }
}

/**
 * Запуск RustDesk service.
 */
export async function startRustDeskWindows(): Promise<void> {
  await debugLog("=== Start RustDesk ===");

  await runPowerShell(
    `
Start-Service ` +
      `-Name '${RUSTDESK_SERVICE}'
`,
  );

  await waitForRustDeskServiceWindows();

  await debugLog("RustDesk service started");
}

/**
 * Полная настройка Windows RustDesk.
 */
export async function setupRustDeskWindows(params: {
  password: string;
  configString?: string;
}): Promise<string> {
  await debugLog("================================");
  await debugLog("=== FULL WINDOWS RUSTDESK SETUP ===");
  await debugLog("================================");

  await waitForRustDeskWindows();

  await ensureRustDeskServiceWindows();

  if (params.configString) {
    await configureRustDeskWindows(params.configString);
  }

  await setRustDeskPasswordWindows(params.password);

  await restartRustDeskWindows();

  await sleep(2000);

  const id = await getRustDeskIdWindows();

  if (!id) {
    throw new Error("Failed to get RustDesk ID");
  }

  await debugLog(`FULL SETUP SUCCESS. ID=${id}`);

  return id;
}

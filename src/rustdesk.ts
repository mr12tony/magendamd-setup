import { Command } from "@tauri-apps/plugin-shell";
import { platform } from "@tauri-apps/plugin-os";
import { getRustDeskPath } from "./os/rustdesk-path";
import { sleep } from "./sleep";

export async function isRustDeskInstalled(): Promise<boolean> {
  return (await getRustDeskPath()) !== null;
}

export async function getRustDeskId(): Promise<string | null> {
  const path = await getRustDeskPath();

  if (!path) {
    return null;
  }

  const command = getRustDeskCommand();

  const result = await Command.create(command, ["--get-id"]).execute();

  if (result.code !== 0) {
    console.error(result.stderr);
    return null;
  }

  return result.stdout.trim();
}

export function getRustDeskCommand() {
  const os = platform();

  if (os === "macos") {
    return "rustdesk-macos";
  }

  if (os === "windows") {
    return "rustdesk-windows";
  }

  throw new Error(`Unsupported OS: ${os}`);
}

export async function getRustDeskConfig(): Promise<{
  rendezvousServer: string;
  relayServer: string;
  key: string;
  password: string;
}> {
  const response = await fetch(
    `${import.meta.env.VITE_FRONTEND_URL}/api/rustdesk/config`,
    {
      method: "GET",
      cache: "no-store",
    },
  );

  if (response.status === 403) {
    throw new Error("API access forbidden");
  }

  if (!response.ok) {
    throw new Error("Backend unavailable");
  }

  const config = await response.json();

  return config;
}

export async function openRustDesk(): Promise<void> {
  const command = getRustDeskCommand();

  const result = await Command.create(command).execute();

  if (result.code !== 0) {
    throw new Error(result.stderr || "Failed to open RustDesk");
  }
}

const RUSTDESK_APP_PATH = "/Applications/RustDesk.app";

export async function killRustDeskMacOS(): Promise<void> {
  try {
    const result = await Command.create("killall", ["RustDesk"]).execute();

    if (result.code !== 0 && result.code !== 1) {
      throw new Error(
        result.stderr || `killall exited with code ${result.code}`,
      );
    }

    console.log("RustDesk stopped");
  } catch (error) {
    console.log("RustDesk was not running:", error);
  }
}

export async function restartRustDeskMacOS(): Promise<void> {
  await killRustDeskMacOS();
  await sleep(500);

  const openResult = await Command.create("open", [
    "-n",
    RUSTDESK_APP_PATH,
  ]).execute();

  if (openResult.code !== 0) {
    throw new Error(openResult.stderr || "Failed to start RustDesk");
  }

  console.log("RustDesk restarted");
}

const RUSTDESK_WINDOWS_PATH = "C:\\Program Files\\RustDesk\\RustDesk.exe";

export async function killRustDeskWindows(): Promise<void> {
  try {
    const result = await Command.create("taskkill", [
      "/F",
      "/IM",
      "RustDesk.exe",
    ]).execute();

    console.log("RustDesk taskkill:", result.code);
    console.log("stdout:", result.stdout);
    console.log("stderr:", result.stderr);

    // ERRORLEVEL 128/1 может означать, что процесса не было.
    // Поэтому отсутствие процесса не считаем ошибкой.
  } catch (error) {
    console.log("RustDesk was not running:", error);
  }
}

// export async function restartRustDeskWindows(): Promise<void> {
//   await killRustDeskWindows();
//   await sleep(500);

//   const result = await Command.create("rustdesk-windows", []).execute();

//   console.log("RustDesk start:", result.code);
//   console.log("stdout:", result.stdout);
//   console.log("stderr:", result.stderr);

//   if (result.code !== 0) {
//     throw new Error(result.stderr || "Failed to start RustDesk");
//   }

//   console.log("RustDesk restarted");
// }

export async function restartRustDeskWindows(): Promise<void> {
  await killRustDeskWindows();
  await sleep(1000);

  const psCommand =
    `Start-Process ` +
    `-FilePath '${RUSTDESK_WINDOWS_PATH.replace(/'/g, "''")}'`;

  const result = await Command.create("powershell", [
    "-NoProfile",
    "-NonInteractive",
    "-Command",
    psCommand,
  ]).execute();

  console.log("RustDesk start:", result.code);
  console.log("stdout:", result.stdout);
  console.log("stderr:", result.stderr);

  if (result.code !== 0) {
    throw new Error(result.stderr || "Failed to start RustDesk");
  }
}

export async function killRustDesk(): Promise<void> {
  const os = platform();

  if (os === "macos") {
    return killRustDeskMacOS();
  }

  if (os === "windows") {
    return killRustDeskWindows();
  }

  throw new Error(`Unsupported platform: ${os}`);
}

export async function restartRustDesk(): Promise<void> {
  const os = platform();

  if (os === "macos") {
    return restartRustDeskMacOS();
  }

  if (os === "windows") {
    return restartRustDeskWindows();
  }

  throw new Error(`Unsupported platform: ${os}`);
}

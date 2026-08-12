import { Command } from "@tauri-apps/plugin-shell";
import { platform } from "@tauri-apps/plugin-os";
import { getRustDeskPath } from "./os/rustdesk-path";

export async function isRustDeskInstalled(): Promise<boolean> {
  return (await getRustDeskPath()) !== null;
}

export async function setRustDeskPassword(password: string): Promise<void> {
  const command = getRustDeskCommand();

  const result = await Command.create(command, [
    "--password",
    password,
  ]).execute();

  console.log("password exit:", result.code);
  console.log("password stdout:", result.stdout);
  console.log("password stderr:", result.stderr);

  if (result.code !== 0) {
    throw new Error(result.stderr || "Failed to set RustDesk password");
  }
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

export async function restartRustDesk(): Promise<void> {
  // 1. Завершаем RustDesk, если он запущен.
  // killall вернёт ненулевой код, если процесса нет —
  // это нормально.
  try {
    const killResult = await Command.create("killall", ["RustDesk"]).execute();

    console.log("RustDesk kill:", killResult.code, killResult.stderr);
  } catch {
    // RustDesk уже не запущен.
  }

  // 2. Небольшая пауза, чтобы процесс полностью завершился.
  await sleep(500);

  // 3. Запускаем установленный RustDesk.
  const openResult = await Command.create("open", [
    "-n",
    RUSTDESK_APP_PATH,
  ]).execute();

  if (openResult.code !== 0) {
    throw new Error(openResult.stderr || "Failed to start RustDesk");
  }

  console.log("RustDesk restarted");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

export async function killRustDesk(): Promise<void> {
  try {
    const result = await Command.create("killall", ["RustDesk"]).execute();

    // 0 — процесс был найден и завершён.
    // 1 — RustDesk не запущен. Это тоже нормально.
    if (result.code !== 0 && result.code !== 1) {
      throw new Error(
        result.stderr || `killall exited with code ${result.code}`,
      );
    }

    console.log("RustDesk stopped");
  } catch (error) {
    // Если RustDesk уже не запущен — продолжаем.
    console.log("RustDesk was not running:", error);
  }
}

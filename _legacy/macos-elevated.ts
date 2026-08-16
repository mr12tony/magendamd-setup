import { Command } from "@tauri-apps/plugin-shell";

type ElevatedResult = {
  code: number | null;
  stdout: string;
  stderr: string;
};

/**
 * Выполняет команду через sudo.
 *
 * macOS сама покажет системный запрос пароля,
 * если текущему пользователю нужны elevated privileges.
 */
export async function runAsAdmin(
  command: string,
  args: string[] = [],
): Promise<ElevatedResult> {
  const escapedCommand = [command, ...args].map(shellEscape).join(" ");

  const result = await Command.create("osascript", [
    "-e",
    `do shell script ${appleScriptString(
      escapedCommand,
    )} with administrator privileges`,
  ]).execute();

  return {
    code: result.code,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

/**
 * Устанавливает пароль RustDesk с административными правами.
 */
export async function setRustDeskPasswordMacOS(
  password: string,
): Promise<void> {
  const rustDeskPath = "/Applications/RustDesk.app/Contents/MacOS/RustDesk";

  const result = await runAsAdmin(rustDeskPath, ["--password", password]);

  console.log("RustDesk password exit:", result.code);

  console.log("RustDesk password stdout:", result.stdout);

  console.log("RustDesk password stderr:", result.stderr);

  if (result.code !== 0) {
    throw new Error(
      result.stderr || result.stdout || "Failed to set RustDesk password",
    );
  }
}

/**
 * Экранирует аргумент для shell.
 */
function shellEscape(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

/**
 * Экранирует строку для AppleScript string literal.
 */
function appleScriptString(value: string): string {
  return `"${value
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\r/g, "\\r")
    .replace(/\n/g, "\\n")}"`;
}

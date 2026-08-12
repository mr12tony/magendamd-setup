import { Command } from "@tauri-apps/plugin-shell";
import { RUSTDESK_PATH } from "./windows";

// export async function runRustDeskAsAdmin(args: string[]): Promise<number> {
//   const escapedArgs = args
//     .map((arg) => arg.replace(/'/g, "''"))
//     .map((arg) => `'${arg}'`)
//     .join(",");

//   const command =
//     `
//     Start-Process ` +
//     `-FilePath '${RUSTDESK_PATH.replace(/'/g, "''")}' ` +
//     `-ArgumentList ${escapedArgs} ` +
//     `-Verb RunAs ` +
//     `-Wait
//   `;

//   const result = await Command.create("powershell", [
//     "-NoProfile",
//     "-NonInteractive",
//     "-ExecutionPolicy",
//     "Bypass",
//     "-Command",
//     command,
//   ]).execute();

//   console.log("PowerShell exit:", result.code);
//   console.log("stdout:", result.stdout);
//   console.log("stderr:", result.stderr);

//   if (result.code !== 0) {
//     throw new Error(
//       result.stderr ||
//         result.stdout ||
//         "Failed to run RustDesk as administrator",
//     );
//   }

//   return result.code;
// }

export async function runRustDeskAsAdmin(args: string[]): Promise<void> {
  const path = "C:\\Program Files\\RustDesk\\RustDesk.exe";

  const argumentList = args
    .map((arg) => `'${arg.replace(/'/g, "''")}'`)
    .join(",");

  const psCommand =
    `
    Start-Process ` +
    `-FilePath '${path}' ` +
    `-ArgumentList ${argumentList} ` +
    `-Verb RunAs ` +
    `-Wait
  `;

  console.log("PowerShell:", psCommand);

  const result = await Command.create("powershell", [
    "-NoProfile",
    "-NonInteractive",
    "-Command",
    psCommand,
  ]).execute();

  console.log("exit:", result.code);
  console.log("stdout:", result.stdout);
  console.log("stderr:", result.stderr);

  if (result.code !== 0) {
    throw new Error(result.stderr || result.stdout || "Failed to run RustDesk");
  }
}

export async function setRustDeskPasswordWindows(
  password: string,
): Promise<void> {
  await runRustDeskAsAdmin(["--password", password]);
}

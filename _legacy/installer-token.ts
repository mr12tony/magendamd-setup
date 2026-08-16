import { invoke } from "@tauri-apps/api/core";

export async function getAccessToken(): Promise<string> {
  // DEV
  if (import.meta.env.DEV) {
    const token = import.meta.env.VITE_ACCESS_TOKEN;

    if (!token) {
      throw new Error("VITE_ACCESS_TOKEN is not defined");
    }

    return token;
  }

  return await invoke<string>("get_access_token");
}

// import { platform } from "@tauri-apps/plugin-os";
// import { invoke } from "@tauri-apps/api/core";
// import { dirname, join } from "@tauri-apps/api/path";
// import { exists, readTextFile } from "@tauri-apps/plugin-fs";

// async function readTokenFile(directory: string): Promise<string> {
//   const tokenPath = await join(directory, "access-token.txt");

//   if (!(await exists(tokenPath))) {
//     throw new Error(`access-token.txt not found: ${tokenPath}`);
//   }

//   const token = (await readTextFile(tokenPath)).trim();

//   if (!token) {
//     throw new Error("access-token.txt is empty");
//   }

//   return token;
// }

// async function getWindowsAccessToken(): Promise<string> {
//   const exePath = await invoke<string>("get_current_exe");

//   const directory = await dirname(exePath);

//   return readTokenFile(directory);
// }

// async function getMacOSAccessToken(): Promise<string> {
//   let path = await invoke<string>("get_current_exe");

//   path = await dirname(path); // Contents/MacOS
//   path = await dirname(path); // Contents
//   path = await dirname(path); // Magendamd.app
//   path = await dirname(path); // parent

//   return readTokenFile(path);
// }

// export async function getAccessToken(): Promise<string> {
//   // DEV
//   if (import.meta.env.DEV) {
//     const token = import.meta.env.VITE_ACCESS_TOKEN;

//     if (!token) {
//       throw new Error("VITE_ACCESS_TOKEN is not defined");
//     }

//     return token;
//   }

//   // PRODUCTION
//   const os = platform();

//   if (os === "windows") {
//     return getWindowsAccessToken();
//   }

//   if (os === "macos") {
//     return getMacOSAccessToken();
//   }

//   throw new Error(`Unsupported platform: ${os}`);
// }

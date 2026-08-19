import { invoke } from "@tauri-apps/api/core";

export interface AppConfig {
  token: string;
  password: string;
  api: string;
}

export async function getAppConfig(): Promise<AppConfig> {
  // DEV
  // if (import.meta.env.DEV) {
  //   return {
  //     token: import.meta.env.VITE_ACCESS_TOKEN,
  //     password: import.meta.env.VITE_PERMANENT_PASSWORD,
  //     api: import.meta.env.VITE_BACKEND_URL,
  //   } as AppConfig;
  // }

  try {
    return await invoke<AppConfig>("get_config");
  } catch (error) {
    console.error("get_config failed:", error);

    throw error;
  }
}

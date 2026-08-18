// import { resolveResource } from "@tauri-apps/api/path";
// import { readTextFile } from "@tauri-apps/plugin-fs";
import { invoke } from "@tauri-apps/api/core";

export interface AppConfig {
  token: string;
  password: string;
  config: string;
}

export async function getAppConfig(): Promise<AppConfig> {
  // DEV
  if (import.meta.env.DEV) {
    return {
      token: "ee6ff174c642b13ef5a5144f",
      password: "Demo111!",
      config:
        "=0nI9MWTLBXTuZjQ6FDUttmN1V3Q3U0QKhmSBBla2EWQ5gFUN50ZrV2byATaMtiI6ISeltmIsIiI6ISawFmIsISbvNmLk1WYk5WZnFWbus2clRGdzVnciojI5FGblJnIsISbvNmLk1WYk5WZnFWbus2clRGdzVnciojI0N3boJye",
    } as AppConfig;
  }

  return await invoke<AppConfig>("get_config");

  //   const configPath = await resolveResource("config.json");
  //   const content = await readTextFile(configPath);
  //   const config = JSON.parse(content) as AppConfig;

  //   if (!config.token) {
  //     throw new Error("config.json: token is missing");
  //   }

  //   if (!config.config) {
  //     throw new Error("config.json: config is missing");
  //   }

  //   return config;
}

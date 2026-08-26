export type InstallMode = "dev" | "prod" | "local";

export type InstallDeepLink = {
  token: string;
  mode: InstallMode;
};

export function getInstallConfigFromUrl(value: string): InstallDeepLink | null {
  try {
    const url = new URL(value);

    if (url.protocol !== "magendasupport:" || url.hostname !== "install") {
      return null;
    }

    const token = url.searchParams.get("token")?.trim();

    const mode = url.searchParams.get("mode")?.trim();

    if (!token) {
      return null;
    }

    if (mode !== "dev" && mode !== "prod" && mode !== "local") {
      return null;
    }

    return {
      token,
      mode,
    };
  } catch {
    return null;
  }
}

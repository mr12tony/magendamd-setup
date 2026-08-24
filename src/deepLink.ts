import { getCurrent, onOpenUrl } from "@tauri-apps/plugin-deep-link";

export function getInstallTokenFromUrl(value: string): string | null {
  try {
    const url = new URL(value);

    if (url.protocol !== "magendasupport:") {
      return null;
    }

    if (url.hostname !== "install") {
      return null;
    }

    const token = url.searchParams.get("token")?.trim();

    if (!token) {
      return null;
    }

    // Та же идея, что в installer filename.
    if (!/^[A-Za-z0-9_-]+$/.test(token)) {
      return null;
    }

    return token;
  } catch {
    return null;
  }
}

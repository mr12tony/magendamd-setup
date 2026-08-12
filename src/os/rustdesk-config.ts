import { exists, readTextFile, writeTextFile } from "@tauri-apps/plugin-fs";
import { homeDir, join, appDataDir } from "@tauri-apps/api/path";
import { parse, stringify } from "smol-toml";

export interface RustDeskConfig {
  rendezvousServer: string;
  relayServer: string;
  key: string;
}

interface RustDeskToml {
  rendezvous_server?: string;
  nat_type?: number;
  serial?: number;
  unlock_pin?: string;
  trusted_devices?: string;

  options?: Record<string, unknown>;

  [key: string]: unknown;
}

export async function configureRustDeskMacOS(
  config: RustDeskConfig,
): Promise<void> {
  const home = await homeDir();

  const path = await join(
    home,
    "Library",
    "Preferences",
    "com.carriez.RustDesk",
    "RustDesk2.toml",
  );

  let data: RustDeskToml = {};

  if (await exists(path)) {
    const text = await readTextFile(path);

    if (text.trim()) {
      data = parse(text) as RustDeskToml;
    }
  }

  // ─────────────────────────────────────
  // ID server
  // ─────────────────────────────────────

  const idServer = normalizeServer(config.rendezvousServer, 21116);

  data.rendezvous_server = idServer;

  // ─────────────────────────────────────
  // [options]
  // ─────────────────────────────────────

  if (!data.options) {
    data.options = {};
  }

  data.options["custom-rendezvous-server"] = normalizeServer(
    config.rendezvousServer,
  );

  data.options["relay-server"] = normalizeServer(config.relayServer);

  data.options["key"] = config.key;

  data.options["verification-method"] = "use-permanent-password";

  // ─────────────────────────────────────
  // Save
  // ─────────────────────────────────────

  await writeTextFile(path, stringify(data));

  console.log("RustDesk configuration written:", path);
}

export async function verifyRustDeskMacOSConfig(
  expected: RustDeskConfig,
): Promise<boolean> {
  const home = await homeDir();

  const path = await join(
    home,
    "Library",
    "Preferences",
    "com.carriez.RustDesk",
    "RustDesk2.toml",
  );

  if (!(await exists(path))) {
    console.error("RustDesk config not found:", path);
    return false;
  }

  const text = await readTextFile(path);

  console.log("RustDesk TOML >>>", text);

  if (!text.trim()) {
    return false;
  }

  const data = parse(text) as RustDeskToml;

  const options = data.options ?? {};

  const expectedIdServer = normalizeServer(expected.rendezvousServer);

  const actualIdServer = normalizeServer(
    String(options["custom-rendezvous-server"] ?? ""),
  );

  const expectedRelayServer = normalizeServer(expected.relayServer);

  const actualRelayServer = normalizeServer(
    String(options["relay-server"] ?? ""),
  );

  const idServerOk = actualIdServer === expectedIdServer;

  const relayServerOk = actualRelayServer === expectedRelayServer;

  const keyOk = options["key"] === expected.key;

  console.log("RustDesk verification:", {
    expectedIdServer,
    actualIdServer,
    idServerOk,

    expectedRelayServer,
    actualRelayServer,
    relayServerOk,

    keyOk,
  });

  return idServerOk && relayServerOk && keyOk;
}

export async function configureRustDeskWindows(
  config: RustDeskConfig,
): Promise<void> {
  const appData = await appDataDir();

  const path = await join(appData, "RustDesk", "config", "RustDesk2.toml");

  let data: RustDeskToml = {};

  if (await exists(path)) {
    const text = await readTextFile(path);

    if (text.trim()) {
      data = parse(text) as RustDeskToml;
    }
  }

  const idServer = normalizeServer(config.rendezvousServer, 21116);

  data.rendezvous_server = idServer;

  if (!data.options) {
    data.options = {};
  }

  data.options["custom-rendezvous-server"] = normalizeServer(
    config.rendezvousServer,
  );

  data.options["relay-server"] = normalizeServer(config.relayServer);

  data.options["key"] = config.key;

  data.options["verification-method"] = "use-permanent-password";

  await writeTextFile(path, stringify(data));
}

function normalizeServer(server: string, defaultPort?: number): string {
  let value = server
    .trim()
    .replace(/^https?:\/\//, "")
    .replace(/\/$/, "");

  if (defaultPort && !value.includes(":")) {
    value += `:${defaultPort}`;
  }

  return value;
}

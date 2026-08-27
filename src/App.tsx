import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { message, ask } from "@tauri-apps/plugin-dialog";
import { getCurrent, onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getSystemInfo } from "./system";
import { getInstallConfigFromUrl } from "./deepLink";

import "./App.css";

type UpdateInfo = {
  available: boolean;
  version: string | null;
  notes: string | null;
};

type RustDeskPermissionsStatus = {
  accessibility: boolean;
  screen_recording: boolean;
  input_monitoring: boolean;
};

type RustDeskStatus = {
  installed: boolean;
  version: string | null;
  service_running: boolean;
  configured: boolean;
  id: string | null;
};

type RegistrationData = {
  registered: boolean;
  currentRustdeskId: string;
  computerName: string;
  registeredAt: string;
};

type InstallMode = "dev" | "prod" | "local";

type InstallConfig = {
  install_token: string;
  mode: InstallMode;
};

function getBackendUrl(mode: InstallMode) {
  switch (mode) {
    case "dev":
      return "https://apidev.magendamd.com/api/v1";

    case "prod":
      return "https://api.magendamd.com/api/v1";

    case "local":
      return "http://127.0.0.1:8000/api/v1";
  }
}

function getFrontendUrl(mode: InstallMode = "prod") {
  switch (mode) {
    case "dev":
      return "https://dev.magendamd.com";

    case "prod":
      return "https://app.magendamd.com";

    case "local":
      return "http://127.0.0.1:3000";
  }
}

function App() {
  const [registration, setRegistration] = useState<RegistrationData | null>(
    () => {
      const saved = localStorage.getItem("device_registration");

      if (!saved) {
        return null;
      }

      try {
        return JSON.parse(saved) as RegistrationData;
      } catch {
        return null;
      }
    },
  );

  const [computerName, setComputerName] = useState(() => {
    const saved = localStorage.getItem("computer_name");

    return saved ?? "";
  });

  const [supportMessage, setSupportMessage] = useState("");

  const [processing, setProcessing] = useState(false);

  const [installConfig, setInstallConfig] = useState<InstallConfig | null>(
    null,
  );

  const [currentRustdeskId, setCurrentRustdeskId] = useState("");

  const [permissions, setPermissions] =
    useState<RustDeskPermissionsStatus | null>(null);

  const [status, setStatus] = useState<RustDeskStatus | null>(null);

  async function checkForUpdates() {
    try {
      const update = await invoke<UpdateInfo>("check_for_updates");

      if (!update.available) {
        console.log("Application is up to date.");

        return;
      }

      const install = await ask(
        `Magenda Support ${update.version} is available.${
          update.notes ? `\n\n${update.notes}` : ""
        }\n\nInstall the update now?`,
        {
          title: "Update available",
          kind: "info",
          okLabel: "Update",
          cancelLabel: "Later",
        },
      );

      if (!install) {
        return;
      }

      setProcessing(true);

      await invoke("download_and_install_update");
    } catch (err) {
      console.error("Updater failed:", err);
    } finally {
      setProcessing(false);
    }
  }

  // ============================================================
  // HELPERS
  // ============================================================

  function isRustDeskHealthy(value: RustDeskStatus) {
    return (
      value.installed &&
      value.version === "1.4.9" &&
      value.service_running &&
      value.configured &&
      !!value.id?.trim()
    );
  }

  function getErrorMessage(err: unknown, fallback: string) {
    if (err instanceof Error) {
      return err.message;
    }

    if (typeof err === "string") {
      return err;
    }

    return fallback;
  }

  // ============================================================
  // PERMISSIONS
  // ============================================================

  async function checkPermissions() {
    try {
      const currentPermissions = await invoke<RustDeskPermissionsStatus>(
        "get_rustdesk_permissions_status",
      );

      setPermissions(currentPermissions);
    } catch (err) {
      console.error("Failed to check RustDesk permissions:", err);
    }
  }

  // ============================================================
  // INITIALIZE
  // ============================================================

  async function initialize() {
    try {
      // ========================================
      // TOKEN
      // ========================================

      const config = await invoke<InstallConfig | null>("get_install_config");

      if (config?.install_token?.trim()) {
        setInstallConfig(config);
      } else {
        setInstallConfig(null);

        await handleMissingInstallToken();
      }

      // ========================================
      // RUSTDESK
      // ========================================

      let rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");

      if (!isRustDeskHealthy(rustdeskStatus)) {
        await invoke("configure_rustdesk");

        rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");
      }

      if (!isRustDeskHealthy(rustdeskStatus)) {
        throw new Error("RustDesk configuration is incomplete.");
      }

      setStatus(rustdeskStatus);

      setCurrentRustdeskId(rustdeskStatus.id!.trim());
    } catch (err) {
      setCurrentRustdeskId("");
      setStatus(null);

      const msg = getErrorMessage(err, "Failed to initialize the application.");

      await message(msg, {
        title: "Configuration error",
        kind: "error",
      });
    }
  }

  // ============================================================
  // REGISTER DEVICE
  // ============================================================

  async function registerDevice(config: InstallConfig) {
    const cleanToken = config.install_token.trim();

    if (!cleanToken) {
      throw new Error("Installation token is missing.");
    }

    const cleanComputerName = computerName.trim();

    if (!cleanComputerName) {
      throw new Error("Computer name is missing.");
    }

    let rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");

    if (!isRustDeskHealthy(rustdeskStatus)) {
      await invoke("configure_rustdesk");

      rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");
    }

    if (!isRustDeskHealthy(rustdeskStatus)) {
      throw new Error("RustDesk configuration is incomplete.");
    }

    const rustdeskId = rustdeskStatus.id!.trim();

    setStatus(rustdeskStatus);
    setCurrentRustdeskId(rustdeskId);

    const backendUrl = getBackendUrl(config.mode);

    const response = await fetch(`${backendUrl}/rustdesk/devices`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-RustDesk-Key": cleanToken,
      },
      body: JSON.stringify({
        device_id: rustdeskId,
        password: import.meta.env.VITE_PERMANENT_PASSWORD,
        name: cleanComputerName,
      }),
    });

    if (!response.ok) {
      let serverMessage = "";

      try {
        serverMessage = await response.text();
      } catch {
        //
      }

      throw new Error(
        serverMessage ||
          `Failed to register device. Server returned HTTP ${response.status}.`,
      );
    }

    const registrationData: RegistrationData = {
      registered: true,
      currentRustdeskId: rustdeskId,
      computerName: cleanComputerName,
      registeredAt: new Date().toISOString(),
    };

    localStorage.setItem(
      "device_registration",
      JSON.stringify(registrationData),
    );

    setRegistration(registrationData);

    return registrationData;
  }

  // ============================================================
  // MANUAL REGISTER
  // ============================================================

  async function handleRegister() {
    if (!installConfig || !computerName.trim()) {
      return;
    }

    try {
      setProcessing(true);

      await registerDevice(installConfig);

      await message("This device has been successfully connected to support.", {
        title: "Device registered",
        kind: "info",
      });
    } catch (err) {
      const msg = getErrorMessage(err, "Failed to register the device.");

      await message(msg, {
        title: "Device registration error",
        kind: "error",
      });
    } finally {
      setProcessing(false);
    }
  }

  // ============================================================
  // DEEP LINK
  // ============================================================

  async function handleDeepLinks(urls: string[]) {
    for (const url of urls) {
      const deepLinkConfig = getInstallConfigFromUrl(url);

      if (!deepLinkConfig) {
        continue;
      }

      try {
        setProcessing(true);

        console.log("Received install config from deep link.");

        const config: InstallConfig = {
          install_token: deepLinkConfig.token,
          mode: deepLinkConfig.mode,
        };

        await invoke("save_install_config", {
          token: config.install_token,
          mode: config.mode,
        });

        setInstallConfig(config);

        await registerDevice(config);

        await message(
          "This device has been successfully connected to support.",
          {
            title: "Device registered",
            kind: "info",
          },
        );
      } catch (err) {
        const msg = getErrorMessage(err, "Failed to register the device.");

        console.error("Deep link registration failed:", err);

        await message(msg, {
          title: "Device registration error",
          kind: "error",
        });
      } finally {
        setProcessing(false);
      }

      return;
    }
  }

  // ============================================================
  // OPEN RUSTDESK
  // ============================================================

  // async function handleOpenRustDesk() {
  //   try {
  //     await invoke("open_rustdesk");
  //   } catch (err) {
  //     const msg = getErrorMessage(err, "Failed to open RustDesk.");

  //     await message(msg, {
  //       title: "RustDesk",
  //       kind: "error",
  //     });
  //   }
  // }

  // ============================================================
  // SUPPORT REQUEST
  // ============================================================

  async function handleRequest() {
    const cleanMessage = supportMessage.trim();

    if (!cleanMessage) {
      await message("Please describe your issue.", {
        title: "Support request",
        kind: "warning",
      });

      return;
    }

    if (!installConfig) {
      await message("Installation configuration is missing.", {
        title: "Support request error",
        kind: "error",
      });

      return;
    }

    const cleanToken = installConfig.install_token?.trim();

    if (!cleanToken) {
      await message("Installation token is missing.", {
        title: "Support request error",
        kind: "error",
      });

      return;
    }

    try {
      setProcessing(true);

      const backendUrl = getBackendUrl(installConfig.mode);

      // Добавляем RustDesk deep link к сообщению.
      const formattedMessage = `${cleanMessage}

rustdesk://${currentRustdeskId.trim()}`;

      const response = await fetch(`${backendUrl}/rustdesk/message`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-RustDesk-Key": cleanToken,
        },
        body: JSON.stringify({
          message: formattedMessage,
          device_id: currentRustdeskId,
          name: computerName.trim(),
        }),
      });

      if (!response.ok) {
        let serverMessage = "";

        try {
          const data = await response.json();

          serverMessage = data?.message || data?.error || "";
        } catch {
          try {
            serverMessage = await response.text();
          } catch {
            //
          }
        }

        throw new Error(
          serverMessage ||
            `Failed to send support request. Server returned HTTP ${response.status}.`,
        );
      }

      // Очищаем сообщение только после успешной отправки.
      setSupportMessage("");

      await message("Your support request has been sent successfully.", {
        title: "Support request sent",
        kind: "info",
      });
    } catch (err) {
      console.error("Failed to send support request:", err);

      const msg = getErrorMessage(err, "Failed to send support request.");

      await message(msg, {
        title: "Support request error",
        kind: "error",
      });
    } finally {
      setProcessing(false);
    }
  }

  // ============================================================
  // MISSING TOKEN
  // ============================================================

  async function handleMissingInstallToken() {
    const openPlatform = await ask(
      "This device is not linked to your Magenda account yet.\n\nOpen the Magenda platform in your browser, then click “Open MagendaSupport” on the platform to send the registration link to this application.",
      {
        title: "Device registration required",
        kind: "info",
        okLabel: "Open Platform",
        cancelLabel: "Not Now",
      },
    );

    if (!openPlatform) {
      return;
    }

    await openUrl(`${getFrontendUrl(installConfig?.mode)}?install=rustdesk`);
  }

  // ============================================================
  // COMPUTER NAME
  // ============================================================

  useEffect(() => {
    (async () => {
      const saved = localStorage.getItem("computer_name");

      if (saved !== null && saved.trim() !== "") {
        return;
      }

      try {
        const info = await getSystemInfo();

        const value = info.hostname || "";

        setComputerName(value);

        localStorage.setItem("computer_name", value);
      } catch (err) {
        console.error("Failed to get system info:", err);
      }
    })();
  }, []);

  // ============================================================
  // INITIALIZE + DEEP LINKS
  // ============================================================

  useEffect(() => {
    let unlisten: (() => void) | undefined;

    (async () => {
      // Сначала поднимаем RustDesk
      // и читаем существующий token.
      await initialize();

      // Проверяем permissions.
      await checkPermissions();

      // --------------------------------------------------------
      // Приложение было запущено через deep link.
      // --------------------------------------------------------

      const urls = await getCurrent();

      if (urls?.length) {
        await handleDeepLinks(urls);
      }

      // --------------------------------------------------------
      // Приложение уже запущено,
      // а пользователь нажал deep link.
      // --------------------------------------------------------

      unlisten = await onOpenUrl(async (urls) => {
        await handleDeepLinks(urls);
      });
    })();

    return () => {
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => {
      checkForUpdates();
    }, 5000);

    return () => clearTimeout(timer);
  }, []);

  // ============================================================
  // UI
  // ============================================================

  return (
    <div className="relative flex min-h-screen bg-[radial-gradient(circle_at_top_right,_#547bb5_0%,_#2b579a_45%,_#18355f_100%)]">
      {processing && (
        <div className="absolute inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
          <div className="flex flex-col items-center gap-4">
            <div
              className="
                h-10 w-10
                animate-spin
                rounded-full
                border-4
                border-white/30
                border-t-white
              "
            />

            <span className="text-sm font-medium text-white">
              Registering your device...
            </span>
          </div>
        </div>
      )}

      <div className="flex w-full flex-col items-center justify-center gap-4 px-4 py-8">
        <div className="flex select-none flex-col items-center justify-center gap-2">
          <img
            src="/magenda-support-logo.png"
            alt="Magenda Support"
            className="h-24"
          />

          <div className="text-2xl font-medium text-white">Magenda Support</div>
        </div>

        <form
          onSubmit={(e) => {
            e.preventDefault();
          }}
          noValidate
          className="flex w-full max-w-120 flex-col gap-2 px-8"
        >
          {registration ? (
            <>
              <div>
                <label
                  htmlFor="message"
                  className="mb-1 text-sm font-bold text-white"
                >
                  Message:
                </label>

                <textarea
                  value={supportMessage}
                  onChange={(e) => {
                    setSupportMessage(e.target.value);
                  }}
                  disabled={processing}
                  id="message"
                  placeholder="Describe your issue..."
                  rows={3}
                  className="w-full resize-none rounded-lg border-gray-300 px-3 py-2 shadow-sm"
                />
              </div>

              <button
                type="button"
                onClick={handleRequest}
                disabled={
                  processing ||
                  !supportMessage.trim() ||
                  !currentRustdeskId ||
                  !installConfig
                }
                className="
                  ms-auto
                  inline-flex
                  items-center
                  justify-center
                  rounded-md
                  border-0
                  bg-[#67ae6f]
                  px-4
                  py-2
                  text-sm
                  font-medium
                  text-white
                  shadow-sm
                  transition
                  hover:opacity-90
                  focus:outline-none
                  focus:ring-0
                  disabled:cursor-not-allowed
                  disabled:opacity-50
                "
              >
                {processing ? "Sending..." : "Request Support"}
              </button>
            </>
          ) : (
            <>
              <div>
                <label
                  htmlFor="computerName"
                  className="mb-1 text-sm font-bold text-white"
                >
                  Computer name:
                </label>

                <input
                  type="text"
                  value={computerName}
                  onChange={(e) => {
                    const value = e.target.value;

                    setComputerName(value);

                    localStorage.setItem("computer_name", value);
                  }}
                  disabled={processing}
                  id="computerName"
                  placeholder="Enter computer name..."
                  className="w-full rounded-lg border-gray-300 px-3 py-2 shadow-sm"
                />
              </div>

              <div className="flex gap-4 pt-2">
                <button
                  type="button"
                  onClick={handleRegister}
                  disabled={
                    !installConfig ||
                    processing ||
                    !computerName.trim() ||
                    !currentRustdeskId
                  }
                  className="
                    ms-auto
                    inline-flex
                    items-center
                    justify-center
                    rounded-md
                    border-0
                    bg-[#67ae6f]
                    px-4
                    py-2
                    text-sm
                    font-medium
                    text-white
                    shadow-sm
                    transition
                    hover:opacity-90
                    focus:outline-none
                    focus:ring-0
                    disabled:cursor-not-allowed
                    disabled:opacity-50
                  "
                >
                  Register Device
                </button>
              </div>
            </>
          )}
        </form>

        {/* <button
          type="button"
          onClick={handleOpenRustDesk}
          className="
            inline-flex
            items-center
            justify-center
            rounded-md
            bg-white/15
            px-4
            py-2
            text-sm
            font-medium
            text-white
            transition
            hover:bg-white/20
          "
        >
          Open RustDesk
        </button> */}

        {/* <div className="w-full max-w-md rounded-xl bg-white/10 p-5 text-white">
          <h2 className="text-lg font-semibold">RustDesk permissions</h2>

          <div className="mt-4 flex flex-col gap-3">
            <div className="flex items-center justify-between gap-4">
              <span>Accessibility</span>

              <div className="flex items-center gap-2">
                {permissions && (
                  <span className="text-xs text-white/70">
                    {permissions.accessibility ? "Granted" : "Required"}
                  </span>
                )}

                <button
                  type="button"
                  onClick={() => invoke("open_accessibility_settings")}
                  className="rounded-md bg-white/15 px-3 py-1.5 text-sm"
                >
                  Open Settings
                </button>
              </div>
            </div>

            <div className="flex items-center justify-between gap-4">
              <span>Screen Recording</span>

              <div className="flex items-center gap-2">
                {permissions && (
                  <span className="text-xs text-white/70">
                    {permissions.screen_recording ? "Granted" : "Required"}
                  </span>
                )}

                <button
                  type="button"
                  onClick={() => invoke("open_screen_recording_settings")}
                  className="rounded-md bg-white/15 px-3 py-1.5 text-sm"
                >
                  Open Settings
                </button>
              </div>
            </div>

            <div className="flex items-center justify-between gap-4">
              <span>Input Monitoring</span>

              <div className="flex items-center gap-2">
                {permissions && (
                  <span className="text-xs text-white/70">
                    {permissions.input_monitoring ? "Granted" : "Required"}
                  </span>
                )}

                <button
                  type="button"
                  onClick={() => invoke("open_input_monitoring_settings")}
                  className="rounded-md bg-white/15 px-3 py-1.5 text-sm"
                >
                  Open Settings
                </button>
              </div>
            </div>
          </div>

          <button
            type="button"
            onClick={checkPermissions}
            className="mt-5 rounded-md bg-white px-4 py-2 text-sm font-medium text-[#2b579a]"
          >
            Check again
          </button>
        </div> */}
      </div>
    </div>
  );
}

export default App;

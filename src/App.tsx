import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { message } from "@tauri-apps/plugin-dialog";
import { getCurrent, onOpenUrl } from "@tauri-apps/plugin-deep-link";

import { getSystemInfo } from "./system";
import { getInstallTokenFromUrl } from "./deepLink";

import "./App.css";

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

  const [clinicToken, setClinicToken] = useState("");

  const [currentRustdeskId, setCurrentRustdeskId] = useState("");

  const [permissions, setPermissions] =
    useState<RustDeskPermissionsStatus | null>(null);

  const [status, setStatus] = useState<RustDeskStatus | null>(null);

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
      // --------------------------------------------------------
      // Install token
      // --------------------------------------------------------

      const installToken = await invoke<string | null>("get_install_token");

      if (installToken?.trim()) {
        setClinicToken(installToken.trim());
      }

      // --------------------------------------------------------
      // RustDesk status
      // --------------------------------------------------------

      let rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");

      if (!isRustDeskHealthy(rustdeskStatus)) {
        console.log(
          "RustDesk is not healthy. Starting repair/configuration...",
        );

        await invoke("configure_rustdesk");

        rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");
      }

      if (!isRustDeskHealthy(rustdeskStatus)) {
        throw new Error("RustDesk configuration is incomplete.");
      }

      setStatus(rustdeskStatus);

      setCurrentRustdeskId(rustdeskStatus.id!.trim());
    } catch (err) {
      // Не сбрасываем clinicToken:
      // ошибка RustDesk не означает,
      // что install token недействителен.

      setCurrentRustdeskId("");
      setStatus(null);

      const msg = getErrorMessage(err, "Failed to initialize the application.");

      console.error("Initialization failed:", err);

      await message(msg, {
        title: "Configuration error",
        kind: "error",
      });
    }
  }

  // ============================================================
  // REGISTER DEVICE
  // ============================================================

  async function registerDevice(token: string) {
    const cleanToken = token.trim();

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

    const response = await fetch(
      `${import.meta.env.VITE_BACKEND_URL}/rustdesk/devices`,
      {
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
      },
    );

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
    if (!clinicToken || !computerName.trim()) {
      return;
    }

    try {
      setProcessing(true);

      await registerDevice(clinicToken);

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
      const token = getInstallTokenFromUrl(url);

      if (!token) {
        continue;
      }

      try {
        setProcessing(true);

        console.log("Received install token from deep link.");

        // Сохраняем token локально.
        await invoke("save_install_token", {
          token,
        });

        setClinicToken(token);

        // Автоматически регистрируем
        // устройство после deep link.
        await registerDevice(token);

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

  async function handleOpenRustDesk() {
    try {
      await invoke("open_rustdesk");
    } catch (err) {
      const msg = getErrorMessage(err, "Failed to open RustDesk.");

      await message(msg, {
        title: "RustDesk",
        kind: "error",
      });
    }
  }

  // ============================================================
  // SUPPORT REQUEST
  // ============================================================

  async function handleRequest() {
    //
    // TODO:
    // POST support request
    //
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
                  processing || !supportMessage.trim() || !currentRustdeskId
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
                Request Support
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
                    !clinicToken ||
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

        {import.meta.env.DEV && (
          <pre className="max-w-full overflow-auto text-xs text-white">
            {JSON.stringify(
              {
                registration,
                computerName,
                clinicToken,
                currentRustdeskId,
                supportMessage,
                permissions,
                status,
              },
              null,
              2,
            )}
          </pre>
        )}
      </div>
    </div>
  );
}

export default App;

import { useEffect, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { message, confirm } from "@tauri-apps/plugin-dialog";
import { isRustDeskInstalled, getRustDeskId, openRustDesk } from "./rustdesk";
import { getAppConfig, type AppConfig } from "./getAppConfig";
import { getSystemInfo } from "./system";
import { debugLog } from "./debugLog";
import { sleep } from "./sleep";
import { installRustDesk } from "./installer";

import "./App.css";

function App() {
  const [hostname, setHostname] = useState(() => {
    const saved = localStorage.getItem("hostname");

    return saved !== null ? JSON.parse(saved) : "";
  });

  const [processing, setProcessing] = useState(false);
  const [installed, setInstalled] = useState(false);
  const [config, setConfig] = useState<AppConfig | null>(null);

  async function handleInstall({ reinstall = false } = {}) {
    if (!config) return;

    const confirmation = reinstall
      ? await confirm(
          "Are you sure you want to reinstall RustDesk with Magendamd settings?",
          {
            title: "Reinstall RustDesk",
            kind: "warning",
          },
        )
      : true;

    if (!confirmation) return;

    try {
      setProcessing(true);

      await debugLog("=== RustDesk installation started ===");
      await installRustDesk(config);
      await debugLog("=== RustDesk installer finished ===");
      await sleep(3000);

      const rustdeskId = await getRustDeskId();

      if (!rustdeskId) {
        throw new Error("Failed to get RustDesk ID");
      }

      await debugLog(`RustDesk ID: ${rustdeskId}`);

      const response = await fetch(`${config.api}/rustdesk/devices`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-RustDesk-Key": config.token,
        },
        body: JSON.stringify({
          device_id: rustdeskId,
          password: config.password,
          name: hostname,
        }),
      });

      if (!response.ok) {
        throw new Error(`Failed to register device: ${response.status}`);
      }

      await debugLog("=== Device registered ===");
      await message(
        "RustDesk has been successfully installed and configured.",
        {
          title: "Installation completed",
          kind: "info",
        },
      );

      setInstalled(true);
    } catch (err) {
      const msg =
        err instanceof Error ? err.message : "RustDesk installation error";

      await debugLog(`INSTALL ERROR: ${msg}`);
      await message(msg, {
        title: "Installation error",
        kind: "error",
      });
    } finally {
      setProcessing(false);
    }
  }

  async function handleOpen() {
    await openRustDesk();
  }

  const handleClose = async () => {
    await getCurrentWindow().close();
  };

  useEffect(() => {
    (async () => {
      if (
        localStorage.getItem("hostname") === null ||
        (localStorage.getItem("hostname") !== null &&
          JSON.parse(localStorage.getItem("hostname") as string) === "")
      ) {
        const info = await getSystemInfo();
        const value = info.hostname || "";

        setHostname(value);
        localStorage.setItem("hostname", JSON.stringify(value));
      }
    })();

    initialize();
  }, []);

  async function initialize() {
    try {
      const config = await getAppConfig();

      setConfig(config);
    } catch (err) {
      setConfig(null);

      const msg =
        err instanceof Error
          ? err.message
          : "Failed to get RustDesk configuration.";

      await debugLog(msg);
      await message(msg, {
        title: "Configuration error",
        kind: "error",
      });

      return;
    }

    try {
      const installed = await isRustDeskInstalled();

      if (!installed) {
        setInstalled(false);
        return;
      }

      setInstalled(true);

      await message("RustDesk is already installed on this computer.", {
        title: "RustDesk",
        kind: "warning",
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : "";

      await debugLog(msg);
    }
  }

  return (
    <div className="relative flex flex-col gap-8 items-center justify-center min-h-screen">
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
              {installed
                ? "Reinstalling RustDesk..."
                : "Installing RustDesk..."}
            </span>
          </div>
        </div>
      )}

      <div className="relative select-none">
        <img src="/logo-white.png" alt="App Logo" className="h-18" />

        <div className="absolute right-0 -bottom-1.5 text-base font-medium text-white tracking-[2px]">
          RustDesk Setup
        </div>
      </div>

      <form
        onSubmit={(e) => {
          e.stopPropagation();
          e.preventDefault();
        }}
        noValidate
        className="w-full max-w-120 flex flex-col gap-2 px-8"
      >
        <div>
          <label
            htmlFor="hostname"
            className="font-bold text-white text-sm mb-1"
          >
            Desktop:
          </label>

          <input
            type="text"
            value={hostname}
            onChange={(e) => {
              const val = e.target.value;

              setHostname(val);
              localStorage.setItem("hostname", JSON.stringify(val));
            }}
            disabled={processing}
            id="hostname"
            placeholder="Enter Computer Name..."
            className="w-full rounded-lg border-gray-300 px-3 py-2 shadow-sm"
          />
        </div>

        <div className="flex gap-4 pt-2">
          {installed && (
            <button
              type="button"
              onClick={() => handleInstall({ reinstall: true })}
              disabled={!config || processing || !hostname}
              className="
              inline-flex items-center justify-center
              rounded-md
              border-0
              bg-[#e44262]
              px-4 py-2
              text-sm font-medium text-white
              shadow-sm
              transition
              hover:opacity-90
              focus:outline-none
              focus:ring-0
              disabled:cursor-not-allowed
              disabled:opacity-50
            "
            >
              {processing ? "Reinstalling..." : "Reinstall"}
            </button>
          )}

          {/* <button
            type="button"
            onClick={handleClose}
            disabled={processing}
            className="
              inline-flex items-center justify-center
              rounded-md
              border-0
              bg-[#e44262]
              px-4 py-2
              text-sm font-medium text-white
              shadow-sm
              transition
              hover:opacity-90
              focus:outline-none
              focus:ring-0
              disabled:cursor-not-allowed
              disabled:opacity-50
            "
          >
            Close
          </button> */}

          {installed ? (
            <button
              type="button"
              onClick={handleOpen}
              disabled={processing}
              className="
                inline-flex items-center justify-center
                rounded-md
                border-0
                bg-[#67ae6f]
                px-4 py-2
                text-sm font-medium text-white
                shadow-sm
                transition
                hover:opacity-90
                focus:outline-none
                focus:ring-0
                disabled:cursor-not-allowed
                disabled:opacity-50
                ms-auto
              "
            >
              Open
            </button>
          ) : (
            <button
              type="button"
              onClick={() => handleInstall()}
              disabled={!config || processing || !hostname}
              className="
                inline-flex items-center justify-center
                rounded-md
                border-0
                bg-[#67ae6f]
                px-4 py-2
                text-sm font-medium text-white
                shadow-sm
                transition
                hover:opacity-90
                focus:outline-none
                focus:ring-0
                disabled:cursor-not-allowed
                disabled:opacity-50
                ms-auto
              "
            >
              {processing ? "Installing..." : "Install"}
            </button>
          )}
        </div>
      </form>
    </div>
  );
}

export default App;

import { useEffect, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { message, ask } from "@tauri-apps/plugin-dialog";
import { platform } from "@tauri-apps/plugin-os";
import {
  isRustDeskInstalled,
  getRustDeskId,
  // openRustDesk,
  restartRustDesk,
  killRustDesk,
  getRustDeskConfig,
} from "./rustdesk";
import { setRustDeskPasswordMacOS } from "./os/macos-elevated";
import { setRustDeskPasswordWindows } from "./os/windows-elevated";
import { installRustDesk, uninstallRustDesk } from "./installer";
import {
  configureRustDeskMacOS,
  verifyRustDeskMacOSConfig,
} from "./os/rustdesk-config";
import { getAccessToken } from "./installer-token";
import { getSystemInfo } from "./system";
import { sleep } from "./sleep";
import { debugLog } from "./debugLog";

import "./App.css";

function App() {
  const [hostname, setHostname] = useState("");
  const [token, setToken] = useState("");
  const [processing, setProcessing] = useState(false);
  const [installed, setInstalled] = useState(false);
  const [config, setConfig] = useState<{
    rendezvousServer: string;
    relayServer: string;
    key: string;
    password: string;
  } | null>(null);

  async function handleInstall() {
    if (!config || !token) return;

    try {
      setProcessing(true);

      const os = platform();

      await debugLog("=== 1. Install RustDesk ===");

      await installRustDesk();

      await debugLog("=== 2. Wait after install ===");

      await sleep(2000);

      if (os === "macos") {
        await debugLog("=== macOS configuration ===");

        await setRustDeskPasswordMacOS(config.password);

        await debugLog("Password configured");

        await configureRustDeskMacOS(config);

        await debugLog("Config written");

        const ok = await verifyRustDeskMacOSConfig(config);

        await debugLog(`Config verification: ${ok}`);

        if (!ok) {
          throw new Error("RustDesk configuration verification failed");
        }
      }

      if (os === "windows") {
        // await debugLog("=== Windows configuration ===");
        // await setRustDeskPasswordWindows(config.password);
        // await debugLog("Password configured");
        // Пока конфигурацию не включаем
        // await configureRustDeskWindows(config);
        // const ok = await verifyRustDeskWindowsConfig(config);
        // if (!ok) {
        //   throw new Error(
        //     "RustDesk configuration verification failed",
        //   );
        // }
      }

      await debugLog("=== 3. Restart RustDesk ===");

      await restartRustDesk();

      await debugLog("=== 4. Wait after restart ===");

      await sleep(3000);

      await debugLog("=== 5. Get RustDesk ID ===");

      const rustdeskId = await getRustDeskId();

      await debugLog("=== 6. Register device ===");

      const response = await fetch(
        `${import.meta.env.VITE_BACKEND_URL}/rustdesk/devices`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-RustDesk-Key": token,
          },
          body: JSON.stringify({
            device_id: rustdeskId,
            password: config.password,
            name: hostname,
          }),
        },
      );

      if (!response.ok) {
        throw new Error(
          `Failed to register RustDesk device: ${response.status}`,
        );
      }

      await debugLog("Device registered");

      await message("RustDesk успешно установлен и настроен.", {
        title: "Установка завершена",
        kind: "info",
      });

      await getCurrentWindow().close();
    } catch (err) {
      const msg =
        err instanceof Error
          ? err.message
          : "Произошла ошибка во время установки RustDesk.";

      await debugLog(msg);
      await message(msg, {
        title: "Ошибка установки",
        kind: "error",
      });
    } finally {
      setProcessing(false);
    }
  }

  async function handleReinstall() {
    if (!config) return;

    const confirmed = await ask(
      "RustDesk уже установлен.\n\nТекущая установка будет удалена и установлена заново. Продолжить?",
      {
        title: "Переустановка RustDesk",
        kind: "warning",
        okLabel: "Reinstall",
        cancelLabel: "Отмена",
      },
    );

    if (!confirmed) {
      return;
    }

    try {
      setProcessing(true);

      const os = platform();

      await debugLog("=== 1. Kill RustDesk ===");
      await killRustDesk();

      await debugLog("=== 2. Uninstall RustDesk ===");
      await uninstallRustDesk();

      await debugLog("=== 3. Wait after uninstall ===");
      await sleep(2000);

      await debugLog("=== 4. Install RustDesk ===");
      await installRustDesk();

      await debugLog("=== 5. Wait after install ===");
      await sleep(2000);

      if (os === "macos") {
        await debugLog("=== macOS configuration ===");

        await setRustDeskPasswordMacOS(config.password);

        await debugLog("Password configured");

        await configureRustDeskMacOS(config);

        await debugLog("Config written");

        const ok = await verifyRustDeskMacOSConfig(config);

        await debugLog(`Config verification: ${ok}`);

        if (!ok) {
          throw new Error("RustDesk configuration verification failed");
        }
      }

      if (os === "windows") {
        // await debugLog("=== Windows configuration ===");
        // await setRustDeskPasswordWindows(config.password);
        // await debugLog("Password configured");
        // Пока конфигурацию не включаем
        // await configureRustDeskWindows(config);
        // const ok = await verifyRustDeskWindowsConfig(config);
        // if (!ok) {
        //   throw new Error(
        //     "RustDesk configuration verification failed",
        //   );
        // }
      }

      await debugLog("=== 6. Restart RustDesk ===");

      await restartRustDesk();

      await debugLog("=== 7. Wait after restart ===");

      await sleep(3000);

      await debugLog("=== 8. Get RustDesk ID ===");

      const rustdeskId = await getRustDeskId();

      await message(
        `RustDesk успешно переустановлен и настроен.\n\nID: ${rustdeskId}`,
        {
          title: "Переустановка завершена",
          kind: "info",
        },
      );

      await getCurrentWindow().close();
    } catch (err) {
      const msg =
        err instanceof Error
          ? err.message
          : "Не удалось переустановить RustDesk.";

      await debugLog(msg);
      await message(msg, {
        title: "Ошибка переустановки",
        kind: "error",
      });
    } finally {
      setProcessing(false);
    }
  }

  const handleClose = async () => {
    await getCurrentWindow().close();
  };

  // const handleRun = async () => {
  //   await killRustDesk();
  //   await openRustDesk();
  // };

  useEffect(() => {
    (async () => {
      const info = await getSystemInfo();

      setHostname(info.hostname || "");

      // console.log("MODE:", import.meta.env.MODE);
      // console.log("FRONTEND_URL:", import.meta.env.VITE_FRONTEND_URL);
      // console.log("BACKEND_URL:", import.meta.env.VITE_BACKEND_URL);
    })();

    initialize();

    getAccessToken()
      .then((token) => setToken(token))
      .catch((err) => {
        setToken("");
        debugLog(err);
      });
  }, []);

  async function initialize() {
    try {
      const config = await getRustDeskConfig();

      setConfig(config);
    } catch (err) {
      setConfig(null);

      const msg =
        err instanceof Error
          ? err.message
          : "Не удалось переустановить RustDesk.";

      await debugLog(msg);
      await message(
        "Не удалось подключиться к серверу.\n\nПроверьте подключение к интернету и попробуйте снова.",
        {
          title: "Нет подключения",
          kind: "error",
        },
      );

      return;
    }

    try {
      const installed = await isRustDeskInstalled();

      if (!installed) {
        setInstalled(false);
        return;
      }

      setInstalled(true);

      await message("RustDesk уже установлен на этом компьютере.", {
        title: "RustDesk",
        kind: "warning",
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : "";

      await debugLog(msg);
    }
  }

  return (
    <div className="flex flex-col gap-8 items-center justify-center min-h-screen">
      <div className="relative select-none">
        <img src="/logo-white.png" alt="App Logo" className="h-[72px]" />
        <div className="absolute right-0 -bottom-1.5 text-base font-medium text-white tracking-[2px]">
          RustDesk Setup
        </div>
      </div>

      <form className="min-w-100 flex flex-col gap-2">
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
            onChange={(e) => setHostname(e.target.value)}
            disabled={processing}
            id="hostname"
            className="w-full rounded-lg border-gray-300 px-3 py-2 shadow-sm"
          />
        </div>

        <div className="flex gap-4 justify-end pt-2">
          <button
            type="button"
            onClick={handleClose}
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
              focus:border-0
              disabled:cursor-not-allowed
              disabled:opacity-50
            "
          >
            Close
          </button>

          {installed ? (
            <button
              type="button"
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
              focus:border-0
              disabled:cursor-not-allowed
              disabled:opacity-50
            "
              // onClick={handleRun}
              onClick={handleReinstall}
              disabled={!config || processing}
            >
              {processing ? "Reinstalling..." : false ? "Run" : "Reinstall"}
            </button>
          ) : (
            <button
              type="button"
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
              focus:border-0
              disabled:cursor-not-allowed
              disabled:opacity-50
            "
              onClick={handleInstall}
              disabled={!config || processing}
            >
              {processing ? "Installing..." : "Install"}
            </button>
          )}
        </div>

        <pre>{JSON.stringify({ config, token }, null, 2)}</pre>
      </form>
    </div>
  );
}

export default App;

import { useEffect, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { message, ask } from "@tauri-apps/plugin-dialog";
import { platform } from "@tauri-apps/plugin-os";
import {
  isRustDeskInstalled,
  getRustDeskId,
  openRustDesk,
  restartRustDesk,
  killRustDesk,
  getRustDeskConfig,
  // setRustDeskPassword,
} from "./rustdesk";
import { setRustDeskPasswordMacOS } from "./os/macos-elevated";
// import { setRustDeskPasswordWindows } from "./os/windows-elevated";
import { installRustDesk, uninstallRustDesk } from "./installer";
import {
  configureRustDeskMacOS,
  verifyRustDeskMacOSConfig,
} from "./os/rustdesk-config";
import { getAccessToken } from "./installer-token";
import { getSystemInfo } from "./system";

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
  } | null>(null);
  const password = "Qaz123456";

  async function handleInstall() {
    if (!config || !token) return;

    try {
      setProcessing(true);

      const os = platform();

      await installRustDesk();

      // await killRustDesk();
      await restartRustDesk();

      // Даём service время подняться
      await new Promise((resolve) => setTimeout(resolve, 2000));

      if (os === "macos") {
        await setRustDeskPasswordMacOS(password);
        await configureRustDeskMacOS(config);

        const ok = await verifyRustDeskMacOSConfig(config);

        if (!ok) {
          throw new Error("RustDesk configuration verification failed");
        }
      }

      // if (os === "windows") {
      //   await setRustDeskPassword(password); // setRustDeskPasswordWindows
      //   await configureRustDeskWindows(config);

      //   const ok = await verifyRustDeskWindowsConfig(config);

      //   if (!ok) {
      //     throw new Error("RustDesk configuration verification failed");
      //   }
      // }

      await restartRustDesk();

      // Ждём запуска
      await new Promise((resolve) => setTimeout(resolve, 2000));

      const rustdeskId = await getRustDeskId();

      await fetch(`${import.meta.env.VITE_BACKEND_URL}/rustdesk/devices`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-RustDesk-Key": token,
        },
        body: JSON.stringify({
          device_id: rustdeskId,
          password: password,
          name: hostname,
        }),
      });

      console.log("rustdeskId >>>", rustdeskId);

      await message("RustDesk успешно установлен и настроен.", {
        title: "Установка завершена",
        kind: "info",
      });

      // await getCurrentWindow().close();
    } catch (error) {
      console.error(error);

      await message(
        error instanceof Error
          ? error.message
          : "Произошла ошибка во время установки RustDesk.",
        {
          title: "Ошибка установки",
          kind: "error",
        },
      );
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

      // Останавливаем текущий RustDesk
      await killRustDesk();

      // Удаляем
      await uninstallRustDesk();

      // Устанавливаем заново
      await installRustDesk();

      // Останавливаем новую установку
      // await killRustDesk();
      await restartRustDesk();

      // Даём service время подняться
      await new Promise((resolve) => setTimeout(resolve, 2000));

      // Конфигурация
      if (os === "macos") {
        await setRustDeskPasswordMacOS(password);
        await configureRustDeskMacOS(config);

        const ok = await verifyRustDeskMacOSConfig(config);

        if (!ok) {
          throw new Error("RustDesk configuration verification failed");
        }
      }

      // if (os === "windows") {
      //   await setRustDeskPassword(password); // setRustDeskPasswordWindows
      //   await configureRustDeskWindows(config);

      //   const ok = await verifyRustDeskWindowsConfig(config);

      //   if (!ok) {
      //     throw new Error("RustDesk configuration verification failed");
      //   }
      // }

      // Запускаем
      await restartRustDesk();

      // Ждём запуска
      await new Promise((resolve) => setTimeout(resolve, 2000));

      // Получаем ID
      const rustdeskId = await getRustDeskId();

      console.log("rustdeskId >>>", rustdeskId);

      // Успешно
      await message(
        `RustDesk успешно переустановлен и настроен.\n\nID: ${rustdeskId}`,
        {
          title: "Переустановка завершена",
          kind: "info",
        },
      );

      await getCurrentWindow().close();
    } catch (error) {
      console.error("RustDesk reinstall failed:", error);

      await message(
        error instanceof Error
          ? error.message
          : "Не удалось переустановить RustDesk.",
        {
          title: "Ошибка переустановки",
          kind: "error",
        },
      );
    } finally {
      setProcessing(false);
    }
  }

  const handleClose = async () => {
    await getCurrentWindow().close();
  };

  const handleRun = async () => {
    await killRustDesk();
    await openRustDesk();
  };

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
      .catch((err) => setToken(err));
  }, []);

  async function initialize() {
    // 1. Проверяем backend / интернет

    try {
      const config = await getRustDeskConfig();

      setConfig(config);
    } catch (error) {
      console.error("Network check failed:", error);

      setConfig(null);

      await message(
        "Не удалось подключиться к серверу.\n\nПроверьте подключение к интернету и попробуйте снова.",
        {
          title: "Нет подключения",
          kind: "error",
        },
      );

      return;
    }

    // 2. Проверяем установлен ли RustDesk

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
    } catch (error) {
      console.error("RustDesk check failed:", error);
    }
  }

  return (
    <div className="flex flex-col gap-8 items-center justify-center min-h-screen">
      <div className="relative select-none">
        <img src="/logo-white.png" alt="App Logo" className="h-[72px]" />
        <div className="absolute right-0 -bottom-1.5 text-base font-medium text-white tracking-[2.75px]">
          Remote Setup
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

        <pre>{JSON.stringify({ token, config }, null, 2)}</pre>
      </form>
    </div>
  );
}

export default App;

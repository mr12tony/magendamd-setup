import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { message } from "@tauri-apps/plugin-dialog";
import { getRustDeskId } from "./rustdesk";
import { getSystemInfo } from "./system";

import "./App.css";

function App() {
  const [hostname, setHostname] = useState(() => {
    const saved = localStorage.getItem("hostname");

    return saved !== null ? JSON.parse(saved) : "";
  });

  const [processing, setProcessing] = useState(false);
  const [token, setToken] = useState("");
  const [rustdeskId, setRustdeskId] = useState("");

  async function handleInstall() {
    if (!token || !hostname) return;

    try {
      setProcessing(true);

      const currentRustdeskId = await getRustDeskId();

      if (!currentRustdeskId?.trim()) {
        throw new Error("Failed to get RustDesk ID.");
      }

      const response = await fetch(
        `${import.meta.env.VITE_BACKEND_URL}/rustdesk/devices`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-RustDesk-Key": token,
          },
          body: JSON.stringify({
            device_id: currentRustdeskId,
            password: import.meta.env.VITE_PERMANENT_PASSWORD,
            name: hostname.trim(),
          }),
        },
      );

      if (!response.ok) {
        throw new Error(
          `Failed to register device. Server returned HTTP ${response.status}.`,
        );
      }

      setRustdeskId(currentRustdeskId);

      await message("The device has been registered successfully.", {
        title: "Registration completed",
        kind: "info",
      });
    } catch (err) {
      let msg: string;

      if (err instanceof Error) {
        msg = err.message;
      } else if (typeof err === "string") {
        msg = err;
      } else {
        msg = "Failed to register the device.";
      }

      await message(msg, {
        title: "Device registration error",
        kind: "error",
      });
    } finally {
      setProcessing(false);
    }
  }

  async function initialize() {
    try {
      const installToken = await invoke<string>("get_install_token");

      if (!installToken?.trim()) {
        throw new Error("Installation token is missing or empty.");
      }

      setToken(installToken.trim());

      const currentRustdeskId = await getRustDeskId();

      if (!currentRustdeskId?.trim()) {
        throw new Error("Failed to get RustDesk ID.");
      }

      setRustdeskId(currentRustdeskId.trim());
    } catch (err) {
      setToken("");
      setRustdeskId("");

      let msg: string;

      if (err instanceof Error) {
        msg = err.message;
      } else if (typeof err === "string") {
        msg = err;
      } else {
        msg = "Failed to initialize the application.";
      }

      console.error("Initialization failed:", err);

      await message(msg, {
        title: "Configuration error",
        kind: "error",
      });
    }
  }

  useEffect(() => {
    (async () => {
      const savedHostname = localStorage.getItem("hostname");

      if (savedHostname === null || JSON.parse(savedHostname) === "") {
        const info = await getSystemInfo();
        const value = info.hostname || "";

        setHostname(value);
        localStorage.setItem("hostname", JSON.stringify(value));
      }
    })();

    initialize();
  }, []);

  return (
    <div className="relative flex min-h-screen flex-col items-center justify-center gap-8">
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
              Registering RustDesk device...
            </span>
          </div>
        </div>
      )}

      <div className="relative select-none">
        <img src="/logo-white.png" alt="App logo" className="h-18" />

        <div className="absolute right-0 -bottom-1.5 text-base font-medium tracking-[2px] text-white">
          RustDesk Setup
        </div>
      </div>

      <form
        onSubmit={(e) => {
          e.preventDefault();
        }}
        noValidate
        className="flex w-full max-w-120 flex-col gap-2 px-8"
      >
        <div>
          <label
            htmlFor="hostname"
            className="mb-1 text-sm font-bold text-white"
          >
            Computer name:
          </label>

          <input
            type="text"
            value={hostname}
            onChange={(e) => {
              const value = e.target.value;

              setHostname(value);
              localStorage.setItem("hostname", JSON.stringify(value));
            }}
            disabled={processing}
            id="hostname"
            placeholder="Enter computer name..."
            className="w-full rounded-lg border-gray-300 px-3 py-2 shadow-sm"
          />
        </div>

        <div className="flex gap-4 pt-2">
          <button
            type="button"
            onClick={handleInstall}
            disabled={!token || processing || !hostname.trim()}
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
      </form>
    </div>
  );
}

export default App;

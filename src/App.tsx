import { useEffect, useState, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { message, ask } from "@tauri-apps/plugin-dialog";
import { getCurrent, onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { platform } from "@tauri-apps/plugin-os";
import { getSystemInfo } from "./system";
import { getInstallConfigFromUrl } from "./deepLink";
import { RegistrationQueue } from "./registrationQueue";

import "./App.css";

const REQUIRED_RUSTDESK_VERSION = "1.5.0";

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

function hasRequiredRustDeskVersion(status: RustDeskStatus) {
  const version = status.version?.trim().match(/^(\d+\.\d+\.\d+)(?:$|[.+-])/)?.[1];
  return status.installed && version === REQUIRED_RUSTDESK_VERSION;
}

function assertRequiredRustDeskVersion(status: RustDeskStatus) {
  if (!hasRequiredRustDeskVersion(status)) {
    throw new Error(
      `RustDesk ${REQUIRED_RUSTDESK_VERSION} installation or update did not complete. Please try again.`,
    );
  }
}

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

type InstallerLaunch = {
  request_id: number;
  config: InstallConfig | null;
  error: string | null;
};

// function getBackendUrl(mode: InstallMode) {
//   switch (mode) {
//     case "dev":
//       return "https://apidev.magendamd.com/api/v1";

//     case "prod":
//       return "https://api.magendamd.com/api/v1";

//     case "local":
//       return "http://127.0.0.1:8000/api/v1";
//   }
// }

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

async function lockWindow() {
  const window = getCurrentWindow();

  await window.setClosable(false);
  await window.setMinimizable(false);
  await window.setMaximizable(false);
  await window.setResizable(false);
}

async function unlockWindow() {
  const window = getCurrentWindow();

  await window.setClosable(true);
  await window.setMinimizable(true);
  await window.setMaximizable(true);
  await window.setResizable(true);
}

async function closeWindow() {
  const window = getCurrentWindow();

  await window.close();
}

async function showWindow() {
  await unlockWindow();
  const window = getCurrentWindow();
  await window.show();
  await window.unminimize();
  await window.setFocus();
}

function App() {
  const [registration, setRegistration] = useState<RegistrationData | null>(
    null,
  );

  const [computerName, setComputerName] = useState("");

  // const [supportMessage, setSupportMessage] = useState("");

  const [processing, setProcessing] = useState(false);

  const [missingInstallToken, setMissingInstallToken] = useState(false);

  const [installConfig, setInstallConfig] = useState<InstallConfig | null>(
    null,
  );

  // A failed candidate stays in memory for Retry; installConfig is the active config.
  const [pendingConfig, setPendingConfig] = useState<InstallConfig | null>(
    null,
  );
  const [connectionError, setConnectionError] = useState<
    string | null
  >(null);
  const registrationQueue = useRef(new RegistrationQueue()).current;
  const lastInstallerRequest = useRef(0);

  const [, /*currentRustdeskId*/ setCurrentRustdeskId] = useState("");

  const [, setPermissions] = useState<RustDeskPermissionsStatus | null>(null);

  const [status, setStatus] = useState<RustDeskStatus | null>(null);

  // function canRegisterRustDesk(value: RustDeskStatus) {
  //   return value.installed && !!value.id?.trim();
  // }

  async function loadRegistrationState() {
    const saved = await invoke<RegistrationData | null>(
      "get_registration_state",
    );

    setRegistration(saved);

    if (saved) {
      setCurrentRustdeskId(saved.currentRustdeskId);
    }

    return saved;
  }

  async function ensureComputerName() {
    const current = computerName.trim();

    if (current) {
      return current;
    }

    try {
      const saved = await invoke<RegistrationData | null>(
        "get_registration_state",
      );

      const savedName = saved?.computerName?.trim();

      if (savedName) {
        setComputerName(savedName);
        return savedName;
      }
    } catch {
      // Состояние регистрации недоступно — пробуем hostname.
    }

    let name = "";

    try {
      const info = await getSystemInfo();
      name = info.hostname?.trim() ?? "";
    } catch {
      // Ниже вернём понятную ошибку без системных подробностей.
    }

    if (!name) {
      throw new Error("Please enter a computer name.");
    }

    setComputerName(name);

    return name;
  }

  async function checkForUpdates() {
    if (registrationQueue.busy || pendingConfig || connectionError) {
      return;
    }

    const version = registrationQueue.version;
    try {
      const update = await invoke<UpdateInfo>("check_for_updates");

      if (registrationQueue.busy || version !== registrationQueue.version) {
        return;
      }

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

      if (
        !install ||
        registrationQueue.busy ||
        version !== registrationQueue.version
      ) {
        return;
      }

      setProcessing(true);

      await invoke("download_and_install_update");
    } catch (err) {
      console.error("Updater failed:", err);
    } finally {
      if (!registrationQueue.busy) {
        setProcessing(false);
      }
    }
  }

  // ============================================================
  // HELPERS
  // ============================================================

  function isRustDeskHealthy(value: RustDeskStatus) {
    return (
      hasRequiredRustDeskVersion(value) &&
      value.service_running &&
      value.configured &&
      !!value.id?.trim()
    );
  }

  // function getRustDeskHealthProblems(value: RustDeskStatus) {
  //   const problems: string[] = [];

  //   if (!value.installed) {
  //     problems.push("RustDesk is not installed");
  //   }

  //   if (!value.version?.startsWith("1.4.9")) {
  //     problems.push(
  //       `Unexpected RustDesk version: ${value.version ?? "unknown"}`,
  //     );
  //   }

  //   if (!value.service_running) {
  //     problems.push("RustDesk service is not running");
  //   }

  //   if (!value.configured) {
  //     problems.push("RustDesk configuration is invalid");
  //   }

  //   if (!value.id?.trim()) {
  //     problems.push("RustDesk ID is missing");
  //   }

  //   return problems;
  // }

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

  async function initialize(skipMissingTokenScreen = false) {
    const isMacOS = platform() === "macos";

    try {
      const config = await invoke<InstallConfig | null>(
        isMacOS && !skipMissingTokenScreen
          ? "initialize_install_config"
          : "get_install_config",
      );

      if (config?.install_token?.trim()) {
        setInstallConfig(config);
        setMissingInstallToken(false);

        await unlockWindow();

        let saved: RegistrationData | null = null;

        try {
          saved = await loadRegistrationState();
        } catch {
          // Config прочитан успешно, но состояние регистрации недоступно.
          // Не сбрасываем installConfig и не показываем отсутствие токена.
          setRegistration(null);
        }

        let name = saved?.computerName?.trim() ?? "";

        if (!name) {
          try {
            const info = await getSystemInfo();
            name = info.hostname?.trim() ?? "";
          } catch {
            // Пользователь сможет ввести имя вручную.
            name = "";
          }
        }

        setComputerName(name);
      } else {
        setInstallConfig(null);
        setRegistration(null);
        setComputerName("");

        if (skipMissingTokenScreen) {
          setMissingInstallToken(false);
        } else {
          setMissingInstallToken(true);
        }

        if (!skipMissingTokenScreen) {
          await lockWindow();
        }
      }
    } catch (err) {
      // A manual candidate can repair a missing or unreadable active config.
      if (skipMissingTokenScreen) {
        return;
      }

      const msg = getErrorMessage(err, "Failed to initialize the application.");

      if (isMacOS) {
        setInstallConfig(null);
        setMissingInstallToken(true);
        await unlockWindow();
      }

      await message(msg, {
        title: "Configuration error",
        kind: "error",
      });
    }
  }

  // ============================================================
  // REGISTER DEVICE
  // ============================================================

  async function registerDevice(config: InstallConfig, requestedName?: string) {
    if (!config.install_token.trim()) {
      throw new Error("Installation token is missing.");
    }

    const name = requestedName ?? await ensureComputerName();

    let rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");

    if (!isRustDeskHealthy(rustdeskStatus)) {
      await invoke("configure_rustdesk");

      rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");
    }

    if (platform() === "macos") {
      assertRequiredRustDeskVersion(rustdeskStatus);
    }

    setStatus(rustdeskStatus);

    const registrationData = await invoke<RegistrationData>("register_device", {
      computerName: name,
      token: config.install_token,
      mode: config.mode,
    });

    setInstallConfig(config);
    setMissingInstallToken(false);
    setRegistration(registrationData);
    setComputerName(registrationData.computerName);
    setCurrentRustdeskId(registrationData.currentRustdeskId);

    return registrationData;
  }

  // ============================================================
  // MANUAL REGISTER
  // ============================================================

  async function runRegistrationTask(
    task: (isLatest: () => boolean) => Promise<void>,
    manual = false,
  ) {
    setProcessing(true);
    try {
      await registrationQueue.enqueue(task, manual);
    } finally {
      if (!registrationQueue.busy) {
        setProcessing(false);
      }
    }
  }

  async function requestRegistration(config: InstallConfig) {
    setPendingConfig(config);
    setConnectionError(null);

    await runRegistrationTask(
      (isLatest) => completeRegistration(config, isLatest),
      true,
    );
  }

  async function completeRegistration(
    config: InstallConfig,
    isLatest: () => boolean,
    requestedName?: string,
  ) {
    try {
      if (platform() === "windows") {
        await showWindow();
      } else {
        await unlockWindow();
      }
      await registerDevice(config, requestedName);

      if (!isLatest()) {
        return;
      }

      setPendingConfig(null);
      await message(
        "This device has been successfully connected to support.",
        {
          title: "Device registered",
          kind: "info",
        },
      );

      // Another link may arrive while the success dialog is open.
      if (isLatest() && platform() !== "macos") {
        await closeWindow();
      }
    } catch (err) {
      if (!isLatest()) {
        return;
      }

      await message(getErrorMessage(err, "Failed to register the device."), {
        title: "Device registration error",
        kind: "error",
      });
    }
  }

  async function handleRegister() {
    const config = pendingConfig ?? installConfig;

    if (!config || !computerName.trim()) {
      return;
    }

    await requestRegistration(config);
  }

  function clearConnectionState() {
    setInstallConfig(null);
    setRegistration(null);
    setPendingConfig(null);
    setConnectionError(null);
    setMissingInstallToken(true);
    setComputerName("");
    setCurrentRustdeskId("");
  }

  async function handleReconnect() {
    if (platform() !== "macos" || registrationQueue.busy) return;

    await runRegistrationTask(async (isLatest) => {
      if (!isLatest()) return;
      clearConnectionState();

      try {
        await unlockWindow();
        if (!isLatest()) return;
        await invoke("reset_installation_state");
        if (!isLatest()) return;

        const config = await invoke<InstallConfig | null>(
          "read_downloaded_install_config",
        );
        // A platform link received during reset or Downloads access wins.
        if (!isLatest()) return;
        if (!config) {
          setConnectionError(
            "Download a new connection file from the Magenda platform and click Reconnect Device again, or connect directly from the platform.",
          );
          return;
        }

        setPendingConfig(config);
        setMissingInstallToken(false);
        const info = await getSystemInfo().catch(() => null);
        if (!isLatest()) return;
        const name = info?.hostname?.trim() ?? "";
        setComputerName(name);
        if (!name) {
          await message("Please enter a computer name and retry the connection.", {
            title: "Device registration",
            kind: "info",
          });
          return;
        }

        // Manual registration always sends an API upsert, even for the same token.
        await completeRegistration(config, isLatest, name);
      } catch (err) {
        if (!isLatest()) return;
        const error = getErrorMessage(err, "Failed to reconnect the device.");
        setConnectionError(error);
        await message(error, {
          title: "Device registration error",
          kind: "error",
        });
      }
    }, true);
  }

  async function registerFromInstaller(
    launch: InstallerLaunch,
    isLatest: () => boolean,
  ) {
    if (!isLatest()) return;

    // An installer starts a new connection. Do not show or retry the old account.
    clearConnectionState();

    let resetComplete = false;
    try {
      await invoke("reset_installation_state");
      if (!isLatest()) return;
      resetComplete = true;

      const configError = launch.error || (!launch.config
        ? "No installation token was found. Download a personalized installer or connect through the Magenda platform."
        : null);
      setConnectionError(configError);
      if (configError) throw new Error(configError);
      setPendingConfig(launch.config);
      setMissingInstallToken(false);

      const wasVisible = await getCurrentWindow().isVisible();
      if (!isLatest()) return;

      const result = await invoke<RegistrationData>("auto_register_device", {
        config: launch.config,
        force: true,
      });

      if (launch.config) setInstallConfig(launch.config);
      setMissingInstallToken(false);
      setRegistration(result);
      setComputerName(result.computerName);
      setCurrentRustdeskId(result.currentRustdeskId);

      if (!isLatest()) return;
      setPendingConfig(null);
      if (!wasVisible) await closeWindow();
    } catch (err) {
      if (!isLatest()) return;
      if (!resetComplete) {
        setConnectionError(getErrorMessage(
          err,
          "Cannot clear the previous installation data. Run the installer again.",
        ));
      } else if (!launch.error && launch.config) {
        // Retry must start with this computer's name, not a previous registration.
        const info = await getSystemInfo().catch(() => null);
        if (!isLatest()) return;
        setComputerName(info?.hostname?.trim() ?? "");
      }
      if (!isLatest()) return;
      await showWindow();
      if (!isLatest()) return;
      await message(
        getErrorMessage(
          err,
          "Automatic registration failed. Please try again.",
        ),
        {
          title: "Device registration error",
          kind: "error",
        },
      );
    }
  }

  async function handleInstallerLaunch() {
    const manualVersion = registrationQueue.manualVersion;
    const launch = await invoke<InstallerLaunch | null>("get_installer_launch");
    if (!launch || launch.request_id <= lastInstallerRequest.current) return;
    lastInstallerRequest.current = launch.request_id;
    // Only an active/new manual request takes precedence, not one from earlier
    // in the session. A new installer may intentionally change the account.
    if (
      registrationQueue.hasPendingManualRequest ||
      manualVersion !== registrationQueue.manualVersion
    ) {
      await invoke("clear_installer_launch", { requestId: launch.request_id });
      return;
    }

    await runRegistrationTask(async (isLatest) => {
      await invoke("clear_installer_launch", { requestId: launch.request_id });
      if (!isLatest()) return;
      await registerFromInstaller(launch, isLatest);
    });
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

      await requestRegistration({
        install_token: deepLinkConfig.token,
        mode: deepLinkConfig.mode,
      });

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

  //   async function handleRequest() {
  //     const cleanMessage = supportMessage.trim();

  //     if (!cleanMessage) {
  //       await message("Please describe your issue.", {
  //         title: "Support request",
  //         kind: "warning",
  //       });

  //       return;
  //     }

  //     if (!installConfig) {
  //       await message("Installation configuration is missing.", {
  //         title: "Support request error",
  //         kind: "error",
  //       });

  //       return;
  //     }

  //     const cleanToken = installConfig.install_token?.trim();

  //     if (!cleanToken) {
  //       await message("Installation token is missing.", {
  //         title: "Support request error",
  //         kind: "error",
  //       });

  //       return;
  //     }

  //     try {
  //       setProcessing(true);

  //       const backendUrl = getBackendUrl(installConfig.mode);

  //       // Добавляем RustDesk deep link к сообщению.
  //       const formattedMessage = `${cleanMessage}

  // rustdesk://${currentRustdeskId.trim()}`;

  //       const response = await fetch(`${backendUrl}/rustdesk/message`, {
  //         method: "POST",
  //         headers: {
  //           "Content-Type": "application/json",
  //           "X-RustDesk-Key": cleanToken,
  //         },
  //         body: JSON.stringify({
  //           message: formattedMessage,
  //           device_id: currentRustdeskId,
  //           name: computerName.trim(),
  //         }),
  //       });

  //       if (!response.ok) {
  //         let serverMessage = "";

  //         try {
  //           const data = await response.json();

  //           serverMessage = data?.message || data?.error || "";
  //         } catch {
  //           try {
  //             serverMessage = await response.text();
  //           } catch {
  //             //
  //           }
  //         }

  //         throw new Error(
  //           serverMessage ||
  //             `Failed to send support request. Server returned HTTP ${response.status}.`,
  //         );
  //       }

  //       // Очищаем сообщение только после успешной отправки.
  //       setSupportMessage("");

  //       await message("Your support request has been sent successfully.", {
  //         title: "Support request sent",
  //         kind: "info",
  //       });
  //     } catch (err) {
  //       console.error("Failed to send support request:", err);

  //       const msg = getErrorMessage(err, "Failed to send support request.");

  //       await message(msg, {
  //         title: "Support request error",
  //         kind: "error",
  //       });
  //     } finally {
  //       setProcessing(false);
  //     }
  //   }

  // ============================================================
  // MISSING TOKEN
  // ============================================================

  // async function handleMissingInstallToken() {
  //   const openPlatform = await ask(
  //     "This device is not linked to your Magenda account yet.\n\nOpen the Magenda platform in your browser, then click “Open MagendaSupport” on the platform to send the registration link to this application.",
  //     {
  //       title: "Device registration required",
  //       kind: "info",
  //       okLabel: "Open Platform",
  //       cancelLabel: "Not Now",
  //     },
  //   );

  //   if (!openPlatform) {
  //     return;
  //   }

  //   await openUrl(`${getFrontendUrl(installConfig?.mode)}?install=rustdesk`);
  // }

  async function handleOpenPlatform() {
    try {
      const url = `${getFrontendUrl(installConfig?.mode)}?install=rustdesk`;

      // Сначала открываем сайт в браузере.
      await openUrl(url);

      // Затем закрываем MagendaSupport.
      await closeWindow();
    } catch (err) {
      console.error("Failed to open Magenda platform:", err);

      const msg = getErrorMessage(err, "Failed to open the Magenda platform.");

      await message(msg, {
        title: "Magenda Support",
        kind: "error",
      });
    }
  }

  // ============================================================
  // INITIALIZE + DEEP LINKS
  // ============================================================

  const handleDeepLinksRef = useRef(handleDeepLinks);
  const handleInstallerLaunchRef = useRef(handleInstallerLaunch);
  const checkForUpdatesRef = useRef(checkForUpdates);
  const installerListenerReady = useRef(Promise.resolve());

  useEffect(() => {
    handleDeepLinksRef.current = handleDeepLinks;
    handleInstallerLaunchRef.current = handleInstallerLaunch;
    checkForUpdatesRef.current = checkForUpdates;
  });

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;

    async function subscribe() {
      try {
        const stop = await onOpenUrl(async (urls) => {
          if (disposed) {
            return;
          }

          try {
            await handleDeepLinksRef.current(urls);
          } catch {
            if (!disposed) {
              await message("Failed to process the connection link.", {
                title: "Magenda Support",
                kind: "error",
              });
            }
          }
        });

        if (disposed) {
          stop();
        } else {
          unlisten = stop;
        }
      } catch {
        // Не выводим URL: он может содержать install token.
        console.error("Failed to subscribe to connection links.");
      }
    }

    void subscribe();

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (platform() !== "windows") return;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    installerListenerReady.current = listen("installer-launch", async () => {
      if (disposed) return;
      try {
        await handleInstallerLaunchRef.current();
      } catch {
        await showWindow();
        await message(
          "Cannot process the installer request. Open the Magenda platform to connect this computer.",
          {
            title: "Magenda Support",
            kind: "error",
          },
        );
      }
    }).then((stop) => {
      if (disposed) stop();
      else unlisten = stop;
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    let disposed = false;

    void runRegistrationTask(async (isLatest) => {
      if (disposed) {
        return;
      }

      try {
        // Subscribe before consuming the stored request so a second installer
        // cannot arrive between the initial read and event subscription.
        await installerListenerReady.current;
        if (disposed) return;
        const urls = await getCurrent();

        if (disposed) {
          return;
        }

        const installUrl =
          urls?.find((url) => getInstallConfigFromUrl(url) !== null) ?? null;

        const installer =
          platform() === "windows"
            ? await invoke<InstallerLaunch | null>("get_installer_launch")
            : null;
        if (disposed) return;

        // Installer requests reset old state before starting their own token
        // lookup. Regular startup may still load the saved account.
        if (!installer) {
          await initialize(!!installUrl || registrationQueue.hasManualRequest);
        }

        // A live link takes precedence over a delayed startup link/auto request.
        if (disposed || registrationQueue.hasManualRequest || !isLatest()) {
          if (installer) {
            await invoke("clear_installer_launch", {
              requestId: installer.request_id,
            });
          }
          return;
        }

        if (installUrl) {
          if (installer) {
            lastInstallerRequest.current = Math.max(
              lastInstallerRequest.current,
              installer.request_id,
            );
            await invoke("clear_installer_launch", {
              requestId: installer.request_id,
            });
          }
          if (disposed || registrationQueue.hasManualRequest) return;
          // Enqueue without awaiting: this startup job must release the queue first.
          void handleDeepLinksRef.current([installUrl]);
          return;
        }

        if (installer) {
          if (installer.request_id > lastInstallerRequest.current) {
            lastInstallerRequest.current = installer.request_id;
            await invoke("clear_installer_launch", {
              requestId: installer.request_id,
            });
            await registerFromInstaller(installer, isLatest);
          }
          return;
        }

        let rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");

        if (disposed || !isLatest()) {
          return;
        }

        // Install or update the bundled RustDesk version before auto-registration.
        if (
          platform() === "macos" &&
          !hasRequiredRustDeskVersion(rustdeskStatus)
        ) {
          await invoke("configure_rustdesk");

          if (disposed || !isLatest()) {
            return;
          }

          rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");

          if (disposed || !isLatest()) {
            return;
          }

          assertRequiredRustDeskVersion(rustdeskStatus);
        }

        if (disposed || !isLatest()) {
          return;
        }

        setStatus(rustdeskStatus);
        setCurrentRustdeskId(rustdeskStatus.id?.trim() ?? "");
        await checkPermissions();

        if (disposed || !isLatest() || platform() !== "macos") {
          return;
        }

        // Rust reads the active config again after taking the registration lock.
        const config = await invoke<InstallConfig | null>("get_install_config");

        if (disposed || !isLatest() || !config?.install_token?.trim()) {
          return;
        }

        const existing = await invoke<RegistrationData | null>(
          "get_registration_state",
        ).catch(() => null);

        if (disposed || !isLatest()) {
          return;
        }

        const result =
          existing ?? (await invoke<RegistrationData>("auto_register_device"));

        if (disposed) {
          return;
        }

        setRegistration(result);
        setComputerName(result.computerName);
        setCurrentRustdeskId(result.currentRustdeskId);
        // Keep macOS open for RustDesk privacy permissions and Rename.
      } catch (err) {
        if (disposed || !isLatest()) {
          return;
        }

        if (platform() === "windows") await showWindow();
        await message(
          getErrorMessage(err, "Failed to initialize or register the device."),
          { title: "Magenda Support", kind: "error" },
        );
      }
    });

    return () => {
      disposed = true;
    };
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;

    getCurrentWindow()
      .onFocusChanged(async ({ payload: focused }) => {
        if (!focused || disposed || registrationQueue.busy) {
          return;
        }

        const version = registrationQueue.version;
        try {
          const saved = await invoke<RegistrationData | null>(
            "get_registration_state",
          );

          if (
            disposed ||
            registrationQueue.busy ||
            version !== registrationQueue.version
          ) {
            return;
          }

          setRegistration(saved);

          if (saved) {
            setCurrentRustdeskId(saved.currentRustdeskId);
          }
        } catch {
          // При ошибке чтения сохраняем последнее отображённое состояние.
        }
      })
      .then((stop) => {
        if (disposed) {
          stop();
        } else {
          unlisten = stop;
        }
      })
      .catch(() => {
        // Если подписка не создалась, состояние всё равно
        // загружается при запуске через initialize().
      });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => {
      void checkForUpdatesRef.current();
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
              Connecting your device...
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

        {(missingInstallToken && !pendingConfig) || connectionError ? (
          <div className="flex w-full max-w-120 flex-col items-center gap-4 px-8">
            <div className="rounded-xl bg-white/10 p-4 text-center text-white shadow-lg backdrop-blur-sm">
              <div className="mb-2 text-lg leading-none font-semibold">
                Connect this computer
              </div>

              <div className="text-sm leading-none text-white/90">
                {connectionError ||
                  "This computer is not connected to your Magenda account yet."}
                <br />
                <br />
                Open the Magenda platform and continue the connection process
                there.
              </div>
            </div>

            <button
              type="button"
              onClick={handleOpenPlatform}
              className="
                inline-flex
                items-center
                justify-center
                rounded-md
                border-0
                bg-[#67ae6f]
                px-5
                py-2.5
                text-sm
                font-medium
                text-white
                shadow-sm
                transition
                hover:opacity-90
                focus:outline-none
                focus:ring-0
              "
            >
              Open Magenda Platform
            </button>

            <div className="text-center text-xs leading-none text-white/70">
              Magenda Support will close after opening the platform.
              <br />
              It will open again when you connect this computer from the
              website.
            </div>
          </div>
        ) : (
          <form
            onSubmit={(e) => {
              e.preventDefault();
            }}
            noValidate
            className="flex w-full max-w-120 flex-col gap-2 px-8"
          >
            {pendingConfig && !processing && (
              <div className="rounded-xl bg-white/10 p-4 text-center text-sm text-white">
                Connection not completed. Retry to finish connecting this
                computer.
              </div>
            )}

            {registration && !pendingConfig && (
              <div className="rounded-xl bg-white/10 p-4 text-center text-white shadow-lg backdrop-blur-sm">
                <div className="text-sm leading-none text-white/90">
                  This device has been successfully connected to support.
                </div>
              </div>
            )}

            {/* {registration ? (
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
              <> */}
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
                  setComputerName(e.target.value);
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
                  !(pendingConfig ?? installConfig) ||
                  processing ||
                  !computerName.trim()
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
                {pendingConfig
                  ? "Retry Connection"
                  : registration
                    ? "Rename Device"
                    : "Register Device"}
              </button>
            </div>
            {/* </>
            )} */}
          </form>
        )}

        {platform() === "macos" && (
          <div className="flex w-full max-w-120 flex-col items-center gap-2 px-8 text-center text-white">
            <p className="text-xs text-white/80">
              To reconnect, first download a new connection file from the Magenda
              platform to Downloads. This clears the saved connection and uses
              the latest downloaded file.
            </p>
            <button
              type="button"
              onClick={handleReconnect}
              disabled={processing}
              className="rounded-md bg-white/15 px-4 py-2 text-sm hover:bg-white/25 disabled:opacity-50"
            >
              Reconnect Device
            </button>
          </div>
        )}

        {platform() === "macos" &&
          (status?.installed || installConfig || pendingConfig) && (
            <div className="flex w-full max-w-120 flex-col gap-3 rounded-xl bg-white/10 p-4 text-white">
              <div className="text-sm font-semibold">Allow remote assistance</div>
              <p className="text-sm text-white/90">
                Open RustDesk, then enable RustDesk in Screen Recording and
                Accessibility in macOS System Settings. If RustDesk is missing
                from the list, add it from Applications. Quit and reopen RustDesk
                after changing these permissions.
              </p>
              <div className="flex flex-wrap gap-2">
                {[
                  ["Open RustDesk", "open_rustdesk"],
                  ["Screen Recording", "open_screen_recording_settings"],
                  ["Accessibility", "open_accessibility_settings"],
                ].map(([label, command]) => (
                  <button
                    key={command}
                    type="button"
                    disabled={processing}
                    onClick={async () => {
                      try {
                        await invoke(command);
                      } catch {
                        await message(
                          "Open RustDesk or Privacy & Security from macOS Settings to continue.",
                          {
                            title: "Magenda Support",
                            kind: "error",
                          },
                        );
                      }
                    }}
                    className="rounded-md bg-white/15 px-3 py-2 text-sm hover:bg-white/25 disabled:opacity-50"
                  >
                    {label}
                  </button>
                ))}
              </div>
              {registration && !pendingConfig && (
                <button
                  type="button"
                  onClick={closeWindow}
                  disabled={processing}
                  className="self-end rounded-md bg-[#67ae6f] px-4 py-2 text-sm disabled:opacity-50"
                >
                  Done
                </button>
              )}
            </div>
          )}

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

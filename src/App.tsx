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

const PROCESSING_TEXT = {
  initialize: "Loading device information...",
  connect: "Connecting your device...",
  rename: "Updating computer name...",
  reconnect: "Reconnecting your device...",
  reset: "Clearing saved connection...",
  readConnection: "Reading connection file...",
  configureRustDesk: "Setting up RustDesk...",
  update: "Downloading and installing update...",
};

type ProcessingOperation = keyof typeof PROCESSING_TEXT;

const REGISTRATION_MESSAGES = {
  connect: {
    success: "This device has been successfully connected to support.",
    successTitle: "Device connected",
    error: "Failed to connect the device.",
    errorTitle: "Connection failed",
  },
  rename: {
    success: "The computer name has been updated.",
    successTitle: "Device renamed",
    error: "Failed to update the computer name.",
    errorTitle: "Rename failed",
  },
  reconnect: {
    success: "This device has been successfully reconnected to support.",
    successTitle: "Device reconnected",
    error: "Failed to reconnect the device.",
    errorTitle: "Reconnection failed",
  },
};

type RegistrationIntent = keyof typeof REGISTRATION_MESSAGES;

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
  const version = status.version
    ?.trim()
    .match(/^(\d+\.\d+\.\d+)(?:$|[.+-])/)?.[1];
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

  const [registrationOperation, setRegistrationOperation] =
    useState<ProcessingOperation | null>(null);
  const [installingUpdate, setInstallingUpdate] = useState(false);
  const processingOperation =
    registrationOperation ?? (installingUpdate ? "update" : null);
  const processing = processingOperation !== null;

  const [missingInstallToken, setMissingInstallToken] = useState(false);

  const [installConfig, setInstallConfig] = useState<InstallConfig | null>(
    null,
  );

  // A failed candidate stays in memory for Retry; installConfig is the active config.
  const [pendingConfig, setPendingConfig] = useState<InstallConfig | null>(
    null,
  );
  const [pendingIntent, setPendingIntent] =
    useState<RegistrationIntent>("connect");
  const [connectionError, setConnectionError] = useState<string | null>(null);
  // Retain only the platform environment while Windows waits for a fresh link.
  const [windowsReconnectMode, setWindowsReconnectMode] =
    useState<InstallMode | null>(null);
  const registrationQueue = useRef(new RegistrationQueue()).current;
  const lastInstallerRequest = useRef(0);

  // Support needs the live RustDesk ID, even if backend registration failed.
  const [currentRustdeskId, setCurrentRustdeskId] = useState("");
  const [readingDeviceId, setReadingDeviceId] = useState(true);
  const [deviceIdError, setDeviceIdError] = useState(false);
  const [copyFeedback, setCopyFeedback] = useState("");
  const [openingRustDesk, setOpeningRustDesk] = useState(false);
  const deviceIdRequest = useRef(0);

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
    if (
      registrationQueue.busy ||
      pendingConfig ||
      connectionError ||
      windowsReconnectMode !== null
    ) {
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

      setInstallingUpdate(true);

      await invoke("download_and_install_update");
    } catch (err) {
      console.error("Updater failed:", err);
    } finally {
      setInstallingUpdate(false);
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

  async function registerDevice(
    config: InstallConfig,
    intent: RegistrationIntent,
    requestedName?: string,
  ) {
    if (!config.install_token.trim()) {
      throw new Error("Installation token is missing.");
    }

    const name = requestedName ?? (await ensureComputerName());

    let rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");

    if (!isRustDeskHealthy(rustdeskStatus)) {
      setRegistrationOperation("configureRustDesk");
      await invoke("configure_rustdesk");

      rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");
    }

    if (platform() === "macos") {
      assertRequiredRustDeskVersion(rustdeskStatus);
    }

    setStatus(rustdeskStatus);

    setRegistrationOperation(intent);
    const registrationData = await invoke<RegistrationData>("register_device", {
      computerName: name,
      token: config.install_token,
      mode: config.mode,
    });

    setInstallConfig(config);
    setMissingInstallToken(false);
    setRegistration(registrationData);
    setComputerName(registrationData.computerName);

    return registrationData;
  }

  // ============================================================
  // MANUAL REGISTER
  // ============================================================

  async function runRegistrationTask(
    task: (isLatest: () => boolean) => Promise<void>,
    operation: ProcessingOperation,
    manual = false,
  ) {
    if (!registrationQueue.busy) setRegistrationOperation(operation);
    try {
      await registrationQueue.enqueue((isLatest) => {
        // A queued request must not change the label of the running operation.
        setRegistrationOperation(operation);
        return task(isLatest);
      }, manual);
    } finally {
      if (!registrationQueue.busy) {
        setRegistrationOperation(null);
      }
    }
  }

  async function requestRegistration(
    config: InstallConfig,
    intent: RegistrationIntent = "connect",
  ) {
    setPendingConfig(config);
    setPendingIntent(intent);
    setConnectionError(null);

    await runRegistrationTask(
      (isLatest) => completeRegistration(config, isLatest, intent),
      intent,
      true,
    );
  }

  async function completeRegistration(
    config: InstallConfig,
    isLatest: () => boolean,
    intent: RegistrationIntent,
    requestedName?: string,
  ) {
    const messages = REGISTRATION_MESSAGES[intent];
    setRegistrationOperation(intent);
    try {
      if (platform() === "windows") {
        await showWindow();
      } else {
        await unlockWindow();
      }
      await registerDevice(config, intent, requestedName);

      if (!isLatest()) {
        return;
      }

      setPendingConfig(null);
      await message(messages.success, {
        title: messages.successTitle,
        kind: "info",
      });

      // Another link may arrive while the success dialog is open.
      if (isLatest() && platform() !== "macos") {
        await closeWindow();
      }
    } catch (err) {
      if (!isLatest()) {
        return;
      }

      await message(getErrorMessage(err, messages.error), {
        title: messages.errorTitle,
        kind: "error",
      });
    }
  }

  async function handleRegister() {
    const config = pendingConfig ?? installConfig;

    if (!config || !computerName.trim()) {
      return;
    }

    const intent = pendingConfig
      ? pendingIntent
      : registration
        ? "rename"
        : "connect";
    await requestRegistration(config, intent);
  }

  function clearConnectionState() {
    setInstallConfig(null);
    setRegistration(null);
    setPendingConfig(null);
    setPendingIntent("connect");
    setConnectionError(null);
    setMissingInstallToken(true);
    setComputerName("");
    setWindowsReconnectMode(null);
  }

  async function handleReconnect() {
    const isWindows = platform() === "windows";
    if ((!isWindows && platform() !== "macos") || registrationQueue.busy)
      return;
    const mode =
      pendingConfig?.mode ??
      installConfig?.mode ??
      windowsReconnectMode ??
      "prod";

    if (isWindows) {
      clearConnectionState();
      setWindowsReconnectMode(mode);
    }
    await runRegistrationTask(async (isLatest) => {
      if (!isWindows) {
        if (!isLatest()) return;
        clearConnectionState();
      }

      try {
        await unlockWindow();
        // Finish an explicit Windows reset even if a new link is already queued.
        // The queue ensures the new registration starts only after this cleanup.
        if (!isWindows && !isLatest()) return;
        await invoke("reset_installation_state");
        if (!isLatest()) return;

        // Windows waits for a new platform link; never reuse Downloads or an old token.
        if (isWindows) return;

        setRegistrationOperation("readConnection");
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
        setPendingIntent("reconnect");
        setMissingInstallToken(false);
        const info = await getSystemInfo().catch(() => null);
        if (!isLatest()) return;
        const name = info?.hostname?.trim() ?? "";
        setComputerName(name);
        if (!name) {
          await message(
            "Please enter a computer name and retry the connection.",
            {
              title: "Reconnect device",
              kind: "info",
            },
          );
          return;
        }

        // Manual registration always sends an API upsert, even for the same token.
        await completeRegistration(config, isLatest, "reconnect", name);
      } catch (err) {
        if (!isLatest()) return;
        const error = getErrorMessage(
          err,
          isWindows
            ? "Failed to clear the saved connection."
            : "Failed to reconnect the device.",
        );
        setConnectionError(error);
        await message(error, {
          title: isWindows ? "Connection reset failed" : "Reconnection failed",
          kind: "error",
        });
      }
    }, "reset", true);
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
      setRegistrationOperation("reset");
      await invoke("reset_installation_state");
      if (!isLatest()) return;
      resetComplete = true;

      const configError =
        launch.error ||
        (!launch.config
          ? "No installation token was found. Download a personalized installer or connect through the Magenda platform."
          : null);
      setConnectionError(configError);
      if (configError) throw new Error(configError);
      setPendingConfig(launch.config);
      setMissingInstallToken(false);

      const wasVisible = await getCurrentWindow().isVisible();
      if (!isLatest()) return;

      setRegistrationOperation("connect");
      const result = await invoke<RegistrationData>("auto_register_device", {
        config: launch.config,
        force: true,
      });

      if (launch.config) setInstallConfig(launch.config);
      setMissingInstallToken(false);
      setRegistration(result);
      setComputerName(result.computerName);

      if (!isLatest()) return;
      setPendingConfig(null);
      if (!wasVisible) await closeWindow();
    } catch (err) {
      if (!isLatest()) return;
      if (!resetComplete) {
        setConnectionError(
          getErrorMessage(
            err,
            "Cannot clear the previous installation data. Run the installer again.",
          ),
        );
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
    }, "reset");
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

  async function refreshDeviceId() {
    const request = ++deviceIdRequest.current;
    setReadingDeviceId(true);
    setCurrentRustdeskId("");
    setDeviceIdError(false);
    setCopyFeedback("");
    try {
      const id = await invoke<string | null>("get_rustdesk_id");
      if (request === deviceIdRequest.current) {
        setCurrentRustdeskId(id?.trim() ?? "");
      }
    } catch {
      if (request === deviceIdRequest.current) setDeviceIdError(true);
    } finally {
      if (request === deviceIdRequest.current) setReadingDeviceId(false);
    }
  }

  async function handleCopyDeviceId() {
    if (!currentRustdeskId) return;
    const request = deviceIdRequest.current;
    try {
      await navigator.clipboard.writeText(currentRustdeskId);
      if (request === deviceIdRequest.current) {
        setCopyFeedback("Device ID copied.");
      }
    } catch {
      if (request === deviceIdRequest.current) {
        const shortcut = platform() === "macos" ? "Command+C" : "Ctrl+C";
        setCopyFeedback(
          `Select the Device ID and press ${shortcut} to copy it.`,
        );
      }
    }
  }

  async function handleOpenRustDesk() {
    setOpeningRustDesk(true);
    try {
      await invoke("open_rustdesk");
      void refreshDeviceId();
    } catch (err) {
      await message(
        getErrorMessage(
          err,
          "Failed to open RustDesk. Please reinstall Magenda Support and try again.",
        ),
        { title: "RustDesk", kind: "error" },
      );
    } finally {
      setOpeningRustDesk(false);
    }
  }

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
    const version = registrationQueue.version;
    try {
      const mode =
        pendingConfig?.mode ??
        installConfig?.mode ??
        windowsReconnectMode ??
        "prod";
      const url = `${getFrontendUrl(mode)}?install=rustdesk`;

      // Сначала открываем сайт в браузере.
      await openUrl(url);

      // A Windows reconnect waits here for the platform to send its new link.
      if (
        windowsReconnectMode === null &&
        !registrationQueue.busy &&
        version === registrationQueue.version
      ) {
        await closeWindow();
      }
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

        let rustdeskStatus = await invoke<RustDeskStatus>(
          "get_rustdesk_status",
        );

        if (disposed || !isLatest()) {
          return;
        }

        // Install or update the bundled RustDesk version before auto-registration.
        if (
          platform() === "macos" &&
          !hasRequiredRustDeskVersion(rustdeskStatus)
        ) {
          setRegistrationOperation("configureRustDesk");
          await invoke("configure_rustdesk");

          if (disposed || !isLatest()) {
            return;
          }

          rustdeskStatus = await invoke<RustDeskStatus>("get_rustdesk_status");

          if (disposed || !isLatest()) {
            return;
          }

          assertRequiredRustDeskVersion(rustdeskStatus);
          setRegistrationOperation("initialize");
        }

        if (disposed || !isLatest()) {
          return;
        }

        setStatus(rustdeskStatus);
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

        if (!existing) setRegistrationOperation("connect");
        const result =
          existing ?? (await invoke<RegistrationData>("auto_register_device"));

        if (disposed) {
          return;
        }

        setRegistration(result);
        setComputerName(result.computerName);
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
    }, "initialize");

    return () => {
      disposed = true;
    };
  }, []);

  useEffect(() => {
    if (!processing && !registrationQueue.busy) void refreshDeviceId();
    // Ignore probes that finish after setup starts or this view is unmounted.
    return () => {
      deviceIdRequest.current++;
    };
  }, [processing]);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;

    getCurrentWindow()
      .onFocusChanged(async ({ payload: focused }) => {
        if (!focused || disposed || registrationQueue.busy) {
          return;
        }

        void refreshDeviceId();
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
    <main className="app-shell">
      {processingOperation && (
        <div className="processing-overlay" role="status" aria-live="polite">
          <div className="processing-spinner" aria-hidden="true" />
          <span>{PROCESSING_TEXT[processingOperation]}</span>
        </div>
      )}

      <div className="app-content">
        <header className="app-header">
          <img src="/magenda-support-logo.png" alt="" className="app-logo" />
          <div>
            <h1>Magenda Support</h1>
            <p>Remote support for this computer</p>
          </div>
        </header>

        <section aria-label="Support connection" className="panel">
          <label htmlFor="rustdeskId" className="field-label">
            Device ID <span className="label-detail">RustDesk</span>
          </label>
          <div className="field-row">
            <input
              id="rustdeskId"
              type="text"
              readOnly
              value={currentRustdeskId}
              placeholder={
                readingDeviceId ? "Reading Device ID..." : "Not available"
              }
              aria-describedby="device-id-hint"
              className="control-input device-id"
            />
            <button
              type="button"
              onClick={handleCopyDeviceId}
              disabled={!currentRustdeskId || readingDeviceId}
              className="control-button button-secondary"
            >
              Copy ID
            </button>
          </div>
          <p id="device-id-hint" role="status" className="field-hint">
            {copyFeedback ||
              (readingDeviceId
                ? "Reading Device ID..."
                : currentRustdeskId
                  ? "Share this ID with your support team."
                  : deviceIdError
                    ? "Could not read Device ID. Open RustDesk to find it, or refresh."
                    : "Device ID is not available yet. Open RustDesk, then refresh.")}
          </p>
          <div className="button-row">
            <button
              type="button"
              onClick={handleOpenRustDesk}
              disabled={processing || openingRustDesk}
              className="control-button button-primary"
            >
              {openingRustDesk ? "Opening RustDesk..." : "Open RustDesk"}
            </button>
            <button
              type="button"
              onClick={refreshDeviceId}
              disabled={processing || readingDeviceId}
              className="control-button button-secondary"
            >
              Refresh ID
            </button>
          </div>
        </section>

        <section aria-label="Device connection" className="panel">
          {(missingInstallToken && !pendingConfig) || connectionError ? (
            <div className="panel-stack">
              <h2>Connect this computer</h2>
              <p className={connectionError ? "notice" : "body-copy"}>
                {connectionError ||
                  "This computer is not connected to your Magenda account yet."}
              </p>
              <button
                type="button"
                onClick={handleOpenPlatform}
                className="control-button button-primary"
              >
                Open Magenda Platform
              </button>
              <p className="field-hint">
                {windowsReconnectMode !== null
                  ? "Connect this computer on the platform and allow it to open Magenda Support. This window will stay open while you connect."
                  : "Continue the connection on the platform. This window will close and reopen when you connect."}
              </p>
            </div>
          ) : (
            <form
              onSubmit={(e) => {
                e.preventDefault();
              }}
              noValidate
            >
              <div className="panel-heading">
                <h2>This computer</h2>
                {registration && !pendingConfig && (
                  <span className="connection-badge" role="status">
                    <span className="status-dot" aria-hidden="true" />
                    Connected
                  </span>
                )}
              </div>
              {pendingConfig && !processing && (
                <p className="notice">
                  {pendingIntent === "rename"
                    ? "Computer name was not updated. Retry to save the new name."
                    : "Connection not completed. Retry to finish connecting this computer."}
                </p>
              )}
              <label htmlFor="computerName" className="field-label">
                Computer name
              </label>
              <div className="field-row">
                <input
                  type="text"
                  value={computerName}
                  onChange={(e) => {
                    setComputerName(e.target.value);
                  }}
                  disabled={processing}
                  id="computerName"
                  placeholder="Enter computer name..."
                  className="control-input"
                />
                <button
                  type="button"
                  onClick={handleRegister}
                  disabled={
                    !(pendingConfig ?? installConfig) ||
                    processing ||
                    !computerName.trim()
                  }
                  className={`control-button ${registration && !pendingConfig ? "button-secondary" : "button-primary"}`}
                >
                  {pendingConfig
                    ? pendingIntent === "rename"
                      ? "Retry Rename"
                      : "Retry Connection"
                    : registration
                      ? "Rename Device"
                      : "Register Device"}
                </button>
              </div>
            </form>
          )}

          {(platform() === "macos" || platform() === "windows") && (
            <details className="disclosure reconnect-section">
              <summary>Reconnect this computer</summary>
              <div className="disclosure-content">
                <p className="body-copy">
                  {platform() === "windows"
                    ? "Clear the saved connection, then connect this computer again from the Magenda platform. Your RustDesk ID and settings are kept."
                    : "Download a new connection file from Magenda to Downloads. Reconnecting clears the saved connection and uses the latest file."}
                </p>
                <button
                  type="button"
                  onClick={handleReconnect}
                  disabled={processing}
                  className="control-button button-secondary"
                >
                  Reconnect Device
                </button>
              </div>
            </details>
          )}
        </section>

        {platform() === "macos" &&
          (status?.installed || installConfig || pendingConfig) && (
            <section
              aria-labelledby="permissions-title"
              className="panel panel-stack"
            >
              <h2 id="permissions-title">Allow remote assistance</h2>
              <p className="body-copy">
                Enable RustDesk in Screen Recording and Accessibility in macOS
                settings.
              </p>
              <div className="button-row equal-buttons">
                {[
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
                          { title: "Magenda Support", kind: "error" },
                        );
                      }
                    }}
                    className="control-button button-secondary"
                  >
                    {label}
                  </button>
                ))}
              </div>
              <details className="disclosure">
                <summary>Setup instructions</summary>
                <p className="body-copy disclosure-content">
                  Open RustDesk before changing permissions. If RustDesk is
                  missing from the list, add it from Applications. Quit and
                  reopen RustDesk after changing these permissions.
                </p>
              </details>
            </section>
          )}

        {platform() === "macos" && registration && !pendingConfig && (
          <footer className="app-footer">
            <button
              type="button"
              onClick={closeWindow}
              disabled={processing}
              className="control-button button-primary"
            >
              Done
            </button>
          </footer>
        )}
      </div>
    </main>
  );
}

export default App;

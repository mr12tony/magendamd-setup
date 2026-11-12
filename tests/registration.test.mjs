import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";

function load(source, imports = {}, globals = {}) {
  const { outputText } = ts.transpileModule(
    readFileSync(new URL(source, import.meta.url), "utf8"),
    {
      compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        jsx: ts.JsxEmit.ReactJSX,
      },
    },
  );
  const exports = {};
  runInNewContext(outputText, {
    exports,
    URL,
    console,
    setTimeout: () => 0,
    clearTimeout() {},
    require(name) {
      assert.ok(name in imports, `Unexpected dependency: ${name}`);
      return imports[name];
    },
    ...globals,
  });
  return exports;
}

const queueModule = load("../src/registrationQueue.ts");
const deepLinkModule = load("../src/deepLink.ts");
const config = (token, mode = "prod") => ({ install_token: token, mode });
const link = (token, mode = "prod") =>
  `magendasupport://install?token=${token}&mode=${mode}`;
const registered = (name = "Test computer") => ({
  registered: true,
  currentRustdeskId: "123456789",
  computerName: name,
  registeredAt: "2026-10-26T00:00:00Z",
});

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

async function until(check) {
  for (let i = 0; i < 100; i++) {
    if (check()) return;
    await new Promise(setImmediate);
  }
  assert.fail("Expected application state was not reached");
}

// Run the real App handlers/effects with a small hook renderer and mocked Tauri IO.
// No API requests, desktop windows, RustDesk operations or user files are involved.
function app(options = {}) {
  const hooks = [];
  const calls = [];
  const dialogs = [];
  const questions = [];
  const timers = new Map();
  let timerId = 0;
  let activeConfig = options.config ?? null;
  let saved = options.saved ?? null;
  let status = {
    installed: true,
    version: "1.5.0",
    service_running: true,
    configured: true,
    id: "123456789",
    ...options.status,
  };
  let cursor = 0,
    pendingRender = false,
    tree,
    effects = [],
    linkListener,
    focusListener,
    installerListener;
  let closes = 0,
    readOverride;
  let installer = options.installer ?? null;
  let visible = options.visible ?? true;
  let shows = 0;
  const state = {
    calls,
    dialogs,
    questions,
    get activeConfig() {
      return activeConfig;
    },
    get closes() {
      return closes;
    },
    get visible() {
      return visible;
    },
    get shows() {
      return shows;
    },
    get text() {
      return content(tree);
    },
    get busy() {
      return state.text.includes("Connecting your device...");
    },
    links: (...urls) => linkListener(urls),
    installer: (launch) => {
      installer = launch;
      return installerListener();
    },
    focus: () => focusListener({ payload: true }),
    setReadOverride: (read) => {
      readOverride = read;
    },
    button: (label) =>
      nodes(tree).find(
        (node) => node.type === "button" && content(node) === label,
      ),
    idle: () => until(() => !state.busy && !pendingRender),
    runTimers: async () => {
      const callbacks = [...timers.values()];
      timers.clear();
      for (const callback of callbacks) callback();
      await new Promise(setImmediate);
    },
  };

  function scheduleRender() {
    if (pendingRender) return;
    pendingRender = true;
    queueMicrotask(render);
  }

  const react = {
    useState(initial) {
      const i = cursor++;
      hooks[i] ??= { value: initial };
      return [
        hooks[i].value,
        (value) => {
          if (Object.is(value, hooks[i].value)) return;
          hooks[i].value = value;
          scheduleRender();
        },
      ];
    },
    useRef(initial) {
      const i = cursor++;
      hooks[i] ??= { current: initial };
      return hooks[i];
    },
    useEffect(effect, deps) {
      const i = cursor++;
      if (!hooks[i] || deps === undefined) effects.push(effect);
      hooks[i] = { effect };
    },
  };

  async function invoke(command, args) {
    calls.push({ command, args });
    switch (command) {
      case "check_for_updates":
        return options.update
          ? options.update()
          : { available: true, version: "0.0.6", notes: null };
      case "download_and_install_update":
        return;
      case "get_installer_launch":
        return options.readInstaller
          ? options.readInstaller(installer)
          : installer;
      case "clear_installer_launch":
        if (installer?.request_id === args.requestId) installer = null;
        return;
      case "reset_installation_state":
        await options.reset?.();
        activeConfig = null;
        saved = null;
        return;
      case "read_downloaded_install_config":
        return options.download ? options.download() : null;
      case "initialize_install_config":
      case "get_install_config":
        return activeConfig;
      case "get_registration_state":
        return readOverride ? readOverride() : saved;
      case "get_rustdesk_status":
        return status;
      case "get_rustdesk_permissions_status":
        return {};
      case "open_rustdesk":
      case "open_screen_recording_settings":
      case "open_accessibility_settings":
        return options.openSettings?.(command);
      case "configure_rustdesk":
        status = {
          ...status,
          installed: true,
          version: "1.5.0",
          configured: true,
          service_running: true,
          id: status.id ?? "123456789",
          ...(await options.configure?.()),
        };
        return;
      case "auto_register_device":
        await options.auto?.(args);
        if (args?.config) activeConfig = args.config;
        saved = registered();
        return saved;
      case "register_device":
        await options.register?.(args);
        activeConfig = config(args.token, args.mode);
        saved = registered(args.computerName);
        return saved;
      default:
        assert.fail(`Unexpected IPC command: ${command}`);
    }
  }

  const window = {
    setClosable: async () => {},
    setMinimizable: async () => {},
    setMaximizable: async () => {},
    setResizable: async () => {},
    close: async () => {
      closes++;
    },
    show: async () => {
      visible = true;
      shows++;
    },
    isVisible: async () => visible,
    unminimize: async () => {},
    setFocus: async () => {},
    onFocusChanged: async (listener) => {
      focusListener = listener;
      return () => {};
    },
  };
  const jsx = (type, props) => ({ type, props });
  const { default: App } = load(
    "../src/App.tsx",
    {
      react,
      "react/jsx-runtime": { jsx, jsxs: jsx },
      "@tauri-apps/api/core": { invoke },
      "@tauri-apps/api/event": {
        listen: async (_event, listener) => {
          installerListener = listener;
          return () => {};
        },
      },
      "@tauri-apps/plugin-dialog": {
        ask: async (text) => {
          questions.push(text);
          return options.ask ? options.ask() : false;
        },
        message: async (text, info) => {
          dialogs.push({ text, ...info });
          await options.message?.(info);
        },
      },
      "@tauri-apps/plugin-deep-link": {
        getCurrent: async () => (options.current ? options.current() : []),
        onOpenUrl: async (listener) => {
          linkListener = listener;
          return () => {};
        },
      },
      "@tauri-apps/plugin-opener": { openUrl: async () => {} },
      "@tauri-apps/api/window": { getCurrentWindow: () => window },
      "@tauri-apps/plugin-os": { platform: () => options.platform ?? "macos" },
      "./system": {
        getSystemInfo: async () => ({ hostname: "Test computer" }),
      },
      "./deepLink": deepLinkModule,
      "./registrationQueue": queueModule,
      "./App.css": {},
    },
    {
      setTimeout: (callback) => {
        const id = ++timerId;
        timers.set(id, callback);
        return id;
      },
      clearTimeout: (id) => timers.delete(id),
    },
  );

  function render() {
    pendingRender = false;
    cursor = 0;
    effects = [];
    tree = App();
    const mounted = effects;
    return { effects: mounted, cleanups: mounted.map((effect) => effect()) };
  }

  const mounted = render();
  if (options.strictMount) {
    for (const cleanup of mounted.cleanups) cleanup?.();
    for (const effect of mounted.effects) effect();
  }
  return state;
}

function nodes(node) {
  if (Array.isArray(node)) return node.flatMap(nodes);
  if (!node || typeof node !== "object") return [];
  return [node, ...nodes(node.props?.children)];
}

function content(node) {
  if (Array.isArray(node)) return node.map(content).join("");
  if (typeof node === "string" || typeof node === "number") return String(node);
  return node && typeof node === "object" ? content(node.props?.children) : "";
}

const manualCalls = (state) =>
  state.calls.filter((call) => call.command === "register_device");
const autoCalls = (state) =>
  state.calls.filter((call) => call.command === "auto_register_device");
const installerLaunch = (token, mode = "prod", request_id = 1) => ({
  request_id,
  config: token ? config(token, mode) : null,
  error: null,
});

for (const [scenario, status] of [
  ["missing", { installed: false, version: null, id: null }],
  ["older", { version: "1.4.9" }],
  ["newer than the pinned version", { version: "1.6.0" }],
  ["unknown", { version: null }],
  ["a similar version prefix", { version: "1.5.01" }],
]) {
  test(`macOS configures ${scenario} RustDesk before automatic registration`, async () => {
    const state = app({ config: config("A"), status });
    await state.idle();
    const commands = state.calls.map((call) => call.command);
    assert.equal(
      commands.filter((command) => command === "configure_rustdesk").length,
      1,
    );
    assert.ok(
      commands.indexOf("configure_rustdesk") <
        commands.indexOf("auto_register_device"),
    );
    assert.equal(autoCalls(state).length, 1);
    assert.equal(state.dialogs.length, 0);
    assert.equal(state.closes, 0);
    assert.ok(state.button("Open RustDesk"));
  });
}

test("macOS keeps the required RustDesk version without running setup again", async () => {
  for (const version of ["1.5.0", "1.5.0+68", "1.5.0.0"]) {
    const state = app({
      config: config("A"),
      saved: registered(),
      status: { version },
    });
    await state.idle();
    assert.equal(
      state.calls.some((call) => call.command === "configure_rustdesk"),
      false,
    );
    assert.equal(autoCalls(state).length, 0);
    assert.equal(state.calls.some((call) => call.command === "reset_installation_state"), false);
    assert.equal(state.calls.some((call) => call.command === "read_downloaded_install_config"), false);
    assert.ok(state.button("Done"));
  }
});

test("macOS reconnect clears the old account before discovery and saves only after API success", async () => {
  const api = deferred();
  const state = app({
    config: config("OLD"),
    saved: registered("Old name"),
    download: () => config("NEW", "dev"),
    register: () => api.promise,
  });
  await state.idle();
  const reconnect = state.button("Reconnect Device").props.onClick();
  await until(() => manualCalls(state).length === 1);
  const commands = state.calls.map((call) => call.command);
  assert.ok(commands.indexOf("reset_installation_state") < commands.indexOf("read_downloaded_install_config"));
  assert.ok(commands.indexOf("read_downloaded_install_config") < commands.indexOf("register_device"));
  assert.equal(state.activeConfig, null);
  assert.equal(state.text.includes("successfully connected"), false);
  assert.equal(manualCalls(state)[0].args.computerName, "Test computer");
  api.resolve();
  await reconnect;
  await state.idle();
  assert.deepEqual(state.activeConfig, config("NEW", "dev"));
  assert.ok(state.button("Done"));
  assert.equal(state.closes, 0);
});

test("macOS reconnect sends an upsert even when the downloaded token has not changed", async () => {
  const state = app({
    config: config("SAME"),
    saved: registered(),
    download: () => config("SAME"),
  });
  await state.idle();
  await state.button("Reconnect Device").props.onClick();
  await state.idle();
  assert.equal(manualCalls(state).length, 1);
  assert.equal(manualCalls(state)[0].args.token, "SAME");
  assert.equal(autoCalls(state).length, 0);
});

test("a failed macOS reconnect keeps old data cleared and Retry uses only the candidate", async () => {
  let reject = true;
  const state = app({
    config: config("OLD"),
    saved: registered(),
    download: () => config("NEW", "local"),
    register: () => {
      if (reject) throw "Cannot connect to the registration server.";
    },
  });
  await state.idle();
  await state.button("Reconnect Device").props.onClick();
  await state.idle();
  assert.equal(state.activeConfig, null);
  assert.equal(state.button("Done"), undefined);
  assert.equal(state.button("Retry Connection").props.disabled, false);
  reject = false;
  await state.button("Retry Connection").props.onClick();
  await state.idle();
  assert.deepEqual(manualCalls(state).map((call) => call.args.token), ["NEW", "NEW"]);
  assert.equal(state.calls.filter((call) => call.command === "read_downloaded_install_config").length, 1);
  assert.deepEqual(state.activeConfig, config("NEW", "local"));
});

for (const scenario of ["missing", "invalid", "denied"]) {
  test(`macOS reconnect recovers from a ${scenario} download in the same session`, async () => {
    let ready = false;
    const state = app({
      config: config("OLD"),
      saved: registered(),
      download: () => {
        if (ready) return config("NEW");
        if (scenario === "missing") return null;
        throw scenario === "invalid" ? "Invalid install config" : "Downloads access denied";
      },
    });
    await state.idle();
    await state.button("Reconnect Device").props.onClick();
    await state.idle();
    assert.equal(state.activeConfig, null);
    assert.equal(manualCalls(state).length, 0);
    assert.equal(autoCalls(state).length, 0);
    assert.ok(state.button("Open Magenda Platform"));
    assert.equal(state.button("Retry Connection"), undefined);
    ready = true;
    await state.button("Reconnect Device").props.onClick();
    await state.idle();
    assert.equal(state.calls.filter((call) => call.command === "read_downloaded_install_config").length, 2);
    assert.deepEqual(state.activeConfig, config("NEW"));
  });
}

test("macOS reconnect stops on cleanup failure and allows a later clean retry", async () => {
  let fail = true;
  const state = app({
    config: config("OLD"),
    saved: registered(),
    reset: () => {
      if (fail) throw "Cannot clear the previous installation data.";
    },
    download: () => config("NEW"),
  });
  await state.idle();
  await state.button("Reconnect Device").props.onClick();
  await state.idle();
  assert.equal(state.calls.some((call) => call.command === "read_downloaded_install_config"), false);
  assert.equal(manualCalls(state).length, 0);
  assert.ok(state.button("Open Magenda Platform"));
  assert.equal(state.button("Rename Device"), undefined);
  fail = false;
  await state.button("Reconnect Device").props.onClick();
  await state.idle();
  assert.deepEqual(state.activeConfig, config("NEW"));
});

for (const stage of ["reset", "download", "register"]) {
  test(`a platform link takes precedence during macOS reconnect ${stage}`, async () => {
    const blocked = deferred();
    let waiting = false;
    const state = app({
      config: config("OLD"),
      saved: registered(),
      [stage]: () => {
        waiting = true;
        return blocked.promise;
      },
      ...(stage !== "download" ? { download: () => config("DOWNLOAD") } : {}),
    });
    await state.idle();
    const reconnect = state.button("Reconnect Device").props.onClick();
    await until(() => waiting);
    const manual = state.links(link("LINK", "dev"));
    blocked.resolve(config("DOWNLOAD"));
    await Promise.all([reconnect, manual]);
    await state.idle();
    assert.deepEqual(manualCalls(state).map((call) => call.args.token),
      stage === "register" ? ["DOWNLOAD", "LINK"] : ["LINK"]);
    assert.deepEqual(state.activeConfig, config("LINK", "dev"));
    assert.equal(state.dialogs.length, 1);
    assert.ok(state.button("Done"));
  });
}

test("a cancelled macOS setup stops registration and can be retried from the app", async () => {
  let cancelled = true;
  const state = app({
    config: config("A"),
    status: { version: "1.4.9" },
    configure: () => {
      // Native commands reject with strings (Result<_, String>).
      if (cancelled) throw "Administrator authorization was cancelled.";
    },
  });
  await state.idle();
  assert.equal(autoCalls(state).length, 0);
  assert.match(state.dialogs[0].text, /authorization was cancelled/);
  assert.equal(state.closes, 0);
  cancelled = false;
  await state.button("Register Device").props.onClick();
  await state.idle();
  assert.equal(manualCalls(state).length, 1);
  assert.equal(
    state.calls.filter((call) => call.command === "configure_rustdesk").length,
    2,
  );
  assert.ok(state.button("Done"));
});

test("macOS rechecks the installed version and blocks startup and manual registration on an incomplete update", async () => {
  let incomplete = true;
  const state = app({
    config: config("A"),
    status: { version: "1.4.9" },
    configure: () => (incomplete ? { version: "1.4.9" } : undefined),
  });
  await state.idle();
  assert.equal(autoCalls(state).length, 0);
  assert.match(
    state.dialogs[0].text,
    /RustDesk 1\.5\.0 installation or update did not complete/,
  );
  await state.button("Register Device").props.onClick();
  await state.idle();
  assert.equal(manualCalls(state).length, 0);
  assert.ok(state.button("Retry Connection"));
  assert.equal(state.button("Done"), undefined);
  incomplete = false;
  await state.button("Retry Connection").props.onClick();
  await state.idle();
  assert.equal(manualCalls(state).length, 1);
  assert.equal(manualCalls(state)[0].args.token, "A");
});

test("a cold macOS deep link updates RustDesk before registering the requested account", async () => {
  const state = app({
    config: config("OLD"),
    saved: registered(),
    current: () => [link("NEW", "dev")],
    status: { version: "1.4.9" },
  });
  await until(() => manualCalls(state).length === 1);
  await state.idle();
  const commands = state.calls.map((call) => call.command);
  assert.ok(
    commands.indexOf("configure_rustdesk") < commands.indexOf("register_device"),
  );
  assert.equal(
    commands.filter((command) => command === "configure_rustdesk").length,
    1,
  );
  assert.equal(autoCalls(state).length, 0);
  assert.deepEqual(state.activeConfig, config("NEW", "dev"));
  assert.ok(state.button("Open RustDesk"));
  assert.equal(state.closes, 0);
});

test("macOS permission controls open RustDesk and settings, and Done closes the app", async () => {
  const state = app({ config: config("A"), saved: registered() });
  await state.idle();
  assert.ok(state.text.includes("Allow remote assistance"));
  assert.ok(state.text.includes("add it from Applications"));
  for (const [label, command] of [
    ["Open RustDesk", "open_rustdesk"],
    ["Screen Recording", "open_screen_recording_settings"],
    ["Accessibility", "open_accessibility_settings"],
  ]) {
    assert.equal(state.button(label).props.disabled, false);
    await state.button(label).props.onClick();
    assert.equal(state.calls.at(-1).command, command);
  }
  assert.equal(state.closes, 0);
  await state.button("Done").props.onClick();
  assert.equal(state.closes, 1);
});

test("a new Mac without a token can access permission setup after installing RustDesk", async () => {
  const state = app({ status: { installed: false, version: null, id: null } });
  await state.idle();
  assert.ok(state.button("Open Magenda Platform"));
  assert.ok(state.button("Open RustDesk"));
  assert.ok(state.button("Screen Recording"));
  assert.ok(state.button("Accessibility"));
  assert.equal(state.button("Done"), undefined);
  assert.equal(autoCalls(state).length, 0);
});

test("macOS settings errors leave the app open with an actionable message", async () => {
  const state = app({
    config: config("A"),
    saved: registered(),
    openSettings: () => {
      throw "Cannot open System Settings";
    },
  });
  await state.idle();
  await state.button("Screen Recording").props.onClick();
  assert.equal(state.dialogs.at(-1).kind, "error");
  assert.match(state.dialogs.at(-1).text, /Open RustDesk or Privacy & Security/);
  assert.equal(state.closes, 0);
});

test("Windows startup does not run the macOS update or display its permission controls", async () => {
  const state = app({
    platform: "windows",
    config: config("A"),
    saved: registered(),
    status: { version: "1.4.9" },
  });
  await state.idle();
  assert.equal(
    state.calls.some((call) => call.command === "configure_rustdesk"),
    false,
  );
  assert.equal(state.button("Open RustDesk"), undefined);
  assert.equal(state.button("Done"), undefined);
});

test("the update timer does not interrupt a failed installer candidate awaiting Retry", async () => {
  const state = app({
    platform: "windows",
    visible: false,
    config: config("OLD"),
    saved: registered(),
    installer: installerLaunch("NEW", "dev"),
    auto: () => {
      throw new Error("Registration rejected");
    },
  });
  await state.idle();
  assert.ok(state.button("Retry Connection"));
  await state.runTimers();
  assert.equal(
    state.calls.filter((call) => call.command === "check_for_updates").length,
    0,
  );
  assert.equal(state.questions.length, 0);
});

test("the update timer does not use the old account after invalid installer input", async () => {
  const state = app({
    platform: "windows",
    config: config("OLD"),
    saved: registered(),
    installer: {
      request_id: 1,
      config: null,
      error: "Invalid installer filename",
    },
  });
  await state.idle();
  await state.runTimers();
  assert.equal(
    state.calls.filter((call) => call.command === "check_for_updates").length,
    0,
  );
});

test("a delayed update check is ignored when a new installer request arrives", async () => {
  const update = deferred();
  const state = app({
    platform: "windows",
    config: config("OLD"),
    saved: registered(),
    update: () => update.promise,
    auto: () => {
      throw new Error("Registration rejected");
    },
  });
  await state.idle();
  await state.runTimers();
  await state.installer(installerLaunch("NEW"));
  update.resolve({ available: true, version: "0.0.6", notes: null });
  await new Promise(setImmediate);
  assert.equal(state.questions.length, 0);
});

test("accepting an old update dialog cannot discard a newer registration candidate", async () => {
  const decision = deferred();
  const state = app({
    platform: "windows",
    config: config("OLD"),
    saved: registered(),
    ask: () => decision.promise,
    auto: () => {
      throw new Error("Registration rejected");
    },
  });
  await state.idle();
  await state.runTimers();
  assert.equal(state.questions.length, 1);
  await state.installer(installerLaunch("NEW"));
  decision.resolve(true);
  await new Promise(setImmediate);
  assert.equal(
    state.calls.filter((call) => call.command === "download_and_install_update")
      .length,
    0,
  );
});

test("an idle configured app can still accept an update", async () => {
  const state = app({
    platform: "windows",
    config: config("ACTIVE"),
    saved: registered(),
    ask: () => true,
  });
  await state.idle();
  await state.runTimers();
  assert.equal(state.questions.length, 1);
  assert.equal(
    state.calls.filter((call) => call.command === "download_and_install_update")
      .length,
    1,
  );
});

test("personalized reinstall clears the old account before POST and saves the candidate only on success", async () => {
  const api = deferred();
  const state = app({
    platform: "windows",
    visible: false,
    config: config("OLD"),
    saved: registered(),
    installer: installerLaunch("EXE", "dev"),
    auto: () => api.promise,
  });
  await until(() => autoCalls(state).length === 1);
  assert.equal(state.activeConfig, null);
  const commands = state.calls.map((call) => call.command);
  assert.ok(commands.indexOf("reset_installation_state") < commands.indexOf("auto_register_device"));
  assert.deepEqual(autoCalls(state)[0].args.config, config("EXE", "dev"));
  assert.equal(autoCalls(state)[0].args.force, true);
  assert.equal(state.visible, false);
  api.resolve();
  await state.idle();
  assert.deepEqual(state.activeConfig, config("EXE", "dev"));
  assert.equal(state.closes, 1);
  assert.equal(state.shows, 0);
  assert.equal(state.dialogs.length, 0);
});

test("first-install API failure opens the app and Retry retains the installer token/mode", async () => {
  const state = app({
    platform: "windows",
    visible: false,
    installer: installerLaunch("EXE", "dev"),
    auto: () => {
      throw new Error("Offline");
    },
  });
  await state.idle();
  assert.equal(state.visible, true);
  assert.equal(state.activeConfig, null);
  assert.equal(state.button("Retry Connection").props.disabled, false);
  await state.button("Retry Connection").props.onClick();
  assert.deepEqual(state.activeConfig, config("EXE", "dev"));
  assert.equal(manualCalls(state)[0].args.token, "EXE");
  assert.equal(state.closes, 1);
});

test("invalid installer data opens the platform flow without registering an old account", async () => {
  const state = app({
    platform: "windows",
    visible: false,
    config: config("OLD"),
    saved: registered(),
    installer: {
      request_id: 1,
      config: null,
      error: "Invalid installer filename",
    },
  });
  await state.idle();
  assert.equal(state.visible, true);
  assert.equal(state.activeConfig, null);
  assert.equal(autoCalls(state).length, 0);
  assert.ok(state.button("Open Magenda Platform"));
  assert.equal(state.button("Rename Device"), undefined);
  await state.links(link("MANUAL"));
  assert.deepEqual(state.activeConfig, config("MANUAL"));
});

test("cold-start deep link takes precedence over a simultaneous installer candidate", async () => {
  const state = app({
    platform: "windows",
    visible: false,
    installer: installerLaunch("EXE"),
    current: () => [link("MANUAL", "dev")],
  });
  await state.idle();
  assert.equal(autoCalls(state).length, 0);
  assert.deepEqual(state.activeConfig, config("MANUAL", "dev"));
});

test("manual link received during installer registration runs last and shows the window", async () => {
  const api = deferred();
  const state = app({
    platform: "windows",
    visible: false,
    installer: installerLaunch("EXE"),
    auto: () => api.promise,
  });
  await until(() => autoCalls(state).length === 1);
  const manual = state.links(link("MANUAL"));
  api.resolve();
  await manual;
  await state.idle();
  assert.deepEqual(state.activeConfig, config("MANUAL"));
  assert.equal(state.shows, 1);
  assert.equal(state.closes, 1); // The installer completion did not close early.
});

test("a new installer reaches an existing app after an earlier completed manual registration", async () => {
  const state = app({
    platform: "windows",
    config: config("OLD"),
    saved: registered(),
  });
  await state.idle();
  await state.links(link("MANUAL"));
  await state.installer(installerLaunch("EXE", "dev", 2));
  await state.idle();
  assert.deepEqual(state.activeConfig, config("EXE", "dev"));
  assert.equal(autoCalls(state).length, 1);
  assert.equal(state.closes, 1); // Existing visible app stays open after installer success.
});

test("an installer arriving while a manual request runs cannot supersede that request", async () => {
  const api = deferred();
  const state = app({
    platform: "windows",
    config: config("OLD"),
    saved: registered(),
    register: () => api.promise,
  });
  await state.idle();
  const manual = state.links(link("MANUAL"));
  await until(() => manualCalls(state).length === 1);
  await state.installer(installerLaunch("EXE", "dev", 2));
  api.resolve();
  await manual;
  assert.equal(autoCalls(state).length, 0);
  assert.equal(state.calls.some((call) => call.command === "reset_installation_state"), false);
  assert.deepEqual(state.activeConfig, config("MANUAL"));
  assert.equal(state.closes, 1);
});

test("ordinary reinstall with no new token clears old state and asks for a platform connection", async () => {
  const state = app({
    platform: "windows",
    visible: false,
    config: config("SAVED"),
    saved: registered(),
    installer: installerLaunch(null),
  });
  await state.idle();
  assert.equal(state.activeConfig, null);
  assert.equal(autoCalls(state).length, 0);
  assert.equal(state.closes, 0);
  assert.equal(state.visible, true);
  assert.ok(state.button("Open Magenda Platform"));
  assert.equal(state.button("Rename Device"), undefined);
  await state.focus();
  assert.equal(state.text.includes("successfully connected"), false);
  await state.links(link("NEW", "dev"));
  assert.deepEqual(state.activeConfig, config("NEW", "dev"));
});

test("failed reinstall retains only the new candidate for Retry", async () => {
  const state = app({
    platform: "windows",
    visible: false,
    config: config("SAVED", "dev"),
    saved: registered(),
    installer: installerLaunch("NEW", "dev"),
    auto: () => {
      throw new Error("Offline");
    },
  });
  await state.idle();
  assert.equal(state.visible, true);
  assert.equal(state.closes, 0);
  assert.equal(state.activeConfig, null);
  assert.equal(state.button("Rename Device"), undefined);
  assert.equal(state.text.includes("successfully connected"), false);
  assert.equal(state.button("Retry Connection").props.disabled, false);
  await state.focus();
  assert.equal(state.text.includes("successfully connected"), false);
  await state.button("Retry Connection").props.onClick();
  assert.equal(manualCalls(state)[0].args.token, "NEW");
  assert.equal(manualCalls(state)[0].args.mode, "dev");
  assert.equal(state.closes, 1);
});

test("an ordinary installer forwarded to a running app clears its old account too", async () => {
  const state = app({
    platform: "windows",
    config: config("SAVED"),
    saved: registered(),
  });
  await state.idle();
  assert.equal(autoCalls(state).length, 0);
  await state.installer(installerLaunch(null, "prod", 2));
  await state.idle();
  assert.equal(autoCalls(state).length, 0);
  assert.equal(state.activeConfig, null);
  assert.ok(state.button("Open Magenda Platform"));
  assert.equal(state.closes, 0);
});

test("a reset failure blocks installer registration and retry with the old account", async () => {
  const state = app({
    platform: "windows",
    visible: false,
    config: config("OLD"),
    saved: registered(),
    installer: installerLaunch("NEW"),
    reset: () => { throw new Error("Cannot clear the previous installation data"); },
  });
  await state.idle();
  assert.equal(state.visible, true);
  assert.equal(autoCalls(state).length, 0);
  assert.equal(state.closes, 0);
  assert.equal(state.button("Rename Device"), undefined);
  assert.equal(state.button("Retry Connection"), undefined);
  assert.ok(state.text.includes("Cannot clear the previous installation data"));
});

test("normal Windows startup preserves saved registration without resetting it", async () => {
  const state = app({ platform: "windows", config: config("SAVED"), saved: registered() });
  await state.idle();
  assert.equal(state.calls.some((call) => call.command === "reset_installation_state"), false);
  assert.deepEqual(state.activeConfig, config("SAVED"));
  assert.ok(state.button("Rename Device"));
});

test("startup and a live notification for the same installer do not register twice", async () => {
  const discovery = deferred();
  let reading = false;
  const candidate = installerLaunch("EXE");
  const state = app({
    platform: "windows",
    visible: false,
    installer: candidate,
    current: () => {
      reading = true;
      return discovery.promise;
    },
  });
  await until(() => reading);
  const event = state.installer(candidate);
  await new Promise(setImmediate);
  discovery.resolve([]);
  await event;
  await state.idle();
  assert.equal(autoCalls(state).length, 1);
  assert.deepEqual(state.activeConfig, config("EXE"));
});

test("StrictMode handles a hidden installer request once", async () => {
  const state = app({
    platform: "windows",
    strictMount: true,
    visible: false,
    installer: installerLaunch("EXE"),
  });
  await state.idle();
  assert.equal(autoCalls(state).length, 1);
  assert.equal(state.closes, 1);
});

test("a slow startup config read cannot discard a newer installer request", async () => {
  const oldRead = deferred();
  const first = installerLaunch("OLD_EXE", "prod", 1);
  let reading = false;
  const state = app({
    platform: "windows",
    visible: false,
    installer: first,
    readInstaller: (candidate) => {
      if (candidate?.request_id === 1) {
        reading = true;
        return oldRead.promise;
      }
      return candidate;
    },
  });
  await until(() => reading);
  const newer = state.installer(installerLaunch("NEW_EXE", "dev", 2));
  await new Promise(setImmediate);
  oldRead.resolve(first);
  await newer;
  await state.idle();
  assert.equal(autoCalls(state).length, 1);
  assert.deepEqual(state.activeConfig, config("NEW_EXE", "dev"));
});

test("an in-flight automatic registration finishes before the manual candidate", async () => {
  const automatic = deferred();
  const state = app({ config: config("A"), auto: () => automatic.promise });
  await until(() => autoCalls(state).length === 1);
  const manual = state.links(link("B", "dev"));
  assert.equal(manualCalls(state).length, 0);
  automatic.resolve();
  await manual;
  await state.idle();
  assert.equal(manualCalls(state)[0].args.token, "B");
  assert.equal(manualCalls(state)[0].args.mode, "dev");
  assert.deepEqual(state.activeConfig, config("B", "dev"));
  assert.equal(state.dialogs.length, 1);
  assert.equal(state.closes, 0); // macOS keeps the permissions panel open.
});

test("two live links keep their own token/mode and only the latest closes Windows", async () => {
  const first = deferred(),
    second = deferred();
  const state = app({
    platform: "windows",
    config: config("A"),
    saved: registered(),
    register: ({ token }) => (token === "B" ? first.promise : second.promise),
  });
  await state.idle();
  const b = state.links(link("B", "dev"));
  await until(() => manualCalls(state).length === 1);
  const c = state.links(link("C", "local"));
  first.resolve();
  await b;
  await until(() => manualCalls(state).length === 2);
  assert.equal(state.busy, true);
  assert.equal(state.dialogs.length, 0);
  assert.equal(state.closes, 0);
  assert.deepEqual(
    manualCalls(state).map((call) => [call.args.token, call.args.mode]),
    [
      ["B", "dev"],
      ["C", "local"],
    ],
  );
  second.resolve();
  await c;
  await state.idle();
  assert.deepEqual(state.activeConfig, config("C", "local"));
  assert.equal(state.dialogs.length, 1);
  assert.equal(state.closes, 1);
});

test("a rejected candidate preserves the active config and Retry uses that candidate", async () => {
  let reject = true;
  const state = app({
    config: config("A"),
    saved: registered(),
    register: () => {
      if (reject) throw new Error("Server rejected registration");
    },
  });
  await state.idle();
  await state.links(link("B", "dev"));
  await state.idle();
  assert.deepEqual(state.activeConfig, config("A"));
  assert.equal(state.text.includes("successfully connected"), false);
  assert.equal(state.button("Retry Connection").props.disabled, false);
  reject = false;
  await state.button("Retry Connection").props.onClick();
  await state.idle();
  assert.deepEqual(
    manualCalls(state).map((call) => call.args.token),
    ["B", "B"],
  );
  assert.deepEqual(state.activeConfig, config("B", "dev"));
  assert.ok(state.button("Rename Device"));
});

test("a failed newer link can be retried after an older link succeeded", async () => {
  const first = deferred();
  const state = app({
    config: config("A"),
    saved: registered(),
    register: ({ token }) => {
      if (token === "B") return first.promise;
      throw new Error("Unavailable");
    },
  });
  await state.idle();
  const b = state.links(link("B"));
  await until(() => manualCalls(state).length === 1);
  const c = state.links(link("C"));
  first.resolve();
  await Promise.all([b, c]);
  await state.idle();
  assert.deepEqual(state.activeConfig, config("B"));
  assert.equal(state.text.includes("successfully connected"), false);
  await state.button("Retry Connection").props.onClick();
  assert.equal(manualCalls(state).at(-1).args.token, "C");
});

test("cold-start links use the same retry flow even without a saved config", async () => {
  const state = app({
    current: () => [link("B")],
    register: () => {
      throw new Error("Offline");
    },
  });
  await until(() => manualCalls(state).length === 1);
  await state.idle();
  assert.equal(state.activeConfig, null);
  assert.equal(
    state.calls.some((call) => call.command === "initialize_install_config"),
    false,
  );
  assert.equal(state.button("Open Magenda Platform"), undefined);
  assert.equal(state.button("Retry Connection").props.disabled, false);
  await state.button("Retry Connection").props.onClick();
  assert.deepEqual(
    manualCalls(state).map((call) => call.args.token),
    ["B", "B"],
  );
});

test("a live manual link supersedes delayed startup discovery", async () => {
  const discovery = deferred();
  let discovering = false;
  const state = app({
    config: config("A"),
    current: () => {
      discovering = true;
      return discovery.promise;
    },
  });
  await until(() => discovering);
  const b = state.links(link("B"));
  discovery.resolve([link("A")]);
  await b;
  await state.idle();
  assert.deepEqual(
    manualCalls(state).map((call) => call.args.token),
    ["B"],
  );
  assert.equal(autoCalls(state).length, 0);
});

for (const [scenario, status] of [
  ["installation", { installed: false }],
  ["update", { version: "1.4.9" }],
]) {
  test(`manual registration waits for macOS ${scenario} without starting auto afterward`, async () => {
    const setup = deferred();
    const state = app({
      config: config("A"),
      status,
      configure: () => setup.promise,
    });
    await until(() =>
      state.calls.some((call) => call.command === "configure_rustdesk"),
    );
    assert.equal(state.button("Open RustDesk").props.disabled, true);
    const b = state.links(link("B"));
    assert.equal(manualCalls(state).length, 0);
    setup.resolve();
    await b;
    assert.equal(autoCalls(state).length, 0);
    assert.equal(
      state.calls.filter((call) => call.command === "configure_rustdesk").length,
      1,
    );
    assert.deepEqual(state.activeConfig, config("B"));
  });
}

test("a focus refresh started before registration cannot overwrite its success", async () => {
  const refresh = deferred();
  const state = app({ config: config("A"), saved: registered() });
  await state.idle();
  state.setReadOverride(() => refresh.promise);
  const focused = state.focus();
  await state.links(link("B"));
  refresh.resolve(null);
  await focused;
  await state.idle();
  assert.ok(state.button("Rename Device"));
});

test("a link received during the success dialog prevents premature window close", async () => {
  const dialog = deferred();
  let count = 0;
  const state = app({
    platform: "windows",
    config: config("A"),
    saved: registered(),
    message: () => (++count === 1 ? dialog.promise : undefined),
  });
  await state.idle();
  const b = state.links(link("B"));
  await until(() => count === 1);
  const c = state.links(link("C"));
  dialog.resolve();
  await Promise.all([b, c]);
  assert.equal(state.closes, 1);
  assert.deepEqual(state.activeConfig, config("C"));
});

test("reusing a permanent token still performs a manual upsert", async () => {
  const state = app({ config: config("A"), saved: registered() });
  await state.idle();
  await state.links(link("B"));
  await state.links(link("B"));
  assert.deepEqual(
    manualCalls(state).map((call) => call.args.token),
    ["B", "B"],
  );
});

test("StrictMode effect replay does not duplicate startup or discard manual links", async () => {
  const state = app({ strictMount: true, config: config("A") });
  await state.idle();
  assert.equal(autoCalls(state).length, 1);
  await state.links(link("B"));
  await state.idle();
  assert.deepEqual(state.activeConfig, config("B"));
  assert.equal(manualCalls(state).length, 1);
});

test("a rejected queue job does not lose the next request or clear busy early", async () => {
  const queue = new queueModule.RegistrationQueue();
  const gate = deferred();
  const first = queue.enqueue(async (latest) => {
    await gate.promise;
    assert.equal(latest(), false);
    throw new Error("Failed");
  });
  const failed = assert.rejects(first, /Failed/);
  const second = queue.enqueue(async (latest) => {
    assert.equal(queue.busy, true);
    assert.equal(latest(), true);
    return "registered";
  }, true);
  gate.resolve();
  await failed;
  assert.equal(await second, "registered");
  assert.equal(queue.busy, false);
});

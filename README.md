# Magenda Support

## Downloaded configuration

The downloaded configuration can be named `MagendaConfig-user.json`.
Numeric duplicate names such as `MagendaConfig-user (1).json` and
`MagendaConfig-user-1.json` are also supported. Legacy `install.json`,
`install (N).json`, and `install-N.json` files remain supported.

All supported names share the same selection rule: use the most recently
modified file in the searched directory. The new name has no special priority.
If the selected file is invalid, report an error without trying an older file.
The JSON fields (`install_token` and `mode`) and internal `install.json` paths
are unchanged. Downloaded source files are not deleted.

Windows searches next to the original installer when it has no personalized
filename token. macOS searches `~/Downloads` during initialization only when
its saved configuration is missing or malformed; a valid saved configuration
skips this import. macOS saves the imported configuration before registration.

The website's download filename must be changed separately; the download service
is outside this repository. Release an application with support for the new name
before switching downloads, since older applications only recognize legacy names.

## macOS startup and permissions

On startup, MagendaSupport installs RustDesk if it is missing or replaces a
different/unknown version with the bundled version, currently `1.5.0`. As in the
deployment script, the version is pinned: a newer installed version is also
replaced. The installed version is checked again after setup; errors stop
registration and leave the app open. Manual registration and deep links use the
same required-version check. Setup and registration share the existing queue.

After RustDesk is installed, the macOS permission panel is available even before
an account token is supplied. It opens RustDesk and the Screen Recording and
Accessibility sections of System Settings, where the user enables access for
RustDesk. It does not infer permission status from device registration. After
successful registration the app stays open for these steps; **Done** closes it.

## Windows installer registration

The NSIS installer accepts a token and mode in its downloaded filename:

```text
MagendaSupport-abc123-prod.exe
MagendaSupport-AbC_12-with-hyphens-dev.exe
MagendaSupport-abc123-local (1).exe
```

Modes are `prod`, `dev`, and `local`. Tokens contain ASCII letters, digits, `_`,
and `-`; their case is preserved. The mode is parsed from the end, so a token can
contain hyphens. Numeric browser suffixes such as ` (1)` are ignored.
Names starting with `MagendaSupport-` are treated as personalized installers;
an invalid token or mode is an error. Regular names such as `MagendaSupport.exe`
and `MagendaSupport_0.0.5_x64-setup.exe` use the remaining configuration sources.

The token and mode are selected together, in this order:

1. A new manual registration through a deep link.
2. The current installer's personalized EXE filename.
3. The most recently modified supported [downloaded configuration](#downloaded-configuration)
   next to that installer, including both `MagendaConfig-user` and legacy `install` names.
4. `%LOCALAPPDATA%\MagendaSupport\install.json`.
5. The legacy `%ProgramData%\Magendamd\install.json`.

A missing source permits the next source to be checked. An invalid selected
source or a rejected API request does not cause a fallback to another account.
A previously saved deep-link token is an ordinary saved configuration; a new
installer can intentionally register the device to a different account.

NSIS passes its original path to the installed application using
`--auto-register --installer-path "<original installer path>"` under `RunAsUser`.
The installed application's own filename is not used to extract the token.
The application resolves the candidate and runs registration in the same queue
as manual deep links, with its window initially hidden. Successful registration
closes the hidden window. On failure it displays the application, keeping a
valid candidate in memory for **Retry Connection**. A malformed source displays
an error and the option to connect through the platform.

Only a successful API response saves the candidate to the current user's
configuration. The installer no longer copies companion JSON to ProgramData.
If an app instance is already running, the installer request is delivered to
that instance; an active/new manual request takes precedence. An already visible
window stays open after a successful installer request.

Personalized installers still use the normal create-or-update API. They can be
reused, including with the same token. Restarting the app after a failed request
discards its in-memory candidate; reopen the installer or send a new deep link.
The updater's existing launch path is unchanged.

A signed NSIS installer can be renamed without changing its Authenticode
signature. The download service can return the same binary for a given release
and architecture with a personalized `Content-Disposition` filename. That service
is outside this repository. Tokens remain visible in filenames and download
history; the installer does not print its path to installation logs.

## Validation

```sh
npm test
npm run typecheck
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --lib --offline
```

Tests cover filename parsing, duplicate downloads, source selection, queue
ordering, hidden success, visible failure/retry, and manual deep-link priority.
They use temporary files and mocked UI/API operations, without real registration.
On Windows, also check a signed NSIS build with a personalized filename, an API
failure followed by Retry, and a deep link received during registration.

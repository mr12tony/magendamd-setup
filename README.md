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

**Reconnect Device** starts a fresh connection on macOS. First download a new
configuration file from the Magenda platform to `~/Downloads`, then click the
button. The app clears `install.json` and `registration.json` from
`~/Library/Application Support/MagendaSupport` under the registration and config
write locks. It then reads the newest supported JSON in Downloads, bypassing
the startup import cache and the saved token. Each click scans again, so a file
downloaded or corrected during the same session can be used without restarting.

Reconnection always sends a new API upsert, including when the downloaded token
matches the previous one. It does not generate a token: the platform supplies
it. The candidate stays in memory and is saved only after API success. On failure,
**Retry Connection** uses that candidate; **Reconnect Device** clears it and reads
Downloads again. Missing/invalid files and cleanup errors never fall back to the
old account. A platform deep link received during cleanup or file discovery
takes precedence and runs next in the registration queue.

Normal launches, updates and replacing the `.app` through the DMG preserve the
saved connection. A drag-and-drop DMG has no install hook; use **Reconnect Device**
when a fresh connection is needed. RustDesk ID, permissions, downloaded source
files and the registration lock are retained. With MagendaSupport closed,
`npm run uninstall:macos` removes both saved JSON files during full cleanup.

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

A missing source permits the next source to be checked. An invalid selected
source or a rejected API request does not cause a fallback to another account.
If the installer has no filename token or companion JSON, the app opens the
platform connection flow. Saved tokens are not a fallback during installation.

NSIS passes its original path to the installed application using
`--auto-register --installer-path "<original installer path>"` under `RunAsUser`.
The installed application's own filename is not used to extract the token.
The application resolves the candidate and runs registration in the same queue
as manual deep links, with its window initially hidden. Successful registration
closes the hidden window. On failure it displays the application, keeping a
valid candidate in memory for **Retry Connection**. A malformed source displays
an error and the option to connect through the platform.

Normal installations and reinstalls start a new connection. After RustDesk
deployment succeeds, the elevated NSIS hook deletes the legacy
`%ProgramData%\Magendamd\install.json`. The app launched under `RunAsUser`
clears `%LOCALAPPDATA%\MagendaSupport\install.json` and `registration.json`
under the registration lock, in the same queue as registration. Running this
part as the user avoids clearing the administrator's profile after UAC.
The lock file, other users' profiles, downloaded JSON files, and RustDesk ID
are retained. A cleanup error stops registration; it never retries an old token.

Only a successful API response saves the new candidate and registration state.
If registration fails, the old data remains deleted and **Retry Connection**
uses the new candidate. The installer never copies companion JSON to ProgramData.
If an app instance is already running, the installer request is delivered to
that instance; an active/new manual request takes precedence. An already visible
window stays open after a successful installer request.

Personalized installers still use the normal create-or-update API. They can be
reused, including with the same token. Restarting the app after a failed request
discards its in-memory candidate; reopen the installer or send a new deep link.
Updater installs (`/UPDATE`) and regular app launches preserve the saved account
and registration. A new active manual deep link still takes precedence over
an installer request; a superseded installer does not clear its state.

Ordinary Windows **Uninstall** removes the desktop user's
`%LOCALAPPDATA%\MagendaSupport\install.json` and `registration.json`, plus the
legacy `%ProgramData%\Magendamd\install.json`, whether or not **Delete app data**
is selected. It first stops MagendaSupport, then extracts and waits for a small
native helper embedded in `uninstall.exe` before deleting the application. The
helper works even if the installed main EXE is missing or damaged, and does not
initialize WebView or contact the API. It identifies the user through the shell
on the current Windows desktop and uses that user's token for path resolution,
file deletion and user registry cleanup, including when UAC uses another administrator.
It does not scan other profiles or fall back to the elevated account's profile.
The registration lock, unrelated files and downloaded configuration remain.
This clears local credentials only; it does not delete the device record from
the API.

Ordinary uninstall also removes the installed RustDesk program and its service
using `rustdesk.exe --uninstall`. RustDesk's ID and settings in user and service
profiles are kept, including when **Delete app data** is selected. An active
RustDesk remote connection ends when the service is removed. The bundled
`uninstall-rustdesk.ps1` script is embedded in `uninstall.exe`, not read from the
installed application resources. It waits for the service, installation registry
entries and program directories to disappear (up to 120 polling attempts with
one-second pauses); exiting the launcher alone is not treated as success.
An already removed RustDesk is a successful no-op. A missing RustDesk EXE with
leftover installation data, concurrent setup or incomplete removal stops uninstall
before MagendaSupport's files are removed. Repair RustDesk or let setup finish,
then retry. The development `cleanup-windows.ps1` full-purge script is not used.

With **Delete app data** selected, the helper additionally removes that user's
`%LOCALAPPDATA%\com.magendamd.support` and `%APPDATA%\com.magendamd.support` folders
and saved installer language. Directory links are removed without deleting their
targets. Autostart is cleared for the same desktop user on any ordinary uninstall.
The UAC administrator's folders and registry are not used as a fallback.

If the user cannot be identified (code 43), registration is busy (42), or a file
or registry entry cannot be removed (40), uninstall stops before removing the
application. Code 44 means invalid helper arguments; code 2 means the helper
could not be extracted or launched. Cleanup is not transactional: a later error
can leave some user data already cleared, while the application remains. Retry
from the connected user's desktop after closing MagendaSupport. A noninteractive
session without a desktop shell cannot perform ordinary cleanup. `/UPDATE`
skips token cleanup and RustDesk removal. These changes take effect after
installing a build containing the updated uninstaller.

`src-tauri/build.rs` builds the helper automatically on Windows using its own
locked Cargo package and the same target architecture. The NSIS template embeds
it from the build output, so no extra manual build step or installed sidecar is
needed. MSVC builds link its C runtime statically. Normal local release commands
remain unchanged; a missing helper fails the installer build.

Choosing **Uninstall** in the same-version EXE maintenance page exits the
installer after successful removal. Cancellation or failure returns to that
page. **Add/Reinstall**, passive installs, and **Uninstall before installing**
for an upgrade/downgrade continue with installation and the fresh connection
flow described above.
**Add/Reinstall** keeps the existing RustDesk installation. **Uninstall before
installing** removes it first and the new install deploys it again, retaining its
saved ID/configuration. An older installed uninstaller retains its old behavior
until a build containing these changes has been installed.

Windows locates RustDesk in the same order as the deployment script:
`%ProgramW6432%`, `%ProgramFiles%`, and `%ProgramFiles(x86)%` (each with
`RustDesk\rustdesk.exe` appended), followed by the standard `C:\Program Files`
and `C:\Program Files (x86)` paths. Registration, status checks, and opening
RustDesk all use this lookup, including installations on a different drive.

A signed NSIS installer can be renamed without changing its Authenticode
signature. The download service can return the same binary for a given release
and architecture with a personalized `Content-Disposition` filename. That service
is outside this repository. Tokens remain visible in filenames and download
history; the installer does not print its path to installation logs.

## Signed Windows releases in GitHub Actions

The manual **Build and Sign Windows Installer** workflow (`release-windows.yml`)
runs on a hosted Windows runner, from `main` only. It uses the existing
`npm run build:win:release` and `npm run sign:win:release` commands. The result is
an NSIS x64 installer with Azure Authenticode signing, its Tauri updater `.exe.sig`
and `SHA256SUMS.txt`, downloadable from the run's **Artifacts** section. The
workflow does not publish a GitHub release or update the production update feed.
The separate portable workflow remains available.

In GitHub **Settings → Secrets and variables → Actions → Variables**, set:

| Variable | Azure source |
| --- | --- |
| `AZURE_SIGNING_ACCOUNT_NAME` | Artifact Signing account name |
| `AZURE_CERTIFICATE_PROFILE_NAME` | Name under that account's Certificate profiles |
| `AZURE_SIGNING_ENDPOINT` | Account URI from the account Overview |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID from the account Overview |
| `AZURE_TENANT_ID` | Directory (tenant) ID from Microsoft Entra ID |
| `AZURE_CLIENT_ID` | Application (client) ID of the app registration below |

Set up GitHub's Azure identity once:

1. In Azure **Microsoft Entra ID → App registrations → New registration**, create
   `magenda-github-signing`. Select accounts in this organizational directory only
   and leave the redirect URI empty. Copy **Application (client) ID** into the
   GitHub `AZURE_CLIENT_ID` variable. Use the same tenant as the signing account.
2. In that app, open **Certificates & secrets → Federated credentials → Add
   credential** and select **GitHub Actions deploying Azure resources**. Use
   organization/owner `mr12tony`, repository `magendamd-setup`, entity **Branch**,
   branch `main`, name `github-main`. Keep issuer
   `https://token.actions.githubusercontent.com` and audience
   `api://AzureADTokenExchange`. The subject must be
   `repo:mr12tony/magendamd-setup:ref:refs/heads/main`.
3. In the Artifact Signing account's **Access control (IAM) → Add role assignment**,
   assign the **Certificate Profile Signer** role (shown as **Trusted Signing
   Certificate Profile Signer** or **Artifact Signing Certificate Profile Signer**)
   to `magenda-github-signing`. This grants signing rights on this account; no
   subscription-wide Contributor/Owner assignment is needed. Allow time for the
   new role assignment to propagate before the first run.

In the **Secrets** tab, add:

| Secret | Value |
| --- | --- |
| `TAURI_SIGNING_PRIVATE_KEY` | Contents of the existing `magendasupport.key` matching the public key in `tauri.conf.json` |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Password for that key; omit if the key is not password-protected |
| `VITE_PERMANENT_PASSWORD` | Production registration password consumed by `src-tauri/build.rs` |

Azure uses GitHub OIDC through `azure/login`, so no Azure client secret or PFX is
needed. SignTool comes from the runner's Windows SDK; the workflow installs the
Azure signing client and creates `metadata.json` from the variables in its
temporary directory. No files from the old Windows PC are needed for Azure
signing. The existing Tauri updater key is still needed separately.

After these repository changes are pushed to `main`, open **Actions → Build and
Sign Windows Installer → Run workflow**, select `main`, and start the run. Download
`MagendaSupport-windows-x64-signed` when it succeeds. Azure signing changes the
installer bytes, so the signing script checks Authenticode and regenerates the
Tauri `.sig` afterward. As in the existing local signing flow, Azure signs the
outer NSIS installer; this workflow does not add signing of the embedded app or
uninstaller. Local scripts still support the existing key file and password prompt.

## Tauri plugins and permissions

`src-tauri/capabilities/default.json` grants the frontend access to window
controls, event subscriptions, message dialogs, deep links, platform URLs and
the computer hostname. In the current OS plugin, `platform()` reads injected
data; only `hostname()` needs an IPC permission.

RustDesk setup, file access and System Settings launch run in native Rust
commands. Application updates use the Rust updater plugin and `app.restart()`.
These operations do not need frontend `fs`, `shell`, `process` or `updater`
permissions. Keep the Rust updater plugin and the single-instance plugin: they
handle application updates and forward deep links/installer requests.

## Support details in the application

Windows and macOS show **Device ID (RustDesk)**, **Copy ID**, **Refresh ID** and
**Open RustDesk**, including when registration fails or the installation token
is missing. The ID is read directly from RustDesk rather than saved registration.
It refreshes after setup/registration and when the window regains focus. The ID
probe runs off the UI thread with a three-second timeout. If no ID is available,
users can still open RustDesk and refresh; a failed clipboard copy leaves the ID
selectable for manual copying. These controls do not register or reconnect the
device. Successful hidden installer registration still closes the application.

**Reconnect Device** on Windows clears `install.json` and `registration.json`
in the current user's `%LOCALAPPDATA%\MagendaSupport` directory under the existing
registration lock. It also discards any pending token in the UI, then waits for
a new platform deep link. A per-user `ignore-legacy-install-config` marker prevents
the old `%ProgramData%\Magendamd\install.json` fallback from restoring a token
after restarting the app; the machine-wide file itself is left intact. The marker
does not interfere with a new user config saved after successful registration.
**Open Magenda Platform** keeps the app open during
this flow and uses the previous connection's environment (production/dev/local).
No registration request is sent until a new link arrives; a failed request can
be retried with its new token. RustDesk, its ID and settings are preserved.
An incoming link waits for a requested Windows reset even if it arrives before
cleanup starts. Late browser-launch completion cannot close a newer connection flow.
On macOS, reconnect continues to use the downloaded connection file.

## Validation

```sh
npm test
npm run typecheck
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --lib --offline
cargo test --manifest-path src-tauri/windows/uninstall-helper/Cargo.toml --locked --offline
```

Tests cover filename parsing, duplicate downloads, source selection, queue
ordering, hidden success, visible failure/retry, and manual deep-link priority.
They use temporary files and mocked UI/API operations, without real registration.
On Windows, also check a signed NSIS build with a personalized filename, an API
failure followed by Retry, and a deep link received during registration.
Also check the support controls after a registration failure: copy the live ID,
open the RustDesk GUI, and refresh after starting RustDesk. Repeat with RustDesk
missing and with a missing token; the panel must remain available.
Uninstall helper tests use temporary directories to check both checkbox choices,
selective, repeatable cleanup, other-profile preservation, missing data, a busy
registration lock, deletion failures and directory links. These tests do not
exercise Windows desktop-token resolution or UAC. On Windows, verify:

- Ordinary uninstall with **Delete app data** unchecked removes both registration
  JSON files and the legacy token, plus the RustDesk program and service. RustDesk
  user/service configuration files remain; reinstall and verify the ID is retained.
- The same uninstall when a standard user enters a different administrator's UAC
  credentials clears the standard user's state and keeps the administrator's
  registration files. Repeat from an RDP desktop if used in deployment.
- Repeat with **Delete app data** checked: both application data folders, saved
  language and autostart belong to the desktop user, not the UAC administrator.
- After installing the new build, close the app and rename/remove its main EXE.
  Run the installed `uninstall.exe`: cleanup and uninstall should still succeed.
- Same-version **Uninstall** exits without directory/install pages or registration;
  canceling the child uninstaller leaves the installation intact.
- **Add/Reinstall**, passive `/P`, and upgrade/downgrade **Uninstall before
  installing** continue installation; `/UPDATE` preserves saved registration and
  RustDesk. Repeat ordinary uninstall when RustDesk is already absent.
- Cleanup failure leaves the application installed and displays an error.

The RustDesk uninstall orchestration can be tested without administrator rights
or touching real installations (all OS/process boundaries are mocked):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-uninstall-rustdesk.test.ps1
```

macOS tests also cover reconnect cleanup, fresh Downloads reads, API failure and
retry, and deep links arriving during reconnect. Before release, check the native
Downloads permission prompt and the full reconnect flow in a packaged macOS app.

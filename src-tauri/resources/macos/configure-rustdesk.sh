#!/bin/bash

set -euo pipefail

# ============================================================
# MagendaSupport / RustDesk deployment for macOS
#
# Target: RustDesk 1.4.9
#
# Flow:
#   1. Require root
#   2. Detect interactive user
#   3. Detect architecture
#   4. Detect/install/update RustDesk
#   5. Close RustDesk GUI
#   6. Ensure RustDesk launchd service/agent
#   7. Stop RustDesk launchd components
#   8. Ensure base config exists
#   9. Backup + patch:
#        - user RustDesk2.toml
#        - root/service RustDesk2.toml
#  10. Start service
#  11. Apply permanent password
#  12. Verify configs
#  13. Get RustDesk ID
# ============================================================


# ============================================================
# CONFIG
# ============================================================

TARGET_VERSION="1.4.9"

RUSTDESK_ID_SERVER="rustdesk.magendamd.com"
RUSTDESK_RELAY_SERVER="rustdesk.magendamd.com"
RUSTDESK_KEY="+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="
RUSTDESK_PORT="21116"

RUSTDESK_PASSWORD="rihn7vw9"

RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK_BIN="$RUSTDESK_APP/Contents/MacOS/RustDesk"

SERVICE_LABEL="com.carriez.RustDesk_service"
AGENT_LABEL="com.carriez.RustDesk_server"

SERVICE_PLIST="/Library/LaunchDaemons/${SERVICE_LABEL}.plist"
AGENT_PLIST="/Library/LaunchAgents/${AGENT_LABEL}.plist"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARM64_DMG="$SCRIPT_DIR/rustdesk-aarch64.dmg"
X64_DMG="$SCRIPT_DIR/rustdesk-x86_64.dmg"

INSTALL_SERVICE_SCRIPT="$SCRIPT_DIR/install_service.sh"

INSTALL_TIMEOUT=90
SERVICE_TIMEOUT=30


# ============================================================
# LOGGING
# ============================================================

log() {
    echo "[RustDesk deployment] $*"
}

fail() {
    echo
    echo "[RustDesk deployment] ERROR: $*" >&2
    echo
    exit 1
}


# ============================================================
# ROOT
# ============================================================

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        fail "Root privileges are required."
    fi

    log "Root privileges: OK"
}


# ============================================================
# INTERACTIVE USER
# ============================================================

get_console_user() {
    local user

    user="$(stat -f "%Su" /dev/console 2>/dev/null || true)"

    if [[ -z "$user" || "$user" == "root" || "$user" == "loginwindow" ]]; then

        user="$(
            scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null |
            awk '/Name :/ && !/loginwindow/ { print $3 }'
        )"
    fi

    echo "$user"
}


get_user_home() {
    local user="$1"

    dscl . \
        -read "/Users/$user" \
        NFSHomeDirectory \
        2>/dev/null |
        awk '{print $2}'
}


# ============================================================
# ARCHITECTURE
# ============================================================

get_architecture() {
    case "$(uname -m)" in

        arm64)
            echo "arm64"
            ;;

        x86_64)
            echo "x86_64"
            ;;

        *)
            fail "Unsupported architecture: $(uname -m)"
            ;;
    esac
}


get_rustdesk_dmg() {
    local arch="$1"

    case "$arch" in

        arm64)

            [[ -f "$ARM64_DMG" ]] ||
                fail "ARM64 RustDesk DMG not found: $ARM64_DMG"

            echo "$ARM64_DMG"
            ;;

        x86_64)

            [[ -f "$X64_DMG" ]] ||
                fail "x86_64 RustDesk DMG not found: $X64_DMG"

            echo "$X64_DMG"
            ;;
    esac
}


# ============================================================
# VERSION
# ============================================================

get_rustdesk_version() {

    if [[ ! -f "$RUSTDESK_APP/Contents/Info.plist" ]]; then
        echo ""
        return
    fi

    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "$RUSTDESK_APP/Contents/Info.plist" \
        2>/dev/null || true
}


# ============================================================
# CLOSE GUI
# ============================================================

stop_rustdesk_gui() {

    log "Checking RustDesk GUI..."

    local uid

    uid="$CONSOLE_UID"

    # Graceful quit first.
    launchctl asuser "$uid" \
        sudo -u "$CONSOLE_USER" \
        osascript \
        -e 'tell application "RustDesk" to quit' \
        >/dev/null 2>&1 || true

    sleep 2

    # Kill only processes owned by interactive user.
    pkill \
        -u "$uid" \
        -x "RustDesk" \
        >/dev/null 2>&1 || true

    sleep 1

    log "RustDesk GUI close phase completed."
}


# ============================================================
# INSTALL / UPDATE RUSTDESK
# ============================================================

install_rustdesk_from_dmg() {

    local dmg="$1"

    [[ -f "$dmg" ]] ||
        fail "RustDesk DMG not found: $dmg"

    stop_rustdesk_gui

    local mount_dir="/tmp/magendasupport-rustdesk-$$"

    mkdir -p "$mount_dir"

    cleanup_mount() {
        hdiutil detach "$mount_dir" \
            >/dev/null 2>&1 || true

        rm -rf "$mount_dir" \
            >/dev/null 2>&1 || true
    }

    trap cleanup_mount RETURN

    log "Mounting RustDesk DMG:"
    log "$dmg"

    hdiutil attach \
        "$dmg" \
        -mountpoint "$mount_dir" \
        -nobrowse \
        -readonly \
        >/dev/null

    if [[ ! -d "$mount_dir/RustDesk.app" ]]; then
        fail "RustDesk.app not found inside DMG."
    fi

    log "Installing RustDesk.app..."

    rm -rf "$RUSTDESK_APP"

    ditto \
        "$mount_dir/RustDesk.app" \
        "$RUSTDESK_APP"

    cleanup_mount

    trap - RETURN

    if [[ ! -x "$RUSTDESK_BIN" ]]; then
        fail "RustDesk executable not found after installation."
    fi

    log "RustDesk.app installed."
}


install_or_update_rustdesk() {

    local arch
    local dmg
    local current_version

    arch="$(get_architecture)"
    dmg="$(get_rustdesk_dmg "$arch")"

    log "Architecture: $arch"

    current_version="$(get_rustdesk_version)"

    if [[ -n "$current_version" ]]; then

        log "Installed RustDesk version: [$current_version]"
        log "Required RustDesk version:  [$TARGET_VERSION]"

        if [[ "$current_version" == "$TARGET_VERSION" ]]; then

            log "Correct RustDesk version already installed."

            return
        fi

        log "RustDesk version mismatch:"
        log "$current_version -> $TARGET_VERSION"
    else

        log "RustDesk is not installed."
    fi

    install_rustdesk_from_dmg "$dmg"

    sleep 2

    current_version="$(get_rustdesk_version)"

    if [[ "$current_version" != "$TARGET_VERSION" ]]; then

        fail \
            "RustDesk version verification failed. Expected [$TARGET_VERSION], got [$current_version]."
    fi

    log "RustDesk installation/update successful."
}


# ============================================================
# SERVICE INSTALLATION
# ============================================================

ensure_rustdesk_service() {

    if [[ -f "$SERVICE_PLIST" && -f "$AGENT_PLIST" ]]; then

        log "RustDesk launchd service files already exist."

        return
    fi

    log "RustDesk launchd service is missing."
    log "Installing RustDesk service..."

    [[ -f "$INSTALL_SERVICE_SCRIPT" ]] ||
        fail "install_service.sh not found: $INSTALL_SERVICE_SCRIPT"

    chmod +x "$INSTALL_SERVICE_SCRIPT"

    #
    # Official RustDesk service installer.
    #
    # We're already root here because configure-rustdesk.sh
    # was started through osascript administrator privileges.
    #
    bash "$INSTALL_SERVICE_SCRIPT" \
        -u "$CONSOLE_USER"

    if [[ ! -f "$SERVICE_PLIST" ]]; then

        fail \
            "RustDesk daemon plist was not created: $SERVICE_PLIST"
    fi

    if [[ ! -f "$AGENT_PLIST" ]]; then

        fail \
            "RustDesk agent plist was not created: $AGENT_PLIST"
    fi

    log "RustDesk launchd service installed."
}


# ============================================================
# STOP LAUNCHD
# ============================================================

stop_rustdesk_service() {

    log "Stopping RustDesk launchd components..."

    launchctl bootout \
        "system/$SERVICE_LABEL" \
        >/dev/null 2>&1 || true

    launchctl bootout \
        "gui/$CONSOLE_UID/$AGENT_LABEL" \
        >/dev/null 2>&1 || true

    sleep 2

    log "RustDesk launchd stop phase completed."
}


# ============================================================
# START LAUNCHD
# ============================================================

start_rustdesk_service() {

    log "Starting RustDesk service..."

    launchctl bootstrap \
        system \
        "$SERVICE_PLIST" \
        >/dev/null 2>&1 || true

    launchctl enable \
        "system/$SERVICE_LABEL" \
        >/dev/null 2>&1 || true

    launchctl kickstart \
        -k \
        "system/$SERVICE_LABEL" \
        >/dev/null 2>&1 || true


    # User agent
    launchctl bootstrap \
        "gui/$CONSOLE_UID" \
        "$AGENT_PLIST" \
        >/dev/null 2>&1 || true

    launchctl enable \
        "gui/$CONSOLE_UID/$AGENT_LABEL" \
        >/dev/null 2>&1 || true

    launchctl kickstart \
        -k \
        "gui/$CONSOLE_UID/$AGENT_LABEL" \
        >/dev/null 2>&1 || true


    for ((i = 1; i <= SERVICE_TIMEOUT; i++)); do

        if launchctl print \
            "system/$SERVICE_LABEL" \
            >/dev/null 2>&1
        then
            log "RustDesk Service is RUNNING."

            sleep 3

            return
        fi

        sleep 1
    done

    fail "RustDesk service did not start."
}


# ============================================================
# BASE CONFIG
# ============================================================

ensure_base_config() {

    if [[ -f "$USER_CONFIG" ]]; then

        log "RustDesk user base config already exists."

        return
    fi

    log "RustDesk base user config is missing."
    log "Starting RustDesk briefly to initialize config..."

    launchctl asuser "$CONSOLE_UID" \
        sudo -u "$CONSOLE_USER" \
        "$RUSTDESK_BIN" \
        --server \
        >/dev/null 2>&1 &

    local init_pid=$!

    for i in {1..20}; do

        if [[ -f "$USER_CONFIG" ]]; then

            log "RustDesk created base user config."

            kill "$init_pid" \
                >/dev/null 2>&1 || true

            return
        fi

        sleep 1
    done

    kill "$init_pid" \
        >/dev/null 2>&1 || true

    log "RustDesk did not create RustDesk2.toml."
    log "Creating base config ourselves."

    mkdir -p "$USER_CONFIG_DIR"

    touch "$USER_CONFIG"

    chown -R \
        "$CONSOLE_USER":staff \
        "$USER_CONFIG_DIR"
}


# ============================================================
# TOML PATCH
# ============================================================

patch_rustdesk_toml() {

    local path="$1"

    log "Patching RustDesk config:"
    log "$path"

    mkdir -p "$(dirname "$path")"

    if [[ -f "$path" ]]; then

        cp \
            "$path" \
            "$path.bak"

        log "Backup created:"
        log "$path.bak"
    fi


    CONFIG_PATH="$path" \
    ID_SERVER="$RUSTDESK_ID_SERVER" \
    RELAY_SERVER="$RUSTDESK_RELAY_SERVER" \
    RUSTDESK_KEY_VALUE="$RUSTDESK_KEY" \
    RUSTDESK_PORT_VALUE="$RUSTDESK_PORT" \
    /usr/bin/python3 <<'PY'
import os
import re

path = os.environ["CONFIG_PATH"]
id_server = os.environ["ID_SERVER"]
relay_server = os.environ["RELAY_SERVER"]
key = os.environ["RUSTDESK_KEY_VALUE"]
port = os.environ["RUSTDESK_PORT_VALUE"]

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
else:
    content = ""

rendezvous = f"{id_server}:{port}"


# ============================================================
# TOP-LEVEL rendezvous_server
# ============================================================

top_pattern = r"(?m)^rendezvous_server\s*=.*$"

if re.search(top_pattern, content):

    content = re.sub(
        top_pattern,
        f"rendezvous_server = '{rendezvous}'",
        content,
        count=1,
    )

else:

    content = (
        f"rendezvous_server = '{rendezvous}'\n"
        + content
    )


# ============================================================
# FIND [options]
# ============================================================

section_pattern = (
    r"(?ms)^\[options\]\s*\n"
    r"(.*?)(?=^\[|\Z)"
)

match = re.search(
    section_pattern,
    content,
)

if not match:

    if content and not content.endswith("\n"):
        content += "\n"

    content += "\n[options]\n"

    match = re.search(
        section_pattern,
        content,
    )


start, end = match.span(1)

block = match.group(1)


def set_option(block, name, value):

    pattern = (
        rf"(?m)^{re.escape(name)}"
        rf"\s*=.*$"
    )

    replacement = (
        f"{name} = '{value}'"
    )

    if re.search(pattern, block):

        return re.sub(
            pattern,
            replacement,
            block,
            count=1,
        )

    if block and not block.endswith("\n"):
        block += "\n"

    return (
        block
        + replacement
        + "\n"
    )


block = set_option(
    block,
    "custom-rendezvous-server",
    id_server,
)

block = set_option(
    block,
    "relay-server",
    relay_server,
)

block = set_option(
    block,
    "key",
    key,
)


content = (
    content[:start]
    + block
    + content[end:]
)


with open(
    path,
    "w",
    encoding="utf-8",
) as f:
    f.write(content)
PY

    log "RustDesk config patched successfully."
}


# ============================================================
# VERIFY
# ============================================================

verify_rustdesk_toml() {

    local path="$1"

    [[ -f "$path" ]] ||
        fail "RustDesk config not found: $path"


    grep -Fq \
        "rendezvous_server = '$RUSTDESK_ID_SERVER:$RUSTDESK_PORT'" \
        "$path" ||
        fail "rendezvous_server verification failed: $path"


    grep -Fq \
        "custom-rendezvous-server = '$RUSTDESK_ID_SERVER'" \
        "$path" ||
        fail "custom-rendezvous-server verification failed: $path"


    grep -Fq \
        "relay-server = '$RUSTDESK_RELAY_SERVER'" \
        "$path" ||
        fail "relay-server verification failed: $path"


    grep -Fq \
        "key = '$RUSTDESK_KEY'" \
        "$path" ||
        fail "RustDesk key verification failed: $path"


    log "Config verification OK:"
    log "$path"
}


# ============================================================
# PASSWORD
# ============================================================

apply_rustdesk_password() {

    log "Applying RustDesk permanent password..."

    for attempt in 1 2 3; do

        log "Password attempt $attempt/3..."

        set +e

        result="$(
            "$RUSTDESK_BIN" \
                --password \
                "$RUSTDESK_PASSWORD" \
                2>&1
        )"

        status=$?

        set -e

        log "Password CLI response: [$result]"
        log "Password CLI exit code: [$status]"

        if [[ "$status" -eq 0 ]]; then

            log "Permanent password command completed."

            sleep 2

            return
        fi

        sleep 2
    done

    fail "RustDesk --password failed."
}


# ============================================================
# GET ID
# ============================================================

get_rustdesk_id() {

    "$RUSTDESK_BIN" \
        --get-id \
        2>/dev/null |
        tr -d '\r\n'
}


# ============================================================
# MAIN
# ============================================================

log ""
log "============================================"
log "RustDesk deployment started"
log "Target version: $TARGET_VERSION"
log "============================================"
log ""


require_root


# ============================================================
# USER
# ============================================================

CONSOLE_USER="$(get_console_user)"

if [[ -z "$CONSOLE_USER" ]]; then

    fail "Could not determine interactive macOS user."
fi

CONSOLE_UID="$(id -u "$CONSOLE_USER")"

USER_HOME="$(get_user_home "$CONSOLE_USER")"

if [[ -z "$USER_HOME" ]]; then

    fail "Could not determine interactive user's home directory."
fi


log "Interactive user: $CONSOLE_USER"
log "Interactive UID:  $CONSOLE_UID"
log "User home:        $USER_HOME"


# ============================================================
# CONFIG PATHS
# ============================================================

USER_CONFIG_DIR="$USER_HOME/Library/Preferences/com.carriez.RustDesk"

USER_CONFIG="$USER_CONFIG_DIR/RustDesk2.toml"


ROOT_CONFIG_DIR="/var/root/Library/Preferences/com.carriez.RustDesk"

ROOT_CONFIG="$ROOT_CONFIG_DIR/RustDesk2.toml"


log "User config:"
log "$USER_CONFIG"

log "Root/service config:"
log "$ROOT_CONFIG"


# ============================================================
# INSTALL / UPDATE
# ============================================================

install_or_update_rustdesk


# ============================================================
# STOP GUI
# ============================================================

stop_rustdesk_gui


# ============================================================
# SERVICE
# ============================================================

ensure_rustdesk_service


# ============================================================
# STOP SERVICE DURING CONFIG PATCH
# ============================================================

stop_rustdesk_service


# ============================================================
# BASE USER CONFIG
# ============================================================

ensure_base_config


# ============================================================
# ROOT BASE CONFIG
# ============================================================

mkdir -p "$ROOT_CONFIG_DIR"

if [[ ! -f "$ROOT_CONFIG" ]]; then

    cp \
        "$USER_CONFIG" \
        "$ROOT_CONFIG"
fi


# ============================================================
# PATCH BOTH
# ============================================================

patch_rustdesk_toml "$USER_CONFIG"

patch_rustdesk_toml "$ROOT_CONFIG"


# ============================================================
# OWNERSHIP
# ============================================================

chown -R \
    "$CONSOLE_USER":staff \
    "$USER_CONFIG_DIR"

chown -R \
    root:wheel \
    "$ROOT_CONFIG_DIR"


# ============================================================
# VERIFY BEFORE SERVICE START
# ============================================================

verify_rustdesk_toml "$USER_CONFIG"

verify_rustdesk_toml "$ROOT_CONFIG"


# ============================================================
# START SERVICE
# ============================================================

start_rustdesk_service


# ============================================================
# PASSWORD
# ============================================================

apply_rustdesk_password


# ============================================================
# VERIFY AGAIN
# ============================================================

sleep 3

verify_rustdesk_toml "$USER_CONFIG"

verify_rustdesk_toml "$ROOT_CONFIG"


# ============================================================
# FINAL VERSION
# ============================================================

ACTUAL_VERSION="$(get_rustdesk_version)"

if [[ "$ACTUAL_VERSION" != "$TARGET_VERSION" ]]; then

    fail \
        "Final version mismatch. Expected [$TARGET_VERSION], got [$ACTUAL_VERSION]."
fi

log "RustDesk version: [$ACTUAL_VERSION]"


# ============================================================
# GET ID
# ============================================================

RUSTDESK_ID=""

for attempt in {1..10}; do

    RUSTDESK_ID="$(
        get_rustdesk_id || true
    )"

    if [[ -n "$RUSTDESK_ID" ]]; then
        break
    fi

    log "RustDesk ID not ready. Retry $attempt/10..."

    sleep 2
done


if [[ -z "$RUSTDESK_ID" ]]; then

    fail "RustDesk ID is empty."
fi


# ============================================================
# SUCCESS
# ============================================================

log ""
log "============================================"
log "RustDesk deployment SUCCESS"
log "============================================"
log "Version : $ACTUAL_VERSION"
log "ID      : $RUSTDESK_ID"
log "Server  : $RUSTDESK_ID_SERVER"
log "Relay   : $RUSTDESK_RELAY_SERVER"
log "User    : $CONSOLE_USER"
log "Service : RUNNING"
log "============================================"
log ""

exit 0
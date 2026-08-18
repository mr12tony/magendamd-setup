#!/bin/bash

set -u

# ==========================================================
# RustDesk macOS installer for Tauri
#
# Tauri runs:
#
#   bash resources/macos/install.sh PASSWORD
#
# The script itself requests administrator privileges.
#
# RustDesk:
#   1.4.9
#
# IMPORTANT:
#   We intentionally DO NOT use:
#
#       RustDesk --config ...
#
# Network configuration is written directly to RustDesk2.toml.
# ==========================================================

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

# ==========================================================
# ORIGINAL SCRIPT DIRECTORY
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==========================================================
# ARGUMENTS
# ==========================================================

PASSWORD="${1:-}"

if [ -z "$PASSWORD" ]; then
    echo "ERROR: RustDesk password is required."
    exit 1
fi

# ==========================================================
# CONFIGURATION
# ==========================================================

RENDEZVOUS_SERVER="rustdesk.magendamd.com"
RELAY_SERVER="rustdesk.magendamd.com"

RUSTDESK_KEY="+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

# ==========================================================
# LOGGING
# ==========================================================

LOG_FILE="/tmp/rustdesk-install.log"

touch "$LOG_FILE" 2>/dev/null || true

log() {
    local message="$1"

    echo "$(date '+%Y-%m-%d %H:%M:%S') $message" |
        tee -a "$LOG_FILE"
}

# ==========================================================
# FIND CONSOLE USER
# ==========================================================

CONSOLE_USER="$(
    stat -f '%Su' /dev/console 2>/dev/null || true
)"

if [ -z "$CONSOLE_USER" ] ||
   [ "$CONSOLE_USER" = "root" ] ||
   [ "$CONSOLE_USER" = "loginwindow" ]; then

    log "ERROR: no logged-in GUI user found."
    exit 1
fi

USER_HOME="$(
    dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null |
        awk '{print $2}'
)"

if [ -z "$USER_HOME" ]; then
    USER_HOME="/Users/$CONSOLE_USER"
fi

USER_CONFIG_DIR="$USER_HOME/Library/Preferences/com.carriez.RustDesk"

USER_RUSTDESK2="$USER_CONFIG_DIR/RustDesk2.toml"

USER_UID="$(
    id -u "$CONSOLE_USER"
)"

# ==========================================================
# ADMIN PRIVILEGES
# ==========================================================

if [ "$(id -u)" -ne 0 ]; then

    log "Administrator privileges required."

    TEMP_SCRIPT="$(
        mktemp /tmp/rustdesk-install.XXXXXX.sh
    )"

    if [ ! -f "$TEMP_SCRIPT" ]; then
        log "ERROR: failed to create temporary installer."
        exit 1
    fi

    # ------------------------------------------------------
    # Copy this exact installer to /tmp.
    #
    # SCRIPT_DIR is passed explicitly to the root phase.
    # ------------------------------------------------------

    cp "$0" "$TEMP_SCRIPT"

    chmod 700 "$TEMP_SCRIPT"

    PROMPT="Administrator privileges are required to install RustDesk."

    log "Requesting administrator privileges..."

    /usr/bin/osascript \
        -e 'on run argv' \
        -e 'set scriptPath to item 1 of argv' \
        -e 'set passwordValue to item 2 of argv' \
        -e 'set scriptDirectory to item 3 of argv' \
        -e 'set promptText to item 4 of argv' \
        -e 'do shell script "/bin/bash " & quoted form of scriptPath & " " & quoted form of passwordValue & " " & quoted form of scriptDirectory with administrator privileges with prompt promptText' \
        -e 'end run' \
        -- \
        "$TEMP_SCRIPT" \
        "$PASSWORD" \
        "$SCRIPT_DIR" \
        "$PROMPT"

    EXIT_CODE=$?

    rm -f "$TEMP_SCRIPT"

    if [ "$EXIT_CODE" -ne 0 ]; then
        log "ERROR: administrator authorization failed."
        exit "$EXIT_CODE"
    fi

    exit 0
fi

# ==========================================================
# ROOT PHASE
# ==========================================================

# When running as root through the temporary script,
# $2 contains the original bundled SCRIPT_DIR.

ORIGINAL_SCRIPT_DIR="${2:-$SCRIPT_DIR}"

if [ -d "$ORIGINAL_SCRIPT_DIR" ]; then
    SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR"
fi

# ==========================================================
# PATHS
# ==========================================================

APP="/Applications/RustDesk.app"

RUSTDESK="$APP/Contents/MacOS/RustDesk"

MOUNT_POINT="/Volumes/RustDeskInstaller"

SERVER_LOG="/tmp/rustdesk-server.log"

USER_LOG="/tmp/rustdesk-user.log"

# ==========================================================
# HEADER
# ==========================================================

echo ""
echo "========================================"
echo "RustDesk installer"
echo "========================================"

log "Running as      : $(id -un)"
log "Console user    : $CONSOLE_USER"
log "User home       : $USER_HOME"
log "Script directory: $SCRIPT_DIR"

# ==========================================================
# ARCHITECTURE
# ==========================================================

ARCH="$(uname -m)"

case "$ARCH" in

    arm64)
        BUNDLED_DMG="$SCRIPT_DIR/rustdesk-aarch64.dmg"
        ;;

    x86_64)
        BUNDLED_DMG="$SCRIPT_DIR/rustdesk-x86_64.dmg"
        ;;

    *)
        log "ERROR: unsupported architecture: $ARCH"
        exit 1
        ;;

esac

log "Architecture: $ARCH"
log "DMG: $BUNDLED_DMG"

if [ ! -f "$BUNDLED_DMG" ]; then

    log "ERROR: RustDesk DMG not found:"
    log "$BUNDLED_DMG"

    exit 1
fi

# ==========================================================
# STOP RUSTDESK
# ==========================================================

log "Stopping RustDesk..."

pkill -9 -x RustDesk 2>/dev/null || true

pkill -9 -f "/RustDesk.app/" 2>/dev/null || true

sleep 1

# ==========================================================
# STOP SERVICES
# ==========================================================

log "Stopping RustDesk services..."

launchctl bootout \
    system/com.carriez.RustDesk_service \
    2>/dev/null || true

launchctl bootout \
    "gui/$USER_UID/com.carriez.RustDesk.autostart" \
    2>/dev/null || true

# ==========================================================
# REMOVE SERVICE FILES
# ==========================================================

log "Removing old service files..."

rm -f \
    "/Library/LaunchDaemons/com.carriez.RustDesk_service.plist" \
    "/Library/LaunchAgents/com.carriez.RustDesk_service.plist" \
    "$USER_HOME/Library/LaunchAgents/com.carriez.RustDesk.autostart.plist"

# ==========================================================
# REMOVE APP
# ==========================================================

log "Removing old RustDesk.app..."

rm -rf "$APP"

# ==========================================================
# REMOVE USER DATA
# ==========================================================

log "Removing old RustDesk configuration..."

rm -rf "$USER_CONFIG_DIR"

rm -rf \
    "$USER_HOME/Library/Logs/RustDesk" \
    "$USER_HOME/Library/Application Support/RustDesk" \
    "$USER_HOME/Library/Caches/com.carriez.RustDesk" \
    "$USER_HOME/Library/Saved Application State/com.carriez.RustDesk.savedState"

# ==========================================================
# REMOVE SYSTEM DATA
# ==========================================================

log "Removing system RustDesk leftovers..."

rm -rf \
    "/Library/Application Support/RustDesk" \
    "/Library/Logs/RustDesk" \
    "/Library/Preferences/com.carriez.RustDesk" \
    "/var/root/Library/Preferences/com.carriez.RustDesk" \
    "/var/root/Library/Logs/RustDesk"

# ==========================================================
# UNMOUNT OLD DMGs
# ==========================================================

log "Unmounting old RustDesk DMGs..."

for volume in /Volumes/*; do

    if [ -d "$volume" ]; then

        case "$volume" in

            *rustdesk*|*RustDesk*)

                log "Unmounting: $volume"

                hdiutil detach "$volume" \
                    -force \
                    >/dev/null 2>&1 || true

                ;;

        esac

    fi

done

rm -rf "$MOUNT_POINT"

# ==========================================================
# MOUNT DMG
# ==========================================================

log "Mounting RustDesk DMG..."

mkdir -p "$MOUNT_POINT"

hdiutil attach \
    "$BUNDLED_DMG" \
    -mountpoint "$MOUNT_POINT" \
    -nobrowse \
    -quiet

# ==========================================================
# FIND RUSTDESK.APP
# ==========================================================

SOURCE_APP="$MOUNT_POINT/RustDesk.app"

if [ ! -d "$SOURCE_APP" ]; then

    SOURCE_APP="$(
        find "$MOUNT_POINT" \
            -maxdepth 2 \
            -type d \
            -name "RustDesk.app" \
            -print \
            -quit
    )"

fi

if [ -z "${SOURCE_APP:-}" ] ||
   [ ! -d "$SOURCE_APP" ]; then

    log "ERROR: RustDesk.app not found in DMG."

    hdiutil detach "$MOUNT_POINT" \
        -force \
        >/dev/null 2>&1 || true

    exit 1
fi

log "RustDesk.app found."

# ==========================================================
# INSTALL APP
# ==========================================================

log "Copying RustDesk.app..."

ditto "$SOURCE_APP" "$APP"

# ==========================================================
# UNMOUNT DMG
# ==========================================================

log "Unmounting RustDesk DMG..."

hdiutil detach "$MOUNT_POINT" \
    -quiet \
    >/dev/null 2>&1 || true

# ==========================================================
# WAIT FOR EXECUTABLE
# ==========================================================

log "Waiting for RustDesk executable..."

DEADLINE=$((SECONDS + 60))

while [ ! -x "$RUSTDESK" ]; do

    if [ "$SECONDS" -ge "$DEADLINE" ]; then

        log "ERROR: RustDesk executable not found."

        exit 1
    fi

    sleep 1

done

log "RustDesk executable found."

# ==========================================================
# APP OWNERSHIP
# ==========================================================

chown -R root:wheel "$APP"

# ==========================================================
# CREATE USER CONFIG DIRECTORY
# ==========================================================

log "Preparing user configuration..."

mkdir -p "$USER_CONFIG_DIR"

chown "$CONSOLE_USER:staff" \
    "$USER_CONFIG_DIR"

chmod 700 \
    "$USER_CONFIG_DIR"

# ==========================================================
# START RUSTDESK AS USER
# ==========================================================

log "Starting RustDesk GUI as $CONSOLE_USER..."

sudo -u "$CONSOLE_USER" \
    "$RUSTDESK" \
    >"$USER_LOG" \
    2>&1 &

RUSTDESK_USER_PID=$!

log "RustDesk GUI PID: $RUSTDESK_USER_PID"

# ==========================================================
# WAIT FOR RUSTDESK2.TOML
# ==========================================================

log "Waiting for RustDesk user configuration..."

DEADLINE=$((SECONDS + 45))

while [ ! -f "$USER_RUSTDESK2" ]; do

    if [ "$SECONDS" -ge "$DEADLINE" ]; then

        log "ERROR: RustDesk2.toml was not created."

        echo ""
        echo "RustDesk log:"
        cat "$USER_LOG" 2>/dev/null || true

        exit 1
    fi

    sleep 1

done

log "User configuration created."

# ==========================================================
# PASSWORD
# ==========================================================

log "Applying RustDesk password..."

PASSWORD_OUTPUT="$(
    "$RUSTDESK" \
        --password "$PASSWORD" \
        2>&1
)"

PASSWORD_EXIT=$?

if [ "$PASSWORD_EXIT" -ne 0 ]; then

    log "ERROR: password configuration failed."

    log "$PASSWORD_OUTPUT"

    exit 1
fi

log "Password applied."

# ==========================================================
# NETWORK CONFIGURATION
#
# DO NOT USE:
#
#   --config
#
# We write the working GUI-compatible TOML directly.
# ==========================================================

log "Applying network configuration..."

cat > "$USER_RUSTDESK2" <<EOF
rendezvous_server = '$RENDEZVOUS_SERVER:21116'
nat_type = 1
serial = 0
unlock_pin = ''
trusted_devices = ''

[options]
relay-server = '$RELAY_SERVER'
custom-rendezvous-server = '$RENDEZVOUS_SERVER'
key = '$RUSTDESK_KEY'
EOF

# ==========================================================
# OWNERSHIP
# ==========================================================

log "Fixing configuration ownership..."

chown "$CONSOLE_USER:staff" \
    "$USER_CONFIG_DIR"

chmod 700 \
    "$USER_CONFIG_DIR"

for file in "$USER_CONFIG_DIR"/*.toml; do

    [ -f "$file" ] || continue

    chown "$CONSOLE_USER:staff" "$file"

    chmod 600 "$file"

done

# ==========================================================
# VERIFY CONFIG
# ==========================================================

log "Checking RustDesk2.toml..."

if ! grep -q \
    "rendezvous_server = '$RENDEZVOUS_SERVER:21116'" \
    "$USER_RUSTDESK2"; then

    log "ERROR: rendezvous_server was not configured."

    exit 1
fi

if ! grep -q \
    "custom-rendezvous-server = '$RENDEZVOUS_SERVER'" \
    "$USER_RUSTDESK2"; then

    log "ERROR: custom rendezvous server was not configured."

    exit 1
fi

if ! grep -q \
    "relay-server = '$RELAY_SERVER'" \
    "$USER_RUSTDESK2"; then

    log "ERROR: relay server was not configured."

    exit 1
fi

if ! grep -q \
    "key = '$RUSTDESK_KEY'" \
    "$USER_RUSTDESK2"; then

    log "ERROR: RustDesk key was not configured."

    exit 1
fi

log "Network configuration verified."

# ==========================================================
# STOP TEMPORARY GUI
# ==========================================================

log "Stopping temporary RustDesk GUI..."

kill "$RUSTDESK_USER_PID" \
    2>/dev/null || true

sleep 2

pkill -9 -x RustDesk \
    2>/dev/null || true

sleep 2

# ==========================================================
# START RUSTDESK AGAIN
# ==========================================================

log "Starting RustDesk again..."

sudo -u "$CONSOLE_USER" \
    "$RUSTDESK" \
    >"$USER_LOG" \
    2>&1 &

FINAL_GUI_PID=$!

log "RustDesk GUI PID: $FINAL_GUI_PID"

sleep 3

# ==========================================================
# GET ID
# ==========================================================

log "Getting RustDesk ID..."

ID=""

for i in $(seq 1 30); do

    ID="$(
        sudo -u "$CONSOLE_USER" \
        "$RUSTDESK" \
        --get-id \
        2>/dev/null |
        tr -d '\r\n '
    )"

    if [ -n "$ID" ]; then
        break
    fi

    sleep 1

done

if [ -z "$ID" ]; then

    log "ERROR: RustDesk ID is empty."

    echo ""
    echo "RustDesk user log:"
    cat "$USER_LOG" 2>/dev/null || true

    exit 1
fi

# ==========================================================
# FINAL OWNERSHIP
# ==========================================================

chown "$CONSOLE_USER:staff" \
    "$USER_CONFIG_DIR"

chmod 700 \
    "$USER_CONFIG_DIR"

for file in "$USER_CONFIG_DIR"/*.toml; do

    [ -f "$file" ] || continue

    chown "$CONSOLE_USER:staff" "$file"

    chmod 600 "$file"

done

# ==========================================================
# FINAL CONFIG CHECK
# ==========================================================

echo ""
echo "Final RustDesk configuration:"
echo ""

grep -E \
    "rendezvous_server|relay-server|custom-rendezvous-server|^key" \
    "$USER_RUSTDESK2" \
    || true

# ==========================================================
# OPEN GUI
# ==========================================================

log "Opening RustDesk GUI..."

launchctl asuser "$USER_UID" \
    sudo -u "$CONSOLE_USER" \
    open -n "$APP" \
    >/dev/null 2>&1 || true

# ==========================================================
# RESULT
# ==========================================================

echo ""
echo "========================================"
echo "RustDesk installation completed"
echo "========================================"
echo ""
echo "User:"
echo "  $CONSOLE_USER"
echo ""
echo "Architecture:"
echo "  $ARCH"
echo ""
echo "RustDesk ID:"
echo "  $ID"
echo ""
echo "Network:"
echo "  $RENDEZVOUS_SERVER"
echo ""
echo "Relay:"
echo "  $RELAY_SERVER"
echo ""
echo "Password:"
echo "  configured"
echo ""
echo "User config:"
echo "  $USER_CONFIG_DIR"
echo ""
echo "Installer log:"
echo "  $LOG_FILE"
echo ""
echo "User log:"
echo "  $USER_LOG"
echo ""
echo "========================================"

exit 0
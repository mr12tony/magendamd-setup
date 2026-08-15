#!/bin/bash

set -u

# ============================================================
# RustDesk macOS installer for Tauri
#
# Arguments:
#   $1 = RustDesk password
#   $2 = RustDesk config
#
# Resources:
#   resources/macos/install.sh
#   resources/macos/rustdesk-aarch64.dmg
#   resources/macos/rustdesk-x86_64.dmg
# ============================================================

# ------------------------------------------------------------
# Basic paths
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK="$RUSTDESK_APP/Contents/MacOS/RustDesk"
MOUNT_POINT="/Volumes/RustDesk"

LOG_FILE="$SCRIPT_DIR/rustdesk-install.log"

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

RUSTDESK_PASSWORD="${1:-}"
RUSTDESK_CONFIG="${2:-}"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

log() {
    local msg="$1"
    local line

    line="$(date '+%Y-%m-%d %H:%M:%S') - $msg"

    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

separator() {
    log "============================================================"
}

# ------------------------------------------------------------
# Validate arguments
# ------------------------------------------------------------

separator
log "RustDesk installer started"
separator

log "Script:      $0"
log "PID:         $$"
log "Current user: $(id -un)"
log "UID:         $(id -u)"
log "SCRIPT_DIR:  $SCRIPT_DIR"
log "LOG_FILE:    $LOG_FILE"

if [ -n "$RUSTDESK_PASSWORD" ]; then
    log "[ARGS] Password provided: YES"
else
    log "[ARGS] Password provided: NO"
fi

if [ -n "$RUSTDESK_CONFIG" ]; then
    log "[ARGS] Config provided: YES"
else
    log "[ARGS] Config provided: NO"
fi

if [ -z "$RUSTDESK_PASSWORD" ]; then
    log "[ERROR] RustDesk password is required."
    exit 1
fi

if [ -z "$RUSTDESK_CONFIG" ]; then
    log "[ERROR] RustDesk config is required."
    exit 1
fi

# ============================================================
# Determine console user
# ============================================================

CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    log "[ERROR] Unable to determine console user."
    exit 1
fi

CONSOLE_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null \
    | awk '{print $2}')"

if [ -z "$CONSOLE_HOME" ]; then
    CONSOLE_HOME="/Users/$CONSOLE_USER"
fi

log "[USER] Console user: $CONSOLE_USER"
log "[USER] Console home: $CONSOLE_HOME"

# ============================================================
# Root escalation
# ============================================================

if [ "$(id -u)" -ne 0 ]; then

    separator
    log "[ADMIN] Administrator privileges required."
    log "[ADMIN] Creating temporary privileged installer..."

    TEMP_SCRIPT="$(mktemp /tmp/rustdesk-install.XXXXXX.sh)"

    if [ ! -f "$TEMP_SCRIPT" ]; then
        log "[ERROR] Failed to create temporary installer."
        exit 1
    fi

    # --------------------------------------------------------
    # Create root installer.
    #
    # Pass arguments through environment variables instead of
    # putting password/config directly into AppleScript command.
    # --------------------------------------------------------

    export RD_PASSWORD="$RUSTDESK_PASSWORD"
    export RD_CONFIG="$RUSTDESK_CONFIG"
    export RD_CONSOLE_USER="$CONSOLE_USER"
    export RD_CONSOLE_HOME="$CONSOLE_HOME"
    export RD_SCRIPT_DIR="$SCRIPT_DIR"
    export RD_LOG_FILE="$LOG_FILE"

    cat > "$TEMP_SCRIPT" <<'ROOT_SCRIPT'
#!/bin/bash

set -u

RUSTDESK_PASSWORD="${RD_PASSWORD:-}"
RUSTDESK_CONFIG="${RD_CONFIG:-}"
CONSOLE_USER="${RD_CONSOLE_USER:-}"
CONSOLE_HOME="${RD_CONSOLE_HOME:-}"
SCRIPT_DIR="${RD_SCRIPT_DIR:-}"
LOG_FILE="${RD_LOG_FILE:-}"

RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK="$RUSTDESK_APP/Contents/MacOS/RustDesk"
MOUNT_POINT="/Volumes/RustDesk"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

log() {
    local msg="$1"
    local line

    line="$(date '+%Y-%m-%d %H:%M:%S') - $msg"

    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

separator() {
    log "============================================================"
}

# ============================================================
# Root phase
# ============================================================

separator
log "RustDesk privileged installer started"
log "Running as: $(id -un)"
log "UID: $(id -u)"
separator

# ============================================================
# Architecture
# ============================================================

ARCH="$(arch)"

log "[ARCH] Detected architecture: $ARCH"

if [ "$ARCH" = "arm64" ]; then
    DMG_FILE="$SCRIPT_DIR/rustdesk-aarch64.dmg"
else
    DMG_FILE="$SCRIPT_DIR/rustdesk-x86_64.dmg"
fi

log "[ARCH] Selected DMG: $DMG_FILE"

if [ ! -f "$DMG_FILE" ]; then
    log "[ERROR] DMG file does not exist."
    exit 1
fi

log "[ARCH] DMG exists: YES"

# ============================================================
# Stop RustDesk
# ============================================================

separator
log "[CLEANUP] Stopping existing RustDesk processes..."

killall RustDesk >/dev/null 2>&1 || true
killall rustdesk >/dev/null 2>&1 || true

sleep 1

killall -9 RustDesk >/dev/null 2>&1 || true
killall -9 rustdesk >/dev/null 2>&1 || true

sleep 1

if pgrep -fl RustDesk >/dev/null 2>&1; then
    log "[CLEANUP] WARNING: RustDesk processes still exist."
else
    log "[CLEANUP] No RustDesk processes remain."
fi

# ============================================================
# Remove old application
# ============================================================

separator
log "[REMOVE] Removing previous RustDesk installation..."

rm -rf "$RUSTDESK_APP"

if [ -d "$RUSTDESK_APP" ]; then
    log "[ERROR] Failed to remove old RustDesk.app."
    exit 1
fi

log "[REMOVE] RustDesk.app removed."

# ============================================================
# Remove user data
# ============================================================

separator
log "[REMOVE] Removing previous RustDesk user data..."

USER_PREFS="$CONSOLE_HOME/Library/Preferences/com.carriez.RustDesk"
USER_LOGS="$CONSOLE_HOME/Library/Logs/RustDesk"
USER_SUPPORT="$CONSOLE_HOME/Library/Application Support/RustDesk"
USER_CACHE="$CONSOLE_HOME/Library/Caches/com.carriez.RustDesk"
USER_STATE="$CONSOLE_HOME/Library/Saved Application State/com.carriez.RustDesk.savedState"

rm -rf "$USER_PREFS"
rm -rf "$USER_LOGS"
rm -rf "$USER_SUPPORT"
rm -rf "$USER_CACHE"
rm -rf "$USER_STATE"

log "[REMOVE] User preferences removed."
log "[REMOVE] User logs removed."
log "[REMOVE] User Application Support removed."
log "[REMOVE] User cache removed."
log "[REMOVE] Saved Application State removed."

# ============================================================
# Remove system leftovers
# ============================================================

separator
log "[REMOVE] Removing possible system RustDesk leftovers..."

rm -rf "/Library/Application Support/RustDesk"
rm -rf "/Library/Logs/RustDesk"
rm -rf "/Library/Preferences/com.carriez.RustDesk"

log "[REMOVE] System cleanup completed."

# ============================================================
# Mount DMG
# ============================================================

separator
log "[DMG] Mounting RustDesk DMG..."

hdiutil attach \
    "$DMG_FILE" \
    -mountpoint "$MOUNT_POINT" \
    -nobrowse \
    >/dev/null 2>&1

DMG_EXIT=$?

if [ "$DMG_EXIT" -ne 0 ]; then
    log "[ERROR] Failed to mount DMG. Exit code: $DMG_EXIT"
    exit 1
fi

log "[DMG] Mount successful."

if [ ! -d "$MOUNT_POINT/RustDesk.app" ]; then
    log "[ERROR] RustDesk.app not found inside DMG."

    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true

    exit 1
fi

log "[DMG] RustDesk.app found inside DMG."

# ============================================================
# Install application
# ============================================================

separator
log "[INSTALL] Installing RustDesk.app..."

ditto \
    "$MOUNT_POINT/RustDesk.app" \
    "$RUSTDESK_APP"

DITTO_EXIT=$?

if [ "$DITTO_EXIT" -ne 0 ]; then
    log "[ERROR] Failed to install RustDesk.app."
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    exit 1
fi

log "[INSTALL] RustDesk.app installed."

# ============================================================
# Unmount
# ============================================================

log "[DMG] Unmounting RustDesk DMG..."

hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true

log "[DMG] DMG unmounted."

# ============================================================
# Verify executable
# ============================================================

separator
log "[VERIFY] Checking RustDesk executable..."

if [ ! -x "$RUSTDESK" ]; then
    log "[ERROR] RustDesk executable does not exist."
    exit 1
fi

log "[VERIFY] RustDesk executable exists."

# ============================================================
# Ownership
# ============================================================

log "[OWNER] Setting RustDesk ownership to $CONSOLE_USER..."

chown -R "$CONSOLE_USER:staff" "$RUSTDESK_APP" >/dev/null 2>&1 || true

# ============================================================
# RustDesk ID
# ============================================================

separator
log "[ID] Getting RustDesk ID..."

ID_OUTPUT="$("$RUSTDESK" --get-id 2>&1)"
ID_EXIT=$?

log "[ID] Exit code: $ID_EXIT"
log "[ID] Result: $ID_OUTPUT"

# ============================================================
# Start temporary backend
# ============================================================

separator
log "[SERVER] Starting RustDesk server..."

"$RUSTDESK" --server >/tmp/rustdesk-server.out 2>/tmp/rustdesk-server.err &

SERVER_PID=$!

log "[SERVER] PID: $SERVER_PID"

sleep 2

# ============================================================
# Configure password
# ============================================================

separator
log "[PASSWORD] Applying RustDesk password..."

PASSWORD_OUTPUT="$("$RUSTDESK" --password "$RUSTDESK_PASSWORD" 2>&1)"
PASSWORD_EXIT=$?

log "[PASSWORD] Exit code: $PASSWORD_EXIT"

# Don't log the actual password/config.
if [ "$PASSWORD_EXIT" -eq 0 ]; then
    log "[PASSWORD] Password command returned success."
else
    log "[PASSWORD] Password command FAILED."
    log "[PASSWORD] Output: $PASSWORD_OUTPUT"
fi

# ============================================================
# Configure server
# ============================================================

separator
log "[CONFIG] Applying RustDesk configuration..."

CONFIG_OUTPUT="$("$RUSTDESK" --config "$RUSTDESK_CONFIG" 2>&1)"
CONFIG_EXIT=$?

log "[CONFIG] Exit code: $CONFIG_EXIT"

if [ "$CONFIG_EXIT" -eq 0 ]; then
    log "[CONFIG] Configuration command returned success."
else
    log "[CONFIG] Configuration command FAILED."
    log "[CONFIG] Output: $CONFIG_OUTPUT"
fi

# ============================================================
# Stop temporary server
# ============================================================

separator
log "[SERVER] Stopping temporary RustDesk server..."

kill "$SERVER_PID" >/dev/null 2>&1 || true

sleep 1

kill -9 "$SERVER_PID" >/dev/null 2>&1 || true

log "[SERVER] Temporary server stopped."

# ============================================================
# Verify config files
# ============================================================

separator
log "[VERIFY] Checking RustDesk configuration..."

if [ -d "$USER_PREFS" ]; then
    log "[VERIFY] RustDesk preferences directory exists."
else
    log "[VERIFY] WARNING: RustDesk preferences directory not found."
fi

if [ -f "$USER_PREFS/RustDesk.toml" ]; then
    log "[VERIFY] RustDesk.toml exists."
else
    log "[VERIFY] WARNING: RustDesk.toml not found."
fi

# ============================================================
# Restore ownership
# ============================================================

chown -R "$CONSOLE_USER:staff" \
    "$USER_PREFS" \
    "$USER_LOGS" \
    "$USER_SUPPORT" \
    "$USER_CACHE" \
    "$USER_STATE" \
    >/dev/null 2>&1 || true

# ============================================================
# Final ID
# ============================================================

separator
log "[ID] Getting final RustDesk ID..."

FINAL_ID="$("$RUSTDESK" --get-id 2>/dev/null)"
FINAL_ID_EXIT=$?

log "[ID] Exit code: $FINAL_ID_EXIT"
log "[ID] Final result: $FINAL_ID"

# ============================================================
# Result
# ============================================================

separator
log "RustDesk privileged installation completed"

log "Architecture : $ARCH"
log "RustDesk ID  : $FINAL_ID"
log "Password     : $([ "$PASSWORD_EXIT" -eq 0 ] && echo SUCCESS || echo FAILED)"
log "Config       : $([ "$CONFIG_EXIT" -eq 0 ] && echo SUCCESS || echo FAILED)"

separator

# ============================================================
# Launch GUI as console user
# ============================================================

log "[GUI] Starting RustDesk GUI as $CONSOLE_USER..."

launchctl asuser "$(id -u "$CONSOLE_USER")" \
    sudo -u "$CONSOLE_USER" \
    open -n "$RUSTDESK_APP" \
    >/dev/null 2>&1 || true

log "[GUI] GUI launch requested."

# ============================================================
# Return status
# ============================================================

if [ "$PASSWORD_EXIT" -ne 0 ]; then
    log "[ERROR] Password configuration failed."
    exit 1
fi

if [ "$CONFIG_EXIT" -ne 0 ]; then
    log "[ERROR] RustDesk configuration failed."
    exit 1
fi

exit 0
ROOT_SCRIPT

    chmod 700 "$TEMP_SCRIPT"

    # --------------------------------------------------------
    # Build command for osascript.
    #
    # IMPORTANT:
    # The temporary script receives sensitive data through the
    # environment, not through AppleScript shell quoting.
    # --------------------------------------------------------

    APPLESCRIPT_COMMAND="/bin/bash $TEMP_SCRIPT"

    PROMPT="Для установки и настройки RustDesk требуются права администратора."

    log "[ADMIN] Launching privileged installer through macOS authorization dialog..."

    /usr/bin/osascript \
        -e 'on run argv' \
        -e 'set cmd to item 1 of argv' \
        -e 'set promptText to item 2 of argv' \
        -e 'do shell script cmd with administrator privileges with prompt promptText' \
        -e 'end run' \
        -- "$APPLESCRIPT_COMMAND" "$PROMPT"

    OSASCRIPT_EXIT=$?

    rm -f "$TEMP_SCRIPT"

    if [ "$OSASCRIPT_EXIT" -ne 0 ]; then
        log "[ADMIN] Administrator authorization failed. Exit code: $OSASCRIPT_EXIT"
        exit "$OSASCRIPT_EXIT"
    fi

    log "[ADMIN] Privileged installer completed."

    exit 0
fi

# ============================================================
# This point should only be reached as root.
# ============================================================

log "[ERROR] Unexpected installer state."

exit 1
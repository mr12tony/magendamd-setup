#!/bin/bash

set -e

# ============================================================
# Arguments
# ============================================================

rustdesk_pw="$1"
rustdesk_cfg="$2"

if [ -z "$rustdesk_pw" ]; then
    echo "ERROR: Password is required"
    exit 1
fi

if [ -z "$rustdesk_cfg" ]; then
    echo "ERROR: Config is required"
    exit 1
fi

# ============================================================
# Paths
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK="$RUSTDESK_APP/Contents/MacOS/RustDesk"

MOUNT_POINT="/Volumes/RustDesk"

# ============================================================
# Root / administrator
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "Requesting administrator privileges..."

    SCRIPT="$SCRIPT_DIR/$(basename "$0")"

    # Передаём аргументы в повторный запуск.
    PASSWORD="$rustdesk_pw" CONFIG="$rustdesk_cfg" SCRIPT="$SCRIPT" \
    osascript <<'APPLESCRIPT'
set scriptPath to system attribute "SCRIPT"
set passwordValue to system attribute "PASSWORD"
set configValue to system attribute "CONFIG"

do shell script "/bin/bash " & quoted form of scriptPath & " " & quoted form of passwordValue & " " & quoted form of configValue with administrator privileges
APPLESCRIPT

    exit $?
fi

# ============================================================
# Detect architecture
# ============================================================

CPU="$(arch)"

if [ "$CPU" = "arm64" ]; then
    DMG="$SCRIPT_DIR/rustdesk-aarch64.dmg"
elif [ "$CPU" = "x86_64" ]; then
    DMG="$SCRIPT_DIR/rustdesk-x86_64.dmg"
else
    echo "ERROR: Unsupported macOS architecture: $CPU"
    exit 1
fi

echo "Architecture: $CPU"
echo "Installer: $DMG"

if [ ! -f "$DMG" ]; then
    echo "ERROR: DMG not found:"
    echo "$DMG"
    exit 1
fi

# ============================================================
# Stop existing RustDesk
# ============================================================

echo "Stopping existing RustDesk..."

killall RustDesk >/dev/null 2>&1 || true

sleep 1

# ============================================================
# Remove old application
# ============================================================

if [ -d "$RUSTDESK_APP" ]; then
    echo "Removing old RustDesk..."

    rm -rf "$RUSTDESK_APP"
fi

# ============================================================
# Mount DMG
# ============================================================

echo "Mounting DMG..."

hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true

hdiutil attach \
    "$DMG" \
    -mountpoint "$MOUNT_POINT" \
    -nobrowse \
    >/dev/null

# ============================================================
# Install application
# ============================================================

echo "Installing RustDesk..."

ditto \
    "$MOUNT_POINT/RustDesk.app" \
    "$RUSTDESK_APP"

# ============================================================
# Unmount
# ============================================================

echo "Unmounting DMG..."

hdiutil detach \
    "$MOUNT_POINT" \
    -force \
    >/dev/null 2>&1 || true

sleep 2

if [ ! -f "$RUSTDESK" ]; then
    echo "ERROR: RustDesk executable not found"
    exit 1
fi

# ============================================================
# Fix ownership
# ============================================================

# Так как установка выполняется от root,
# приложение не должно остаться root-owned для обычного GUI пользователя.

CONSOLE_USER="$(stat -f '%Su' /dev/console)"

if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    echo "Setting RustDesk ownership to $CONSOLE_USER..."

    chown -R "$CONSOLE_USER:staff" "$RUSTDESK_APP"
fi

# ============================================================
# Get RustDesk ID
# ============================================================

echo "Getting RustDesk ID..."

rustdesk_id="$("$RUSTDESK" --get-id 2>/dev/null || true)"

echo "RustDesk ID: $rustdesk_id"

# ============================================================
# Start RustDesk server
# ============================================================

echo "Starting RustDesk server..."

"$RUSTDESK" --server >/dev/null 2>&1 &

sleep 3

# ============================================================
# Password
# ============================================================

echo "Setting RustDesk password..."

"$RUSTDESK" --password "$rustdesk_pw"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to set RustDesk password"
    exit 1
fi

# ============================================================
# Config
# ============================================================

echo "Applying RustDesk config..."

"$RUSTDESK" --config "$rustdesk_cfg"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to apply RustDesk config"
    exit 1
fi

# ============================================================
# Stop configuration server
# ============================================================

echo "Stopping RustDesk server..."

pkill -f "$RUSTDESK" >/dev/null 2>&1 || true

sleep 2

# ============================================================
# Start GUI as real user
# ============================================================

echo "Starting RustDesk GUI..."

if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    sudo -u "$CONSOLE_USER" \
        -H \
        open -n "$RUSTDESK_APP"
else
    open -n "$RUSTDESK_APP"
fi

# ============================================================
# Result
# ============================================================

echo "=========================================="
echo "RustDesk installation completed"
echo "Architecture: $CPU"
echo "RustDesk ID: $rustdesk_id"
echo "Password: $rustdesk_pw"
echo "=========================================="

exit 0
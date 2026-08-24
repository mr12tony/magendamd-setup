#!/bin/bash

set -e

# ============================================================
# PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG_SOURCE="$SCRIPT_DIR/RustDesk2.toml"

RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK_BIN="$RUSTDESK_APP/Contents/MacOS/RustDesk"

RUSTDESK_CONFIG_DIR="$HOME/Library/Preferences/com.carriez.RustDesk"
RUSTDESK_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk2.toml"

BACKUP_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk2.toml.backup"


# ============================================================
# PASSWORD
# ============================================================

# Можно передать пароль первым аргументом:
#
# ./install-rustdesk.sh "MyPassword123"
#
# Если пароль не передан — генерируем случайный.

if [ -n "$1" ]; then
    PASSWORD="$1"
else
    PASSWORD="$(openssl rand -hex 8)"
fi


# ============================================================
# START
# ============================================================

echo ""
echo "============================================================"
echo "             RUSTDESK CONFIG + PASSWORD"
echo "============================================================"
echo ""

echo "Config source:"
echo "$CONFIG_SOURCE"

echo ""
echo "RustDesk config:"
echo "$RUSTDESK_CONFIG"

echo ""
echo "RustDesk binary:"
echo "$RUSTDESK_BIN"


# ============================================================
# CHECK CONFIG
# ============================================================

if [ ! -f "$CONFIG_SOURCE" ]; then

    echo ""
    echo "ERROR: RustDesk2.toml not found:"
    echo "$CONFIG_SOURCE"

    exit 1

fi


# ============================================================
# CHECK RUSTDESK
# ============================================================

if [ ! -d "$RUSTDESK_APP" ]; then

    echo ""
    echo "ERROR: RustDesk.app not found:"
    echo "$RUSTDESK_APP"

    exit 1

fi


if [ ! -x "$RUSTDESK_BIN" ]; then

    echo ""
    echo "ERROR: RustDesk executable not found:"
    echo "$RUSTDESK_BIN"

    exit 1

fi


# ============================================================
# STOP RUSTDESK
# ============================================================

echo ""
echo "[1/6] Closing RustDesk..."

osascript -e 'tell application "RustDesk" to quit' 2>/dev/null || true

sleep 2


# Force stop if still running

if pgrep -x "RustDesk" >/dev/null 2>&1; then

    echo "RustDesk process still running."
    echo "Stopping process..."

    pkill -x "RustDesk" 2>/dev/null || true

fi


# Wait for complete termination

for i in {1..10}; do

    if ! pgrep -x "RustDesk" >/dev/null 2>&1; then
        break
    fi

    sleep 1

done


if pgrep -x "RustDesk" >/dev/null 2>&1; then

    echo ""
    echo "ERROR: RustDesk process is still running."

    exit 1

fi


echo "RustDesk stopped."


# ============================================================
# CONFIG DIRECTORY
# ============================================================

echo ""
echo "[2/6] Preparing configuration directory..."

mkdir -p "$RUSTDESK_CONFIG_DIR"


# ============================================================
# BACKUP
# ============================================================

echo ""
echo "[3/6] Backing up existing configuration..."

if [ -f "$RUSTDESK_CONFIG" ]; then

    cp -f "$RUSTDESK_CONFIG" "$BACKUP_CONFIG"

    chmod 600 "$BACKUP_CONFIG"

    echo "Backup created:"
    echo "$BACKUP_CONFIG"

else

    echo "Existing RustDesk2.toml not found."
    echo "No backup required."

fi


# ============================================================
# INSTALL CONFIG
# ============================================================

echo ""
echo "[4/6] Installing new RustDesk2.toml..."

cp -f "$CONFIG_SOURCE" "$RUSTDESK_CONFIG"

chmod 600 "$RUSTDESK_CONFIG"

echo "Configuration installed."


# ============================================================
# VERIFY CONFIG
# ============================================================

echo ""
echo "===== INSTALLED CONFIG ====="
echo ""

cat "$RUSTDESK_CONFIG"

echo ""
echo "============================"


# ============================================================
# APPLY PASSWORD
# ============================================================

echo ""
echo "[5/6] Applying RustDesk password..."

echo "Setting permanent password..."

"$RUSTDESK_BIN" --password "$PASSWORD" >/dev/null 2>&1 || {

    echo ""
    echo "ERROR: Failed to set RustDesk password."

    exit 1

}

echo "Password applied successfully."


# ============================================================
# START RUSTDESK
# ============================================================

echo ""
echo "[6/6] Starting RustDesk..."

open -a "$RUSTDESK_APP"

sleep 4


# ============================================================
# VERIFY PROCESS
# ============================================================

if pgrep -x "RustDesk" >/dev/null 2>&1; then

    echo "RustDesk is running."

else

    echo ""
    echo "WARNING: RustDesk process was not detected."

fi


# ============================================================
# RESULT
# ============================================================

echo ""
echo "============================================================"
echo "                       DONE"
echo "============================================================"
echo ""

echo "RustDesk:"
echo "$RUSTDESK_APP"

echo ""
echo "Config:"
echo "$RUSTDESK_CONFIG"

echo ""
echo "Backup:"
echo "$BACKUP_CONFIG"

echo ""
echo "Password:"
echo "$PASSWORD"

echo ""
echo "============================================================"
echo ""
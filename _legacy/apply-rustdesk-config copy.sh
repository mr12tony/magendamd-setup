#!/bin/bash

set -e

# ============================================================
# PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG_SOURCE="$SCRIPT_DIR/RustDesk2.toml"

RUSTDESK_APP="/Applications/RustDesk.app"

RUSTDESK_CONFIG_DIR="$HOME/Library/Preferences/com.carriez.RustDesk"
RUSTDESK_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk2.toml"

BACKUP_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk2.toml.backup"


# ============================================================
# CHECK CONFIG
# ============================================================

echo ""
echo "===== RUSTDESK CONFIG UPDATE ====="
echo ""

if [ ! -f "$CONFIG_SOURCE" ]; then
    echo "ERROR: RustDesk2.toml not found:"
    echo "$CONFIG_SOURCE"
    exit 1
fi

echo "Source config:"
echo "$CONFIG_SOURCE"

echo ""
echo "Target config:"
echo "$RUSTDESK_CONFIG"


# ============================================================
# CHECK RUSTDESK
# ============================================================

if [ ! -d "$RUSTDESK_APP" ]; then
    echo ""
    echo "ERROR: RustDesk.app not found:"
    echo "$RUSTDESK_APP"
    exit 1
fi


# ============================================================
# STOP RUSTDESK
# ============================================================

echo ""
echo "[1/5] Closing RustDesk..."

osascript -e 'tell application "RustDesk" to quit' 2>/dev/null || true

sleep 2


# Если процесс всё ещё работает
if pgrep -x "RustDesk" >/dev/null 2>&1; then
    echo "RustDesk process still running. Stopping it..."
    pkill -x "RustDesk" 2>/dev/null || true
fi


# Ждём полного завершения
for i in {1..10}; do

    if ! pgrep -x "RustDesk" >/dev/null 2>&1; then
        break
    fi

    sleep 1
done


if pgrep -x "RustDesk" >/dev/null 2>&1; then
    echo "ERROR: RustDesk process is still running."
    exit 1
fi

echo "RustDesk stopped."


# ============================================================
# CONFIG DIRECTORY
# ============================================================

echo ""
echo "[2/5] Checking config directory..."

mkdir -p "$RUSTDESK_CONFIG_DIR"


# ============================================================
# BACKUP
# ============================================================

echo ""
echo "[3/5] Backing up existing configuration..."

if [ -f "$RUSTDESK_CONFIG" ]; then

    cp -f "$RUSTDESK_CONFIG" "$BACKUP_CONFIG"

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
echo "[4/5] Installing new RustDesk2.toml..."

cp -f "$CONFIG_SOURCE" "$RUSTDESK_CONFIG"

chmod 600 "$RUSTDESK_CONFIG"

echo "Configuration installed."


# ============================================================
# VERIFY
# ============================================================

echo ""
echo "===== INSTALLED CONFIG ====="
echo ""

cat "$RUSTDESK_CONFIG"

echo ""
echo "============================"


# ============================================================
# START RUSTDESK
# ============================================================

echo ""
echo "[5/5] Starting RustDesk..."

open -a "$RUSTDESK_APP"

sleep 3


# ============================================================
# RESULT
# ============================================================

echo ""
echo "===== DONE ====="
echo ""
echo "RustDesk started."
echo ""
echo "Config:"
echo "$RUSTDESK_CONFIG"
echo ""
echo "Backup:"
echo "$BACKUP_CONFIG"
echo ""
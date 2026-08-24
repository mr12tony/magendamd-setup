#!/bin/bash

set -e

# ============================================================
# RUSTDESK macOS CONFIG + PASSWORD
# ============================================================

# ------------------------------------------------------------
# REAL USER
# ------------------------------------------------------------

if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="$USER"
fi

REAL_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"

if [ -z "$REAL_HOME" ]; then
    REAL_HOME="$HOME"
fi


# ------------------------------------------------------------
# PATHS
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG_SOURCE="$SCRIPT_DIR/RustDesk2.toml"

RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK_BIN="$RUSTDESK_APP/Contents/MacOS/RustDesk"

RUSTDESK_CONFIG_DIR="$REAL_HOME/Library/Preferences/com.carriez.RustDesk"

RUSTDESK_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk2.toml"
RUSTDESK_MAIN_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk.toml"

BACKUP_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk2.toml.backup"
BACKUP_MAIN_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk.toml.backup"


# ============================================================
# PASSWORD
# ============================================================

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
echo "          RUSTDESK macOS CONFIG + PASSWORD"
echo "============================================================"
echo ""

echo "User:"
echo "  $REAL_USER"

echo ""
echo "Home:"
echo "  $REAL_HOME"

echo ""
echo "Config source:"
echo "  $CONFIG_SOURCE"

echo ""
echo "RustDesk config:"
echo "  $RUSTDESK_CONFIG"

echo ""
echo "RustDesk main config:"
echo "  $RUSTDESK_MAIN_CONFIG"

echo ""


# ============================================================
# CHECK ROOT / SUDO
# ============================================================

if [ "$EUID" -ne 0 ]; then

    echo "[0/6] Requesting administrator privileges..."

    exec sudo "$0" "$@"

fi

echo "[0/6] Administrator privileges: OK"


# ============================================================
# CHECK FILES
# ============================================================

if [ ! -f "$CONFIG_SOURCE" ]; then

    echo ""
    echo "ERROR: RustDesk2.toml not found:"
    echo "$CONFIG_SOURCE"

    exit 1

fi


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
# 1. STOP RUSTDESK
# ============================================================

echo ""
echo "[1/6] Stopping RustDesk..."

# Закрываем GUI от имени реального пользователя
sudo -u "$REAL_USER" \
    osascript -e 'tell application "RustDesk" to quit' \
    2>/dev/null || true

sleep 2


# Если процесс остался
if pgrep -x "RustDesk" >/dev/null 2>&1; then

    echo "RustDesk still running. Force stopping..."

    pkill -x "RustDesk" 2>/dev/null || true

fi


# Ждём полного завершения

for i in {1..15}; do

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
# 2. CONFIG DIRECTORY
# ============================================================

echo ""
echo "[2/6] Preparing configuration directory..."

mkdir -p "$RUSTDESK_CONFIG_DIR"

chown "$REAL_USER" "$RUSTDESK_CONFIG_DIR"

chmod 700 "$RUSTDESK_CONFIG_DIR"


# ============================================================
# 3. BACKUP + INSTALL CONFIG
# ============================================================

echo ""
echo "[3/6] Installing RustDesk2.toml..."


# Backup RustDesk2.toml

if [ -f "$RUSTDESK_CONFIG" ]; then

    cp -f \
        "$RUSTDESK_CONFIG" \
        "$BACKUP_CONFIG"

    chown "$REAL_USER" "$BACKUP_CONFIG"
    chmod 600 "$BACKUP_CONFIG"

    echo "RustDesk2.toml backup:"
    echo "  $BACKUP_CONFIG"

fi


# Copy new RustDesk2.toml

cp -f \
    "$CONFIG_SOURCE" \
    "$RUSTDESK_CONFIG"

chown "$REAL_USER" "$RUSTDESK_CONFIG"
chmod 600 "$RUSTDESK_CONFIG"


echo ""
echo "RustDesk2.toml installed:"
echo "  $RUSTDESK_CONFIG"


# ============================================================
# SHOW CONFIG
# ============================================================

echo ""
echo "===== RUSTDESK2.TOML ====="
echo ""

cat "$RUSTDESK_CONFIG"

echo ""
echo "==========================="


# ============================================================
# 4. START RUSTDESK
# ============================================================

echo ""
echo "[4/6] Starting RustDesk..."

sudo -u "$REAL_USER" \
    open -a "$RUSTDESK_APP"


echo "Waiting for RustDesk process..."


RUSTDESK_RUNNING=false

for i in {1..20}; do

    if pgrep -x "RustDesk" >/dev/null 2>&1; then

        RUSTDESK_RUNNING=true

        break

    fi

    sleep 1

done


if [ "$RUSTDESK_RUNNING" != "true" ]; then

    echo ""
    echo "ERROR: RustDesk did not start."

    exit 1

fi


echo "RustDesk is running."


# ============================================================
# 5. APPLY PASSWORD
# ============================================================

echo ""
echo "[5/6] Applying RustDesk password..."

echo "Setting permanent password..."

"$RUSTDESK_BIN" --password "$PASSWORD"

PASSWORD_EXIT_CODE=$?


echo ""
echo "RustDesk --password exit code: $PASSWORD_EXIT_CODE"


if [ "$PASSWORD_EXIT_CODE" -ne 0 ]; then

    echo ""
    echo "ERROR: Failed to set RustDesk password."

    exit "$PASSWORD_EXIT_CODE"

fi


echo "Password applied successfully."


# ============================================================
# 6. VERIFY RustDesk.toml
# ============================================================

echo ""
echo "[6/6] Verifying RustDesk.toml..."

if [ ! -f "$RUSTDESK_MAIN_CONFIG" ]; then

    echo ""
    echo "ERROR: RustDesk.toml was not created."

    exit 1

fi


# Проверяем наличие password и salt

HAS_PASSWORD=false
HAS_SALT=false


if grep -q "^password = " "$RUSTDESK_MAIN_CONFIG"; then
    HAS_PASSWORD=true
fi


if grep -q "^salt = " "$RUSTDESK_MAIN_CONFIG"; then
    HAS_SALT=true
fi


echo ""
echo "RustDesk.toml:"
echo "  $RUSTDESK_MAIN_CONFIG"

echo ""
echo "Password field: $HAS_PASSWORD"
echo "Salt field:     $HAS_SALT"


if [ "$HAS_PASSWORD" != "true" ]; then

    echo ""
    echo "ERROR: Password was not found in RustDesk.toml."

    exit 1

fi


if [ "$HAS_SALT" != "true" ]; then

    echo ""
    echo "ERROR: Salt was not found in RustDesk.toml."

    exit 1

fi


echo ""
echo "Password configuration verified."


# ============================================================
# FINAL
# ============================================================

echo ""
echo "============================================================"
echo "                         DONE"
echo "============================================================"
echo ""

echo "RustDesk:"
echo "  $RUSTDESK_APP"

echo ""
echo "User:"
echo "  $REAL_USER"

echo ""
echo "RustDesk2.toml:"
echo "  $RUSTDESK_CONFIG"

echo ""
echo "RustDesk.toml:"
echo "  $RUSTDESK_MAIN_CONFIG"

echo ""
echo "Password:"
echo "  $PASSWORD"

echo ""
echo "GUI:"
echo "  RUNNING"

echo ""
echo "============================================================"
echo ""
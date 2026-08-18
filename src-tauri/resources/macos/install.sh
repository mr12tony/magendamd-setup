#!/bin/bash

set -e

# ============================================================
# REAL CONSOLE USER
# ============================================================

REAL_USER="$(stat -f '%Su' /dev/console)"

REAL_HOME="$(
    dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null |
    awk '{print $2}'
)"

if [ -z "$REAL_HOME" ]; then
    echo "ERROR: Cannot determine user home."
    exit 1
fi


# ============================================================
# PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG_SOURCE="$SCRIPT_DIR/RustDesk2.toml"

RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK_BIN="$RUSTDESK_APP/Contents/MacOS/RustDesk"

RUSTDESK_CONFIG_DIR="$REAL_HOME/Library/Preferences/com.carriez.RustDesk"

RUSTDESK_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk2.toml"
RUSTDESK_MAIN_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk.toml"

BACKUP_CONFIG="$RUSTDESK_CONFIG_DIR/RustDesk2.toml.backup"


# ============================================================
# PASSWORD
# ============================================================

if [ -n "$1" ]; then
    PASSWORD="$1"
    PASSWORD_GENERATED=false
else
    PASSWORD="$(openssl rand -hex 8)"
    PASSWORD_GENERATED=true
fi


# ============================================================
# ADMIN ELEVATION
# ============================================================

if [ "$EUID" -ne 0 ]; then

    echo "[0/8] Requesting administrator privileges..."

    SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"

    if [ -n "$1" ]; then

        # Передаём пароль как аргумент
        /usr/bin/osascript \
            -e 'do shell script "'"$SCRIPT_PATH"' " & quoted form of "'"$PASSWORD"'" with administrator privileges'

    else

        /usr/bin/osascript \
            -e 'do shell script "'"$SCRIPT_PATH"'" with administrator privileges'

    fi

    exit $?

fi

echo "[0/8] Administrator privileges: OK"


# ============================================================
# FIND LOCAL DMG BY ARCHITECTURE
# ============================================================

echo ""
echo "Detecting Mac architecture..."

ARCH="$(uname -m)"

case "$ARCH" in

    arm64)
        DMG_PATTERN="*aarch64*.dmg"
        echo "Architecture: Apple Silicon (arm64)"
        ;;

    x86_64)
        DMG_PATTERN="*x86_64*.dmg"
        echo "Architecture: Intel (x86_64)"
        ;;

    *)
        echo ""
        echo "ERROR: Unsupported architecture:"
        echo "$ARCH"
        exit 1
        ;;

esac


DMG_FILE=""

for file in "$SCRIPT_DIR"/$DMG_PATTERN; do

    if [ -f "$file" ]; then
        DMG_FILE="$file"
        break
    fi

done


if [ -z "$DMG_FILE" ]; then

    echo ""
    echo "ERROR: RustDesk DMG for architecture '$ARCH' not found."
    echo ""
    echo "Expected pattern:"
    echo "  $SCRIPT_DIR/$DMG_PATTERN"
    echo ""

    echo "Available DMG files:"

    ls -1 "$SCRIPT_DIR"/*.dmg 2>/dev/null || \
        echo "  No DMG files found."

    exit 1

fi


echo ""
echo "RustDesk DMG:"
echo "  $DMG_FILE"


# ============================================================
# CHECK CONFIG
# ============================================================

if [ ! -f "$CONFIG_SOURCE" ]; then

    echo ""
    echo "ERROR: RustDesk2.toml not found:"
    echo "$CONFIG_SOURCE"
    echo ""

    exit 1

fi


# ============================================================
# 1. INSTALL RUSTDESK FROM LOCAL DMG
# ============================================================

echo ""
echo "============================================================"
echo "[1/8] INSTALLING RUSTDESK"
echo "============================================================"
echo ""

MOUNT_POINT="/Volumes/RustDesk"

# Если старый mount существует — сначала отключаем

if mount | grep -q "on $MOUNT_POINT "; then

    echo "Existing RustDesk DMG mount detected."
    echo "Unmounting..."

    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true

    sleep 2

fi


echo "Mounting:"
echo "  $DMG_FILE"

hdiutil attach \
    "$DMG_FILE" \
    -mountpoint "$MOUNT_POINT" \
    -nobrowse \
    >/dev/null


if [ ! -d "$MOUNT_POINT/RustDesk.app" ]; then

    echo ""
    echo "ERROR: RustDesk.app not found inside DMG."

    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true

    exit 1

fi


echo "RustDesk.app found."

echo ""
echo "Installing RustDesk.app to /Applications..."

# Удаляем старую копию только после успешного mount

if [ -d "$RUSTDESK_APP" ]; then

    echo "Removing existing RustDesk.app..."

    rm -rf "$RUSTDESK_APP"

fi


cp -R \
    "$MOUNT_POINT/RustDesk.app" \
    "/Applications/"


echo "RustDesk.app installed."


# Отмонтируем DMG

echo ""
echo "Unmounting DMG..."

hdiutil detach \
    "$MOUNT_POINT" \
    >/dev/null


echo "DMG unmounted."


# ============================================================
# CHECK INSTALLED RUSTDESK
# ============================================================

if [ ! -d "$RUSTDESK_APP" ]; then

    echo ""
    echo "ERROR: RustDesk.app installation failed."

    exit 1

fi


if [ ! -x "$RUSTDESK_BIN" ]; then

    echo ""
    echo "ERROR: RustDesk executable not found:"
    echo "$RUSTDESK_BIN"

    exit 1

fi


echo ""
echo "RustDesk installation verified."


# ============================================================
# 2. STOP RUSTDESK
# ============================================================

echo ""
echo "============================================================"
echo "[2/8] STOPPING RUSTDESK"
echo "============================================================"
echo ""

# Закрываем GUI именно от имени пользователя

sudo -u "$REAL_USER" \
    osascript -e 'tell application "RustDesk" to quit' \
    2>/dev/null || true

sleep 2


# Если процесс остался

if pgrep -x "RustDesk" >/dev/null 2>&1; then

    echo "RustDesk still running."
    echo "Force stopping..."

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
# 3. CONFIG DIRECTORY
# ============================================================

echo ""
echo "============================================================"
echo "[3/8] PREPARING CONFIGURATION"
echo "============================================================"
echo ""

mkdir -p "$RUSTDESK_CONFIG_DIR"

chown "$REAL_USER" "$RUSTDESK_CONFIG_DIR"
chmod 700 "$RUSTDESK_CONFIG_DIR"


# ============================================================
# 4. BACKUP + INSTALL RustDesk2.toml
# ============================================================

echo ""
echo "============================================================"
echo "[4/8] INSTALLING RustDesk2.toml"
echo "============================================================"
echo ""


# ------------------------------------------------------------
# BACKUP
# ------------------------------------------------------------

if [ -f "$RUSTDESK_CONFIG" ]; then

    cp -f \
        "$RUSTDESK_CONFIG" \
        "$BACKUP_CONFIG"

    chown "$REAL_USER" "$BACKUP_CONFIG"
    chmod 600 "$BACKUP_CONFIG"

    echo "Backup created:"
    echo "  $BACKUP_CONFIG"

else

    echo "Existing RustDesk2.toml not found."
    echo "No backup required."

fi


# ------------------------------------------------------------
# COPY CONFIG
# ------------------------------------------------------------

cp -f \
    "$CONFIG_SOURCE" \
    "$RUSTDESK_CONFIG"

chown "$REAL_USER" "$RUSTDESK_CONFIG"
chmod 600 "$RUSTDESK_CONFIG"


echo ""
echo "RustDesk2.toml installed:"
echo "  $RUSTDESK_CONFIG"


# ------------------------------------------------------------
# VERIFY
# ------------------------------------------------------------

if [ ! -f "$RUSTDESK_CONFIG" ]; then

    echo ""
    echo "ERROR: RustDesk2.toml was not installed."

    exit 1

fi


echo ""
echo "===== INSTALLED RustDesk2.toml ====="
echo ""

cat "$RUSTDESK_CONFIG"

echo ""
echo "===================================="


# ============================================================
# 5. START RUSTDESK GUI
# ============================================================

echo ""
echo "============================================================"
echo "[5/8] STARTING RUSTDESK"
echo "============================================================"
echo ""

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

echo ""
echo "Waiting 5 seconds for RustDesk initialization..."

sleep 5


# ============================================================
# 6. APPLY PASSWORD
# ============================================================

echo ""
echo "============================================================"
echo "[6/8] APPLYING RUSTDESK PASSWORD"
echo "============================================================"
echo ""

echo "Password:"
echo "  $PASSWORD"

if [ "$PASSWORD_GENERATED" = "true" ]; then
    echo "  (randomly generated)"
else
    echo "  (provided by user)"
fi


echo ""
echo "Executing:"
echo "  RustDesk --password ********"
echo ""


"$RUSTDESK_BIN" \
    --password "$PASSWORD"

PASSWORD_EXIT_CODE=$?


echo ""
echo "RustDesk --password exit code:"
echo "  $PASSWORD_EXIT_CODE"


if [ "$PASSWORD_EXIT_CODE" -ne 0 ]; then

    echo ""
    echo "ERROR: Failed to set RustDesk password."

    exit "$PASSWORD_EXIT_CODE"

fi


echo ""
echo "Password applied successfully."


# ============================================================
# 7. VERIFY RustDesk.toml
# ============================================================

echo ""
echo "============================================================"
echo "[7/8] VERIFYING RustDesk.toml"
echo "============================================================"
echo ""


if [ ! -f "$RUSTDESK_MAIN_CONFIG" ]; then

    echo ""
    echo "ERROR: RustDesk.toml was not created:"
    echo "$RUSTDESK_MAIN_CONFIG"

    exit 1

fi


# ------------------------------------------------------------
# CHECK PASSWORD
# ------------------------------------------------------------

HAS_PASSWORD=false
HAS_SALT=false


if grep -q "^password = " "$RUSTDESK_MAIN_CONFIG"; then
    HAS_PASSWORD=true
fi


if grep -q "^salt = " "$RUSTDESK_MAIN_CONFIG"; then
    HAS_SALT=true
fi


echo "RustDesk.toml:"
echo "  $RUSTDESK_MAIN_CONFIG"

echo ""
echo "Password field:"
echo "  $HAS_PASSWORD"

echo "Salt field:"
echo "  $HAS_SALT"


if [ "$HAS_PASSWORD" != "true" ]; then

    echo ""
    echo "ERROR: password field not found in RustDesk.toml."

    exit 1

fi


if [ "$HAS_SALT" != "true" ]; then

    echo ""
    echo "ERROR: salt field not found in RustDesk.toml."

    exit 1

fi


echo ""
echo "Password configuration verified."


# ============================================================
# GET RUSTDESK ID
# ============================================================

echo ""
echo "Getting RustDesk ID..."

RUSTDESK_ID=""

RUSTDESK_ID="$(
    sudo -u "$REAL_USER" \
    "$RUSTDESK_BIN" --get-id \
    2>/dev/null || true
)"


# ============================================================
# 8. FINAL
# ============================================================

echo ""
echo "============================================================"
echo "                         DONE"
echo "============================================================"
echo ""

echo "RustDesk:"
echo "  $RUSTDESK_APP"

echo ""
echo "RustDesk ID:"

if [ -n "$RUSTDESK_ID" ]; then
    echo "  $RUSTDESK_ID"
else
    echo "  Failed to get RustDesk ID."
fi

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
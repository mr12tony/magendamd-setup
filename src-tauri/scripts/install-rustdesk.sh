#!/bin/bash

set -u

# ==========================================================
# RustDesk macOS installer
#
# Run:
#   sudo ./install-rustdesk.sh
#
# Tested concept:
#   RustDesk 1.4.9
# ==========================================================

set -e

# ==========================================================
# PATHS
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bundledRustDeskDmg="$SCRIPT_DIR/../resources/macos/rustdesk-aarch64.dmg"

APP="/Applications/RustDesk.app"
RUSTDESK="$APP/Contents/MacOS/RustDesk"

MOUNT_POINT="/Volumes/RustDeskInstaller"

# ==========================================================
# RUSTDESK CONFIG
# ==========================================================

RENDEZVOUS_SERVER="rustdesk.magendamd.com"
RELAY_SERVER="rustdesk.magendamd.com"

RUSTDESK_KEY="+Li02oekgNMPX9Aa6jPAJhJCE7Cuu6kmP1zB6nMpKMc="

PASSWORD="1FooBarBaz1"

# ==========================================================
# LOGGED-IN USER
# ==========================================================

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root:"
    echo "sudo $0"
    exit 1
fi

CONSOLE_USER="$(stat -f '%Su' /dev/console)"

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    echo "ERROR: no logged-in GUI user found."
    exit 1
fi

USER_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory |
    awk '{print $2}')"

if [ -z "$USER_HOME" ]; then
    echo "ERROR: cannot determine user home."
    exit 1
fi

USER_CONFIG_DIR="$USER_HOME/Library/Preferences/com.carriez.RustDesk"

USER_RUSTDESK2="$USER_CONFIG_DIR/RustDesk2.toml"

SERVER_LOG="/tmp/rustdesk-server.log"

# ==========================================================
# HEADER
# ==========================================================

echo "========================================"
echo "RustDesk installer"
echo "========================================"
echo "Logged-in user : $CONSOLE_USER"
echo "User home      : $USER_HOME"
echo "DMG            : $bundledRustDeskDmg"
echo ""

# ==========================================================
# VALIDATE DMG
# ==========================================================

if [ ! -f "$bundledRustDeskDmg" ]; then
    echo "ERROR: RustDesk DMG not found:"
    echo "$bundledRustDeskDmg"
    exit 1
fi

# ==========================================================
# STOP RUSTDESK
# ==========================================================

echo "Stopping RustDesk..."

pkill -9 -x RustDesk 2>/dev/null || true
pkill -9 -f "/RustDesk.app/" 2>/dev/null || true

# ==========================================================
# STOP SERVICE
# ==========================================================

echo "Stopping RustDesk services..."

launchctl bootout system/com.carriez.RustDesk_service \
    2>/dev/null || true

launchctl bootout "gui/$(id -u "$CONSOLE_USER")/com.carriez.RustDesk.autostart" \
    2>/dev/null || true

# ==========================================================
# REMOVE SERVICE FILES
# ==========================================================

echo "Removing old service files..."

rm -f \
    "/Library/LaunchDaemons/com.carriez.RustDesk_service.plist" \
    "/Library/LaunchAgents/com.carriez.RustDesk_service.plist" \
    "$USER_HOME/Library/LaunchAgents/com.carriez.RustDesk.autostart.plist"

# ==========================================================
# REMOVE OLD APP
# ==========================================================

echo "Removing old RustDesk.app..."

if [ -d "$APP" ]; then
    rm -rf "$APP"
fi

# ==========================================================
# REMOVE OLD CONFIG
# ==========================================================

echo "Removing old RustDesk configuration..."

rm -rf "$USER_CONFIG_DIR"

rm -rf \
    "$USER_HOME/Library/Logs/RustDesk" \
    "$USER_HOME/Library/Application Support/RustDesk" \
    "$USER_HOME/Library/Caches/com.carriez.RustDesk"

rm -rf \
    "/Library/Application Support/RustDesk" \
    "/var/root/Library/Preferences/com.carriez.RustDesk" \
    "/var/root/Library/Logs/RustDesk"

# ==========================================================
# UNMOUNT DMG
# ==========================================================

echo "Unmounting old RustDesk DMGs..."

for volume in /Volumes/*; do
    if [ -d "$volume" ]; then
        case "$volume" in
            *rustdesk*|*RustDesk*)
                echo "Unmounting: $volume"
                hdiutil detach "$volume" -force \
                    >/dev/null 2>&1 || true
                ;;
        esac
    fi
done

hdiutil detach "$MOUNT_POINT" -force \
    >/dev/null 2>&1 || true

rm -rf "$MOUNT_POINT"

# ==========================================================
# MOUNT DMG
# ==========================================================

echo "Mounting RustDesk DMG..."

mkdir -p "$MOUNT_POINT"

hdiutil attach \
    "$bundledRustDeskDmg" \
    -mountpoint "$MOUNT_POINT" \
    -nobrowse \
    -quiet

# ==========================================================
# FIND APP
# ==========================================================

SOURCE_APP="$MOUNT_POINT/RustDesk.app"

if [ ! -d "$SOURCE_APP" ]; then

    SOURCE_APP="$(find "$MOUNT_POINT" \
        -maxdepth 2 \
        -type d \
        -name "RustDesk.app" \
        -print -quit)"

fi

if [ -z "$SOURCE_APP" ] || [ ! -d "$SOURCE_APP" ]; then

    echo "ERROR: RustDesk.app not found in DMG."

    hdiutil detach "$MOUNT_POINT" -force \
        >/dev/null 2>&1 || true

    exit 1
fi

# ==========================================================
# COPY APP
# ==========================================================

echo "Copying RustDesk.app..."

cp -R "$SOURCE_APP" "$APP"

# ==========================================================
# UNMOUNT
# ==========================================================

echo "Unmounting DMG..."

hdiutil detach "$MOUNT_POINT" -quiet \
    >/dev/null 2>&1 || true

# ==========================================================
# WAIT FOR EXECUTABLE
# ==========================================================

echo "Waiting for RustDesk executable..."

DEADLINE=$((SECONDS + 60))

while [ ! -x "$RUSTDESK" ]; do

    if [ "$SECONDS" -ge "$DEADLINE" ]; then
        echo "ERROR: RustDesk executable not found."
        exit 1
    fi

    sleep 0.5
done

echo "RustDesk executable found."

# ==========================================================
# FIX APP OWNERSHIP
# ==========================================================

chown -R root:wheel "$APP"

# ==========================================================
# CREATE USER CONFIG DIR
# ==========================================================

echo "Preparing user configuration..."

mkdir -p "$USER_CONFIG_DIR"

chown "$CONSOLE_USER":staff "$USER_CONFIG_DIR"

chmod 700 "$USER_CONFIG_DIR"

# ==========================================================
# START RUSTDESK AS LOGGED-IN USER
# ==========================================================

echo "Starting RustDesk GUI..."

sudo -u "$CONSOLE_USER" \
    "$RUSTDESK" \
    >/tmp/rustdesk-user.log 2>&1 &

RUSTDESK_USER_PID=$!

echo "RustDesk PID: $RUSTDESK_USER_PID"

# ==========================================================
# WAIT FOR USER CONFIG
# ==========================================================

echo "Waiting for RustDesk user configuration..."

DEADLINE=$((SECONDS + 30))

while [ ! -f "$USER_RUSTDESK2" ]; do

    if [ "$SECONDS" -ge "$DEADLINE" ]; then

        echo "ERROR: RustDesk2.toml was not created."

        echo ""
        echo "RustDesk log:"
        cat /tmp/rustdesk-user.log 2>/dev/null || true

        exit 1
    fi

    sleep 0.5
done

echo "User configuration created."

# ==========================================================
# PASSWORD
# ==========================================================

echo "Applying RustDesk password..."

"$RUSTDESK" --password "$PASSWORD"

echo "Password applied."

# ==========================================================
# NETWORK CONFIGURATION
# ==========================================================

echo "Applying network configuration..."

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

echo "Fixing configuration ownership..."

chown "$CONSOLE_USER":staff \
    "$USER_RUSTDESK2"

chmod 600 \
    "$USER_RUSTDESK2"

# RustDesk.toml is generated/updated by the process.
# Ensure user owns the configuration files.
if [ -d "$USER_CONFIG_DIR" ]; then

    chown "$CONSOLE_USER":staff \
        "$USER_CONFIG_DIR"

    for file in "$USER_CONFIG_DIR"/*.toml; do
        [ -f "$file" ] || continue

        chown "$CONSOLE_USER":staff "$file"
        chmod 600 "$file"
    done

fi

# ==========================================================
# VERIFY NETWORK CONFIG
# ==========================================================

echo ""
echo "Checking RustDesk2.toml..."

if ! grep -q \
    "custom-rendezvous-server = '$RENDEZVOUS_SERVER'" \
    "$USER_RUSTDESK2"; then

    echo "ERROR: custom rendezvous server was not configured."
    exit 1
fi

if ! grep -q \
    "relay-server = '$RELAY_SERVER'" \
    "$USER_RUSTDESK2"; then

    echo "ERROR: relay server was not configured."
    exit 1
fi

if ! grep -q \
    "key = '$RUSTDESK_KEY'" \
    "$USER_RUSTDESK2"; then

    echo "ERROR: RustDesk key was not configured."
    exit 1
fi

echo "Network configuration verified."

# ==========================================================
# RESTART RUSTDESK
# ==========================================================

echo ""
echo "Restarting RustDesk..."

kill "$RUSTDESK_USER_PID" 2>/dev/null || true

sleep 2

pkill -9 -x RustDesk 2>/dev/null || true

sleep 1

sudo -u "$CONSOLE_USER" \
    "$RUSTDESK" \
    >/tmp/rustdesk-user.log 2>&1 &

sleep 3

# ==========================================================
# GET ID
# ==========================================================

echo ""
echo "Getting RustDesk ID..."

ID=""

for i in $(seq 1 30); do

    ID=$(
        sudo -u "$CONSOLE_USER" \
        "$RUSTDESK" --get-id 2>/dev/null |
        tr -d '\r\n '
    )

    if [ -n "$ID" ]; then
        break
    fi

    sleep 1
done

if [ -z "$ID" ]; then

    echo "ERROR: RustDesk ID is empty."

    echo ""
    echo "RustDesk user log:"
    cat /tmp/rustdesk-user.log 2>/dev/null || true

    exit 1
fi

# ==========================================================
# FINAL OWNERSHIP
# ==========================================================

chown "$CONSOLE_USER":staff \
    "$USER_CONFIG_DIR"

for file in "$USER_CONFIG_DIR"/*.toml; do
    [ -f "$file" ] || continue

    chown "$CONSOLE_USER":staff "$file"
    chmod 600 "$file"
done

# ==========================================================
# FINAL VERIFICATION
# ==========================================================

echo ""
echo "Final configuration ownership:"

ls -la "$USER_CONFIG_DIR"

echo ""
echo "Network configuration:"

grep -E \
    "rendezvous_server|relay-server|custom-rendezvous-server|^key" \
    "$USER_RUSTDESK2" || true

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
echo "User log:"
echo "  /tmp/rustdesk-user.log"
echo ""
echo "========================================"
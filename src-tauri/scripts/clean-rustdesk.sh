#!/bin/bash

set -u

echo "========================================"
echo "RustDesk FULL TEST CLEANUP"
echo "========================================"

# ==========================================
# REQUIRE ROOT
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo "Run as root:"
    echo "sudo $0"
    exit 1
fi

# ==========================================
# LOGGED-IN USER
# ==========================================

CONSOLE_USER=$(
    stat -f "%Su" /dev/console
)

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    echo "No logged-in user detected."
    exit 1
fi

USER_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory |
    awk '{print $2}')

echo "Logged-in user : $CONSOLE_USER"
echo "User home      : $USER_HOME"
echo ""

# ==========================================
# PATHS
# ==========================================

APP="/Applications/RustDesk.app"

USER_PREFS="$USER_HOME/Library/Preferences/com.carriez.RustDesk"
USER_SUPPORT="$USER_HOME/Library/Application Support/RustDesk"
USER_LOGS="$USER_HOME/Library/Logs/RustDesk"
USER_AGENT="$USER_HOME/Library/LaunchAgents/com.carriez.RustDesk.autostart.plist"

ROOT_PREFS="/var/root/Library/Preferences/com.carriez.RustDesk"
ROOT_SUPPORT="/var/root/Library/Application Support/RustDesk"
ROOT_LOGS="/var/root/Library/Logs/RustDesk"

SYSTEM_SUPPORT="/Library/Application Support/RustDesk"

SERVICE_PLIST="/Library/LaunchDaemons/com.carriez.RustDesk_service.plist"

# ==========================================
# STOP PROCESSES
# ==========================================

echo "Stopping RustDesk processes..."

pkill -9 -x RustDesk 2>/dev/null || true
pkill -9 -f "/RustDesk.app/" 2>/dev/null || true

# ==========================================
# UNLOAD LAUNCH DAEMONS / AGENTS
# ==========================================

echo "Stopping RustDesk launch services..."

if [ -f "$SERVICE_PLIST" ]; then
    launchctl bootout system "$SERVICE_PLIST" 2>/dev/null || true
fi

if [ -f "$USER_AGENT" ]; then
    launchctl bootout "gui/$(id -u "$CONSOLE_USER")" "$USER_AGENT" \
        2>/dev/null || true
fi

# ==========================================
# REMOVE SERVICE FILES
# ==========================================

echo "Removing service files..."

rm -f \
    "/Library/LaunchDaemons/com.carriez.RustDesk_service.plist"

rm -f \
    "/Library/LaunchAgents/com.carriez.RustDesk_service.plist"

rm -f \
    "$USER_AGENT"

# ==========================================
# REMOVE APPLICATION
# ==========================================

echo "Removing RustDesk.app..."

if [ -d "$APP" ]; then
    rm -rf "$APP"
fi

# ==========================================
# REMOVE USER DATA
# ==========================================

echo "Removing user configuration..."

rm -rf "$USER_PREFS"
rm -rf "$USER_SUPPORT"
rm -rf "$USER_LOGS"

# ==========================================
# REMOVE ROOT DATA
# ==========================================

echo "Removing root configuration..."

rm -rf "$ROOT_PREFS"
rm -rf "$ROOT_SUPPORT"
rm -rf "$ROOT_LOGS"

# ==========================================
# REMOVE SYSTEM DATA
# ==========================================

echo "Removing system RustDesk data..."

rm -rf "$SYSTEM_SUPPORT"

# ==========================================
# REMOVE OLD DMG MOUNTS
# ==========================================

echo "Unmounting RustDesk DMGs..."

mount |
while read -r line; do

    if echo "$line" | grep -qi rustdesk; then

        mount_point=$(echo "$line" |
            sed -n 's/.* on \(\/Volumes\/[^ ]*\).*/\1/p')

        if [ -n "$mount_point" ]; then
            echo "Unmounting: $mount_point"

            hdiutil detach "$mount_point" \
                -force \
                >/dev/null 2>&1 || true
        fi

    fi

done

# ==========================================
# KILL AGAIN
# ==========================================

echo "Final process cleanup..."

pkill -9 -x RustDesk 2>/dev/null || true
pkill -9 -f "/RustDesk.app/" 2>/dev/null || true

# ==========================================
# VERIFY
# ==========================================

echo ""
echo "========================================"
echo "VERIFY"
echo "========================================"

if [ -d "$APP" ]; then
    echo "WARNING: RustDesk.app still exists"
else
    echo "OK: RustDesk.app removed"
fi

if pgrep -alf RustDesk >/dev/null 2>&1; then
    echo "WARNING: RustDesk process still running:"
    pgrep -alf RustDesk
else
    echo "OK: RustDesk processes stopped"
fi

echo ""
echo "User RustDesk files:"

find "$USER_HOME/Library" \
    \( -iname '*rustdesk*' -o -iname '*carriez*' \) \
    2>/dev/null |
    grep -v "/Google/Chrome/" |
    grep -v "/DiagnosticReports/" |
    grep -v "/CrashReporter/" \
    || echo "OK: no relevant user RustDesk files"

echo ""
echo "Root RustDesk files:"

find "/var/root/Library" \
    \( -iname '*rustdesk*' -o -iname '*carriez*' \) \
    2>/dev/null \
    || echo "OK: no root RustDesk files"

echo ""
echo "System RustDesk files:"

find "/Library" \
    \( -iname '*rustdesk*' -o -iname '*carriez*' \) \
    2>/dev/null \
    || echo "OK: no system RustDesk files"

echo ""
echo "========================================"
echo "RustDesk cleanup completed"
echo "========================================"
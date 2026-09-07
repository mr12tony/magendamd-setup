#!/bin/bash

set -u

echo "========================================"
echo " RustDesk FULL CLEANUP"
echo "========================================"
echo ""

CURRENT_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console)}"
USER_HOME="$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"

if [ -z "$USER_HOME" ]; then
  USER_HOME="/Users/$CURRENT_USER"
fi

echo "User: $CURRENT_USER"
echo "Home: $USER_HOME"
echo ""

# ========================================
# REMOVE MAGENDA SUPPORT INSTALL TOKEN
# ========================================

echo "Removing MagendaSupport install token..."

INSTALL_JSON="$USER_HOME/Library/Application Support/MagendaSupport/install.json"

if [ -f "$INSTALL_JSON" ]; then
  rm -f "$INSTALL_JSON"
  echo "OK: MagendaSupport install.json removed"
else
  echo "OK: MagendaSupport install.json does not exist"
fi

# ========================================
# 1. CLOSE RUSTDESK
# ========================================

echo "[1/7] Closing RustDesk..."

pkill -x RustDesk 2>/dev/null || true
pkill -f "/RustDesk.app/" 2>/dev/null || true

sleep 1

# ========================================
# 2. STOP / REMOVE SERVICES
# ========================================

echo "[2/7] Removing RustDesk services..."

launchctl bootout system/com.carriez.RustDesk_service 2>/dev/null || true
launchctl remove com.carriez.RustDesk_service 2>/dev/null || true

# Kill remaining RustDesk processes after service removal
pkill -9 -f "RustDesk" 2>/dev/null || true

# ========================================
# 3. REMOVE APPLICATION
# ========================================

echo "[3/7] Removing RustDesk.app..."

rm -rf "/Applications/RustDesk.app"

# ========================================
# 4. REMOVE SYSTEM FILES
# ========================================

echo "[4/7] Removing system RustDesk files..."

rm -f "/Library/LaunchDaemons/com.carriez.RustDesk_service.plist"
rm -f "/Library/LaunchAgents/com.carriez.RustDesk_server.plist"
rm -f "/Library/LaunchAgents/com.carriez.RustDesk.plist"

rm -rf "/Library/Application Support/RustDesk"
rm -rf "/Library/Application Support/com.carriez.RustDesk"

# ========================================
# 5. REMOVE USER CONFIG
# ========================================

echo "[5/7] Removing user RustDesk configuration..."

rm -rf "$USER_HOME/Library/Preferences/com.carriez.RustDesk"
rm -f "$USER_HOME/Library/Preferences/com.carriez.RustDesk.plist"

rm -rf "$USER_HOME/Library/Application Support/RustDesk"
rm -rf "$USER_HOME/Library/Application Support/com.carriez.RustDesk"

rm -rf "$USER_HOME/.config/rustdesk"

rm -rf "$USER_HOME/Library/Caches/com.carriez.RustDesk"
rm -rf "$USER_HOME/Library/Caches/RustDesk"

rm -rf "$USER_HOME/Library/Saved Application State/com.carriez.RustDesk.savedState"

# ========================================
# 6. REMOVE RUSTDESK TCC PERMISSIONS
# ========================================

echo "[6/7] Resetting RustDesk macOS permissions..."

sudo -u "$CURRENT_USER" tccutil reset Accessibility com.carriez.RustDesk 2>/dev/null || true
sudo -u "$CURRENT_USER" tccutil reset ScreenCapture com.carriez.RustDesk 2>/dev/null || true
sudo -u "$CURRENT_USER" tccutil reset ListenEvent com.carriez.RustDesk 2>/dev/null || true

# ========================================
# 7. VERIFY
# ========================================

echo "[7/7] Verifying cleanup..."
echo ""

if [ -d "/Applications/RustDesk.app" ]; then
  echo "ERROR: /Applications/RustDesk.app still exists"
else
  echo "OK: RustDesk.app removed"
fi

if launchctl print system/com.carriez.RustDesk_service >/dev/null 2>&1; then
  echo "ERROR: RustDesk service still loaded"
else
  echo "OK: RustDesk service removed"
fi

if pgrep -f "RustDesk" >/dev/null 2>&1; then
  echo "WARNING: RustDesk process still running:"
  pgrep -fl "RustDesk"
else
  echo "OK: No RustDesk processes"
fi

echo ""
echo "========================================"
echo " RustDesk cleanup complete"
echo "========================================"
echo ""
echo "You can now test MagendaSupport installation from scratch."
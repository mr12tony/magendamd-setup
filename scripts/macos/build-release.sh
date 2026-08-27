#!/bin/bash

set -euo pipefail

# ============================================================
# MagendaSupport macOS Release Build
#
# Flow:
#   1. Load Tauri updater private key
#   2. Ask for password
#   3. Build universal macOS app
#   4. Verify architecture
#   5. Build DMG
#   6. Clear secrets
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KEY_PATH="$HOME/.tauri/magendasupport.key"

TAURI_TARGET="universal-apple-darwin"

BUNDLE_DIR="$ROOT/src-tauri/target/$TAURI_TARGET/release/bundle/macos"

APP_PATH="$BUNDLE_DIR/MagendaSupport.app"

UPDATER_ARCHIVE="$BUNDLE_DIR/MagendaSupport.app.tar.gz"
UPDATER_SIGNATURE="$BUNDLE_DIR/MagendaSupport.app.tar.gz.sig"

echo
echo "============================================"
echo " MagendaSupport macOS Release Build"
echo "============================================"
echo

if [[ ! -f "$KEY_PATH" ]]; then
    echo "ERROR: updater private key not found:"
    echo "$KEY_PATH"
    exit 1
fi

read -r -s -p "Enter updater private key password: " KEY_PASSWORD
echo

export TAURI_SIGNING_PRIVATE_KEY
TAURI_SIGNING_PRIVATE_KEY="$(cat "$KEY_PATH")"

export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$KEY_PASSWORD"

cleanup() {
    unset TAURI_SIGNING_PRIVATE_KEY
    unset TAURI_SIGNING_PRIVATE_KEY_PASSWORD

    KEY_PASSWORD=""

    echo
    echo "Updater signing secrets cleared."
}

trap cleanup EXIT

cd "$ROOT"

echo
echo "Building universal macOS release..."
echo

npm run tauri build -- --target "$TAURI_TARGET"

echo
echo "Checking application architecture..."

BINARY="$APP_PATH/Contents/MacOS/magendamd-setup"

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: application binary not found:"
    echo "$BINARY"
    exit 1
fi

file "$BINARY"

echo
echo "Checking updater artifacts..."

if [[ ! -f "$UPDATER_ARCHIVE" ]]; then
    echo "ERROR: updater archive not found:"
    echo "$UPDATER_ARCHIVE"
    exit 1
fi

if [[ ! -f "$UPDATER_SIGNATURE" ]]; then
    echo "ERROR: updater signature not found:"
    echo "$UPDATER_SIGNATURE"
    exit 1
fi

echo
echo "Updater archive:"
echo "$UPDATER_ARCHIVE"

echo
echo "Updater signature:"
echo "$UPDATER_SIGNATURE"

echo
echo "Building DMG..."

"$ROOT/scripts/macos/build-dmg.sh"

echo
echo "============================================"
echo " macOS release build SUCCESS"
echo "============================================"
echo
echo "Updater:"
echo "$UPDATER_ARCHIVE"
echo
echo "Signature:"
echo "$UPDATER_SIGNATURE"
echo
echo "DMG:"
echo "$ROOT/dist/macos/MagendaSupport.dmg"
echo
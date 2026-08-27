#!/bin/bash

set -euo pipefail

# ============================================================
# build-dmg.sh
#
# Builds a single reusable MagendaSupport.dmg
#
# Usage:
#
# ./scripts/macos/build-dmg.sh
#
# Flow:
#   1. Find Tauri-built MagendaSupport.app
#   2. Copy it into temporary staging
#   3. Verify signature if present
#   4. Create styled DMG
#   5. Clean temporary files
#
# Install token is NOT embedded into the DMG anymore.
# It is received through:
#
# magendasupport://install?token=...
# ============================================================


# ============================================================
# Resolve project root
#
# scripts/macos/build-dmg.sh
# -> project root = ../..
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"


# ============================================================
# Paths
# ============================================================

BASE_APP="$ROOT/src-tauri/target/universal-apple-darwin/release/bundle/macos/MagendaSupport.app"

DIST="$ROOT/dist/macos"

WORK_DIR="$DIST/.work"
STAGING_DIR="$WORK_DIR/staging"

APP_NAME="MagendaSupport.app"
APP_PATH="$STAGING_DIR/$APP_NAME"

OUTPUT_DMG="$DIST/MagendaSupport.dmg"

# Optional background:
#
# BACKGROUND="$ROOT/scripts/macos/dmg-background.png"


# ============================================================
# Check dependencies
# ============================================================

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "ERROR: create-dmg is not installed."
  echo
  echo "Install it with:"
  echo "brew install create-dmg"
  exit 1
fi


# ============================================================
# Check base application
# ============================================================

if [[ ! -d "$BASE_APP" ]]; then
  echo "ERROR: Base Tauri app not found:"
  echo "$BASE_APP"
  echo
  echo "Run first:"
  echo "npm run tauri build"
  exit 1
fi


# ============================================================
# Start
# ============================================================

echo
echo "============================================"
echo "Building MagendaSupport DMG"
echo "============================================"
echo
echo "Base app:"
echo "$BASE_APP"
echo
echo "Output:"
echo "$OUTPUT_DMG"
echo


# ============================================================
# Prepare directories
# ============================================================

rm -rf "$WORK_DIR"

mkdir -p "$STAGING_DIR"
mkdir -p "$DIST"


# ============================================================
# Copy application
#
# ditto preserves macOS bundle metadata, permissions,
# extended attributes and symlinks better than cp -R.
# ============================================================

echo "Copying MagendaSupport.app..."

ditto \
  "$BASE_APP" \
  "$APP_PATH"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: MagendaSupport.app was not copied."
  exit 1
fi


# ============================================================
# Verify application bundle
# ============================================================

echo
echo "Application staged:"
echo "$APP_PATH"
echo


# ============================================================
# Verify existing code signature
#
# During development the application may be unsigned.
# ============================================================

if command -v codesign >/dev/null 2>&1; then
  echo "Checking app signature..."

  if codesign \
      --verify \
      --deep \
      --strict \
      "$APP_PATH" \
      >/dev/null 2>&1
  then
    echo "Code signature: VALID"
  else
    echo "Code signature: unsigned or verification failed."
    echo "This is expected during local development."
  fi
fi


# ============================================================
# Remove previous DMG
# ============================================================

rm -f "$OUTPUT_DMG"


# ============================================================
# Optional background verification
# ============================================================

# if [[ ! -f "$BACKGROUND" ]]; then
#   echo "ERROR: DMG background not found:"
#   echo "$BACKGROUND"
#   exit 1
# fi


# ============================================================
# Create styled DMG
#
# create-dmg itself creates the Applications drop-link.
# Do NOT create an Applications symlink manually.
# ============================================================

echo
echo "Creating styled DMG..."

create-dmg \
  --volname "MagendaSupport" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 96 \
  --icon "$APP_NAME" 180 190 \
  --hide-extension "$APP_NAME" \
  --app-drop-link 480 190 \
  "$OUTPUT_DMG" \
  "$STAGING_DIR"


# ============================================================
# If you want the custom background later, use this instead:
#
# create-dmg \
#   --volname "MagendaSupport" \
#   --window-pos 200 120 \
#   --window-size 660 400 \
#   --background "$BACKGROUND" \
#   --icon-size 96 \
#   --icon "$APP_NAME" 180 190 \
#   --hide-extension "$APP_NAME" \
#   --app-drop-link 480 190 \
#   "$OUTPUT_DMG" \
#   "$STAGING_DIR"
# ============================================================


# ============================================================
# Verify DMG
# ============================================================

if [[ ! -f "$OUTPUT_DMG" ]]; then
  echo "ERROR: DMG was not created."
  exit 1
fi


# ============================================================
# Cleanup
# ============================================================

rm -rf "$WORK_DIR"


# ============================================================
# DONE
# ============================================================

echo
echo "============================================"
echo "MagendaSupport DMG created successfully"
echo "============================================"
echo
echo "$OUTPUT_DMG"
echo
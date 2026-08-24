#!/bin/bash

set -euo pipefail

TARGET_VERSION="1.4.9"

RUSTDESK_ID_SERVER="rustdesk.example.com"
RUSTDESK_RELAY_SERVER="rustdesk.example.com"
RUSTDESK_KEY="YOUR_PUBLIC_KEY"
RUSTDESK_PASSWORD="YOUR_PASSWORD"
RUSTDESK_PORT="21116"

RUSTDESK_APP="/Applications/RustDesk.app"
RUSTDESK_BIN="$RUSTDESK_APP/Contents/MacOS/RustDesk"

SERVICE_LABEL="com.carriez.RustDesk_service"
SERVICE_PLIST="/Library/LaunchDaemons/${SERVICE_LABEL}.plist"

log() {
  echo "[RustDesk deployment] $*"
}

fail() {
  echo
  echo "[RustDesk deployment] ERROR: $*" >&2
  echo
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "Root privileges are required."
  fi
}
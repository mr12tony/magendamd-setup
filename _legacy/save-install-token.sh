#!/bin/bash

set -euo pipefail

INSTALLER_PATH="${1:-}"

if [[ -z "$INSTALLER_PATH" ]]; then
  echo "[Token] ERROR: Installer path is required."
  exit 1
fi

echo "[Token] Installer path: $INSTALLER_PATH"

filename="$(basename "$INSTALLER_PATH")"

# remove extension
filename="${filename%.*}"

echo "[Token] Installer filename: $filename"

# Supports:
#
# MagendaSupport-abc123.dmg
# MagendaSupport-abc123 (1).dmg
# magendamd-setup-abc123.pkg
#
if [[ "$filename" =~ ^(magendamd-setup|MagendaSupport)-([A-Za-z0-9_-]+)(\ \([0-9]+\))?$ ]]; then
  token="${BASH_REMATCH[2]}"
else
  echo "[Token] Token not found in filename."
  exit 2
fi

if [[ -z "$token" ]]; then
  echo "[Token] Token is empty."
  exit 3
fi

directory="/Library/Application Support/MagendaSupport"
output_file="$directory/install.json"

echo "[Token] Output: $output_file"

sudo mkdir -p "$directory"

# Avoid echo/printf escaping problems.
TOKEN="$token" OUTPUT_FILE="$output_file" python3 <<'PY'
import json
import os

token = os.environ["TOKEN"]
path = os.environ["OUTPUT_FILE"]

with open(path, "w", encoding="utf-8") as f:
    json.dump(
        {"install_token": token},
        f,
        ensure_ascii=False,
        separators=(",", ":"),
    )
PY

sudo chown root:wheel "$output_file"
sudo chmod 644 "$output_file"

if [[ ! -f "$output_file" ]]; then
  echo "[Token] ERROR: install.json was not created."
  exit 1
fi

echo "[Token] Token saved successfully."
exit 0
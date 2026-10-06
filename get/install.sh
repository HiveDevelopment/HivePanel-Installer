#!/usr/bin/env bash
set -euo pipefail

INSTALLER_URL="${HIVEPANEL_INSTALLER_URL:-https://raw.githubusercontent.com/HiveDevelopment/HivePanel-Installer/main/install.sh}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 "$INSTALLER_URL" -o "$tmp"
exec bash "$tmp" "$@"

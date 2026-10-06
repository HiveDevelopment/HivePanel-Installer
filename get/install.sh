#!/usr/bin/env bash
set -euo pipefail

INSTALLER_URL="${HIVEPANEL_INSTALLER_URL:-https://raw.githubusercontent.com/HiveDevelopment/HivePanel-Installer/main/install.sh}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [[ ! -r /dev/tty ]]; then
    printf '\033[1;31m[HivePanel] ERROR:\033[0m An interactive terminal is required.\n' >&2
    exit 1
fi

curl -fsSL --retry 3 "$INSTALLER_URL" -o "$tmp"

exec bash "$tmp" "$@" </dev/tty
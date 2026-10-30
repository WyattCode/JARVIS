#!/usr/bin/env bash
# Only installs our package. HyperOS may require the owner to unlock/confirm.
set -euo pipefail
cd "$(dirname "$0")/.."
adb_path="${JARVIS_ADB:-/home/user/.local/opt/jarvis-adb/adb37}"
apk_path="${1:-build/app/outputs/flutter-apk/app-release.apk}"
if [[ ! -f "$apk_path" ]]; then printf 'APK not found: %s\n' "$apk_path" >&2; exit 1; fi
device_id="${JARVIS_DEVICE:-}"
if [[ -z "$device_id" ]]; then
  mapfile -t connected < <("$adb_path" devices | awk '$2 == "device" && $1 !~ /^emulator-/ { print $1 }')
  if [[ "${#connected[@]}" != 1 ]]; then
    printf 'Select one connected phone using JARVIS_DEVICE; found %s phones.\n' "${#connected[@]}" >&2
    exit 1
  fi
  device_id="${connected[0]}"
fi
"$adb_path" -s "$device_id" install --no-incremental -r "$apk_path"
"$adb_path" -s "$device_id" shell am start -n ai.jarvis.app.android/.MainActivity

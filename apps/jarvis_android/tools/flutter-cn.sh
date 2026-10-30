#!/usr/bin/env bash
set -euo pipefail
export PUB_HOSTED_URL=https://pub.dev
export FLUTTER_STORAGE_BASE_URL=https://storage.googleapis.com
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
sdk_path="${JARVIS_FLUTTER_SDK:-/home/user/.local/opt/jarvis-flutter}"
exec "$sdk_path/bin/flutter" "$@"

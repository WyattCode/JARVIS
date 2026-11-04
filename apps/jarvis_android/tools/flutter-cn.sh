#!/usr/bin/env bash
set -euo pipefail
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
sdk_path="${JARVIS_FLUTTER_SDK:-/home/wyatt/.local/opt/jarvis-flutter}"
exec "$sdk_path/bin/flutter" "$@"

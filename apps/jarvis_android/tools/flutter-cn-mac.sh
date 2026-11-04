#!/usr/bin/env bash
# macOS counterpart of flutter-cn.sh: China mirrors plus the Xcode developer dir.
set -euo pipefail
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
exec "${JARVIS_FLUTTER_SDK:-$HOME/development/flutter}/bin/flutter" "$@"

#!/usr/bin/env bash
# E2EAppFlutter を debug apk としてビルドし dist/android/ へ配置する。
set -euo pipefail

cd "$(dirname "$0")/.."

command -v flutter >/dev/null 2>&1 || { echo "flutter 未インストール('brew install --cask flutter')" >&2; exit 1; }

flutter build apk --debug

OUT_DIR="dist/android"
mkdir -p "$OUT_DIR"
APK_DST="$OUT_DIR/ft-e2e-flutter-debug.apk"
cp build/app/outputs/flutter-apk/app-debug.apk "$APK_DST"

echo "built: $APK_DST"
echo "install例: adb install -r $APK_DST"

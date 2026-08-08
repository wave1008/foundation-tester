#!/usr/bin/env bash
# E2EAppRN を release apk としてビルドし dist/android/ へ配置する。
# android/app/build.gradle の release buildType は signingConfigs.debug で署名する
# (無署名 APK はインストール不可なため)。
set -euo pipefail

cd "$(dirname "$0")/.."

test -x android/gradlew || { echo "android/gradlew が無い(pod install/npm install 未実行?)" >&2; exit 1; }

(cd android && ./gradlew assembleRelease)

OUT_DIR="dist/android"
mkdir -p "$OUT_DIR"
APK_SRC="android/app/build/outputs/apk/release/app-release.apk"
APK_DST="$OUT_DIR/ft-e2e-rn-release.apk"
cp "$APK_SRC" "$APK_DST"

echo "built: $APK_DST"
echo "install例: adb install -r $APK_DST"

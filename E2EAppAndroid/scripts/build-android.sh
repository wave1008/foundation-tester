#!/usr/bin/env bash
# E2EAppAndroid(Android ネイティブ SUT)を debug apk としてビルドし dist/android/ へ配置する。
set -euo pipefail

cd "$(dirname "$0")/.."

SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"

# local.properties は .gitignore 対象(マシン固有)。冪等に sdk.dir だけ書く。
if [ -f local.properties ] && grep -q '^sdk.dir=' local.properties; then
  sed -i '' "s#^sdk.dir=.*#sdk.dir=${SDK_DIR}#" local.properties
else
  echo "sdk.dir=${SDK_DIR}" >> local.properties
fi

./gradlew :app:assembleDebug --console=plain

OUT_DIR="dist/android"
mkdir -p "$OUT_DIR"
APK_SRC=$(find app/build/outputs/apk/debug -maxdepth 1 -name '*.apk' | head -1)
APK_DST="$OUT_DIR/ft-e2e-android-debug.apk"
cp "$APK_SRC" "$APK_DST"

echo "built: $APK_DST"
echo "install例: adb install -r $APK_DST"

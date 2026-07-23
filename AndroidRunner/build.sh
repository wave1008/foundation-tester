#!/bin/bash
# ftester Android ブリッジ APK のビルド(gradle 不要、Android SDK 付属ツールのみ)。
# 使い方:
#   ./build.sh              ビルドして prebuilt/ftbridge.apk を更新
#   ./build.sh --install    さらに接続中の全デバイスへ adb install -r
#
# バージョンを上げるときは VERSION_CODE と
# Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode を同時に上げること。
set -euo pipefail
cd "$(dirname "$0")"

VERSION_CODE=10

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[ -d "$SDK" ] || { echo "Android SDK が見つかりません(ANDROID_HOME を設定)"; exit 1; }
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
JAR="$SDK/platforms/$(ls "$SDK/platforms" | sort -V | tail -1)/android.jar"
echo "build-tools: $BT"
echo "android.jar: $JAR"

rm -rf out
mkdir -p out/classes prebuilt

# 1. Java → class(-bootclasspath は -source/-target 8 のときだけ使える)
javac -source 8 -target 8 -bootclasspath "$JAR" -encoding UTF-8 \
      -d out/classes src/com/example/ftbridge/*.java 2> >(grep -v '^警告' >&2 || true)

# 2. class → dex
"$BT/d8" --release --lib "$JAR" --min-api 26 --output out/ \
         out/classes/com/example/ftbridge/*.class

# 3. マニフェストのみの APK を生成(リソース無し)
"$BT/aapt2" link -o out/ftbridge.unaligned.apk --manifest AndroidManifest.xml -I "$JAR" \
            --version-code "$VERSION_CODE" --version-name "1.$VERSION_CODE"

# 4. classes.dex を APK ルートへ格納 → アライン → 署名
(cd out && zip -q -j ftbridge.unaligned.apk classes.dex)
"$BT/zipalign" -f 4 out/ftbridge.unaligned.apk out/ftbridge.apk

KEYSTORE="$HOME/.android/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
          -alias androiddebugkey -keyalg RSA -validity 10950 \
          -dname "CN=Android Debug,O=Android,C=US"
fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android out/ftbridge.apk

cp out/ftbridge.apk prebuilt/ftbridge.apk
echo "✅ prebuilt/ftbridge.apk (versionCode=$VERSION_CODE, $(du -h prebuilt/ftbridge.apk | cut -f1 | tr -d ' '))"

if [ "${1:-}" = "--install" ]; then
  ADB="${SDK}/platform-tools/adb"
  for serial in $("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}'); do
    "$ADB" -s "$serial" install -r prebuilt/ftbridge.apk >/dev/null \
      && echo "✅ install: $serial"
  done
fi

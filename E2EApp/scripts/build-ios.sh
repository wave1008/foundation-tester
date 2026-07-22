#!/usr/bin/env bash
# E2EApp を iOS シミュレータ向け Debug ビルドし dist/ios-simulator/ へ配置する。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未インストール。'brew install xcodegen' を実行してください。" >&2
  exit 1
fi

(cd iosApp && xcodegen generate)

# generic destination は ARCHS に x86_64 を混入させ、Compose(iosSimulatorArm64 のみ配信)の
# syncComposeResourcesForIos が "Unknown iOS simulator arch: 'x86_64'" で落ちる。arm64 固定で回避。
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath iosApp/build \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 EXCLUDED_ARCHS=x86_64 build

OUT_DIR="dist/ios-simulator"
mkdir -p "$OUT_DIR"
APP_SRC="iosApp/build/Build/Products/Debug-iphonesimulator/iosApp.app"
APP_DST="$OUT_DIR/FTE2E.app"
# .app 名は cosmetic。ftester/simctl の install 判定は中身の Info.plist の bundle id で行う。
rsync -a --delete "$APP_SRC/" "$APP_DST/"

echo "built: $APP_DST"
echo "install例: xcrun simctl install <device-id> $APP_DST"

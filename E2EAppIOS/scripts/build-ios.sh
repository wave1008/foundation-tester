#!/usr/bin/env bash
# E2EAppIOS(iOS ネイティブ SUT)を iOS シミュレータ向け Debug ビルドし dist/ios-simulator/ へ配置する。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未インストール。'brew install xcodegen' を実行してください。" >&2
  exit 1
fi

xcodegen generate

xcodebuild -project FTE2EIOS.xcodeproj -scheme FTE2EIOS -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 EXCLUDED_ARCHS=x86_64 build

OUT_DIR="dist/ios-simulator"
mkdir -p "$OUT_DIR"
APP_SRC="build/Build/Products/Debug-iphonesimulator/FTE2EIOS.app"
APP_DST="$OUT_DIR/FTE2EIOS.app"
# .app 名は cosmetic。ftester/simctl の install 判定は中身の Info.plist の bundle id で行う。
rsync -a --delete "$APP_SRC/" "$APP_DST/"

echo "built: $APP_DST"

#!/usr/bin/env bash
# E2EAppFlutter を iOS シミュレータ向け Debug ビルドし dist/ios-simulator/ へ配置する。
#
# **`flutter build ios --simulator` は使えない**(2026-07-23・Flutter 3.44.7 / Xcode 27):
# universal(x86_64+arm64)を要求する内部チェックが lipo の出力と食い違い、
#   Target debug_unpack_ios failed: Binary .../Flutter.framework/Flutter does not contain
#   architectures "arm64 x86_64"
# で必ず落ちる(lipo -info では両方入っている)。arm64 固定で xcodebuild を直接叩いて回避する。
set -euo pipefail

cd "$(dirname "$0")/.."

command -v flutter >/dev/null 2>&1 || { echo "flutter 未インストール('brew install --cask flutter')" >&2; exit 1; }

flutter pub get

xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios-derived \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 EXCLUDED_ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build

OUT_DIR="dist/ios-simulator"
mkdir -p "$OUT_DIR"
APP_SRC="build/ios-derived/Build/Products/Debug-iphonesimulator/Runner.app"
APP_DST="$OUT_DIR/FTE2EFlutter.app"
# .app 名は cosmetic。ftester/simctl の install 判定は中身の Info.plist の bundle id で行う。
rsync -a --delete "$APP_SRC/" "$APP_DST/"

echo "built: $APP_DST"

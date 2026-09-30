#!/usr/bin/env bash
# E2EXAppRN を iOS シミュレータ向け Release ビルドし dist/ios-simulator/ へ配置する。
#
# RN の Debug 構成は Metro 常時接続が前提(JS がバンドルに同梱されない)なので E2E には使えない。
# Release は xcodebuild のビルドフェーズが JS バンドルを同梱するため、これを使う。
set -euo pipefail

cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild 未インストール" >&2; exit 1; }
# 依存が無い機械(ランナー)でもビルドできるように、無ければここで入れる(npm ci は lock どおり・pod は Podfile.lock どおり)
[ -d node_modules ] || npm ci
[ -d ios/Pods ] || (cd ios && pod install)

xcodebuild -workspace ios/FTE2EXRN.xcworkspace -scheme FTE2EXRN -configuration Release \
  -sdk iphonesimulator -derivedDataPath build/ios-derived \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build

OUT_DIR="dist/ios-simulator"
mkdir -p "$OUT_DIR"
APP_SRC="build/ios-derived/Build/Products/Release-iphonesimulator/FTE2EXRN.app"
APP_DST="$OUT_DIR/FTE2EXRN.app"
rsync -a --delete "$APP_SRC/" "$APP_DST/"
# rsync -a は mtime を保存するので成果物の時刻が進まず、Scripts/e2e.sh の needs_rebuild が
# 毎回真になる(ソースが常に新しく見える)。touch を消すと実行のたびに再ビルドが走る。
touch "$APP_DST"

echo "built: $APP_DST"

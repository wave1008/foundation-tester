#!/usr/bin/env bash
# E2EAppCMP を **実機向け** Debug ビルドし dist/ios-device/ へ配置する。
# シミュレータ版は build-ios.sh(-sdk iphonesimulator・署名なし)。実機は署名が要るので別スクリプト
# (同じ形の E2EAppIOS/scripts/build-ios-device.sh と揃えてある)。
#
# Team ID は環境変数 FT_DEVELOPMENT_TEAM、無ければ ~/.config/fleetest/config.json の developmentTeam。
# **Team ID は署名証明書の OU**(`security find-identity` の括弧内は証明書 ID であって Team ID ではない)。
# Kotlin のフレームワーク(iosArm64)は Xcode のビルドフェーズが gradle で作るので、初回は数分かかる。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未インストール。'brew install xcodegen' を実行してください。" >&2
  exit 1
fi

TEAM="${FT_DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$HOME/.config/fleetest/config.json" ]; then
  TEAM=$(python3 -c 'import json,os,sys;print(json.load(open(os.path.expanduser("~/.config/fleetest/config.json"))).get("developmentTeam",""))')
fi
if [ -z "$TEAM" ]; then
  echo "❌ Team ID がありません。FT_DEVELOPMENT_TEAM を設定するか、" >&2
  echo "   ~/.config/fleetest/config.json に developmentTeam を設定してください。" >&2
  exit 1
fi

(cd iosApp && xcodegen generate)

# シミュレータ版(iosApp/build)と DerivedData を分ける(同じ場所だと片方のビルドがもう片方を作り直させる)
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath iosApp/build-device \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$TEAM" \
  ARCHS=arm64 build

OUT_DIR="dist/ios-device"
mkdir -p "$OUT_DIR"
APP_SRC="iosApp/build-device/Build/Products/Debug-iphoneos/iosApp.app"
APP_DST="$OUT_DIR/FTE2E.app"
# 署名は .app 内に埋まっているので rsync でそのまま運べる
rsync -a --delete "$APP_SRC/" "$APP_DST/"
# rsync -a は mtime を保存するので、touch しないと Scripts/e2e.sh の needs_rebuild が毎回真になる
touch "$APP_DST"

echo "built: $APP_DST (team $TEAM)"

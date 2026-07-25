#!/usr/bin/env bash
# E2EAppIOS(iOS ネイティブ SUT)を **実機向け** Debug ビルドし dist/ios-device/ へ配置する。
# シミュレータ版は build-ios.sh(-sdk iphonesimulator・署名なし)。実機は署名が要るので別スクリプト。
#
# Team ID は環境変数 FT_DEVELOPMENT_TEAM、無ければ ~/.config/ftester/config.json の developmentTeam。
# **Team ID は署名証明書の OU**(`security find-identity` の括弧内は証明書 ID であって Team ID ではない)。
#   security find-certificate -c "Apple Development: <you>" -p | openssl x509 -noout -subject
# bundle id プレフィックスは FT_BUNDLE_ID_PREFIX(既定はプロジェクト定義の com.ftester のまま)。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未インストール。'brew install xcodegen' を実行してください。" >&2
  exit 1
fi

TEAM="${FT_DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$HOME/.config/ftester/config.json" ]; then
  TEAM=$(python3 -c 'import json,os,sys;print(json.load(open(os.path.expanduser("~/.config/ftester/config.json"))).get("developmentTeam",""))')
fi
if [ -z "$TEAM" ]; then
  echo "❌ Team ID がありません。FT_DEVELOPMENT_TEAM を設定するか、" >&2
  echo "   ~/.config/ftester/config.json に developmentTeam を設定してください。" >&2
  exit 1
fi

xcodegen generate

xcodebuild -project FTE2EIOS.xcodeproj -scheme FTE2EIOS -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build-device \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$TEAM" \
  ${FT_BUNDLE_ID_PREFIX:+PRODUCT_BUNDLE_IDENTIFIER=$FT_BUNDLE_ID_PREFIX.e2e.ios} \
  ARCHS=arm64 build

OUT_DIR="dist/ios-device"
mkdir -p "$OUT_DIR"
APP_SRC="build-device/Build/Products/Debug-iphoneos/FTE2EIOS.app"
APP_DST="$OUT_DIR/FTE2EIOS.app"
# シミュレータ版と同居させる(実体が別物なので dist のディレクトリを分ける)。
# 署名は .app 内に埋まっているので rsync でそのまま運べる
rsync -a --delete "$APP_SRC/" "$APP_DST/"

echo "built: $APP_DST (team $TEAM)"

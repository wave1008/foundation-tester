#!/usr/bin/env bash
# E2EAppRN を **実機向け** Release ビルドし dist/ios-device/ へ配置する。
# シミュレータ版は build-ios.sh(署名なし)。実機は署名が要るので別スクリプト
# (同じ形の E2EAppIOS / E2EAppCMP の build-ios-device.sh と揃えてある)。
# Release にするのはシミュレータ版と同じ理由(Debug は Metro 常時接続が前提で JS がバンドルに入らない)。
# Team ID は環境変数 FT_DEVELOPMENT_TEAM、無ければ ~/.config/fleetest/config.json の developmentTeam。
set -euo pipefail

cd "$(dirname "$0")/.."

# 依存を lock に揃えてからビルドする(Scripts/rn-deps.sh)
. ../Scripts/rn-deps.sh
rn_sync_node_modules
rn_sync_pods

command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild 未インストール" >&2; exit 1; }

TEAM="${FT_DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$HOME/.config/fleetest/config.json" ]; then
  TEAM=$(python3 -c 'import json,os,sys;print(json.load(open(os.path.expanduser("~/.config/fleetest/config.json"))).get("developmentTeam",""))')
fi
if [ -z "$TEAM" ]; then
  echo "❌ Team ID がありません。FT_DEVELOPMENT_TEAM を設定するか、" >&2
  echo "   ~/.config/fleetest/config.json に developmentTeam を設定してください。" >&2
  exit 1
fi

# シミュレータ版(build/ios-derived)と DerivedData を分ける(同じ場所だと片方のビルドがもう片方を作り直させる)
xcodebuild -workspace ios/FTE2ERN.xcworkspace -scheme FTE2ERN -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-derived-device \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$TEAM" \
  ARCHS=arm64 build

OUT_DIR="dist/ios-device"
mkdir -p "$OUT_DIR"
APP_SRC="build/ios-derived-device/Build/Products/Release-iphoneos/FTE2ERN.app"
APP_DST="$OUT_DIR/FTE2ERN.app"
# 署名は .app 内に埋まっているので rsync でそのまま運べる
rsync -a --delete "$APP_SRC/" "$APP_DST/"
# rsync -a は mtime を保存するので、touch しないと needs_rebuild が毎回真になる
touch "$APP_DST"

echo "built: $APP_DST (team $TEAM)"

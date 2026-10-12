#!/usr/bin/env bash
# E2EAppFlutter を **実機向け** Release ビルドし dist/ios-device/ へ配置する。
# シミュレータ版は build-ios.sh(Debug・署名なし)。実機は署名が要るので別スクリプト
# (同じ形の E2EAppIOS / E2EAppCMP の build-ios-device.sh と揃えてある)。
#
# **Release にする**: Flutter の Debug 構成(JIT)は flutter の道具が付いていないと実機で起動できない
# (ホーム画面・devicectl から起こすと落ちる)。Release は AOT で単独で起動する。
# Team ID は環境変数 FT_DEVELOPMENT_TEAM、無ければ ~/.config/fleetest/config.json の developmentTeam
# (project.pbxproj に書かれた Team はコマンドラインで上書きする)。
set -euo pipefail

cd "$(dirname "$0")/.."

command -v flutter >/dev/null 2>&1 || { echo "flutter 未インストール('brew install --cask flutter')" >&2; exit 1; }

TEAM="${FT_DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ] && [ -f "$HOME/.config/fleetest/config.json" ]; then
  TEAM=$(python3 -c 'import json,os,sys;print(json.load(open(os.path.expanduser("~/.config/fleetest/config.json"))).get("developmentTeam",""))')
fi
if [ -z "$TEAM" ]; then
  echo "❌ Team ID がありません。FT_DEVELOPMENT_TEAM を設定するか、" >&2
  echo "   ~/.config/fleetest/config.json に developmentTeam を設定してください。" >&2
  exit 1
fi

flutter pub get
# Generated.xcconfig を Release の設定で作る(xcodebuild のビルドフェーズがこれを読んで AOT を作る)
flutter build ios --config-only --release --no-codesign

# シミュレータ版(build/ios-derived)と DerivedData を分ける(同じ場所だと片方のビルドがもう片方を作り直させる)
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-derived-device \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$TEAM" \
  ARCHS=arm64 build

OUT_DIR="dist/ios-device"
mkdir -p "$OUT_DIR"
APP_SRC="build/ios-derived-device/Build/Products/Release-iphoneos/Runner.app"
APP_DST="$OUT_DIR/FTE2EFlutter.app"
# 署名は .app 内に埋まっているので rsync でそのまま運べる
rsync -a --delete "$APP_SRC/" "$APP_DST/"
# rsync -a は mtime を保存するので、touch しないと needs_rebuild が毎回真になる
touch "$APP_DST"

echo "built: $APP_DST (team $TEAM)"

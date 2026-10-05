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
# pod install は hermes-engine の checksum を機械ごとに書き換える(podspec の評価が環境に依存)。追跡している
# Podfile.lock を書き換えたまま残すとランナーのクローンが汚れるので元に戻し、Pods/Manifest.lock にも同じ内容を書く
# (Xcode の [CP] Check Pods Manifest.lock が2つを突き合わせ、違うとビルドを止める。入った Pods は同じ)。
# align の reset で Podfile.lock だけが戻った形も、違いが hermes の checksum の1行だけなら揃えるだけで済ませる
install_pods() {
  local backup
  backup="$(mktemp)"
  cp ios/Podfile.lock "$backup"
  (cd ios && pod install)
  cp "$backup" ios/Podfile.lock
  cp "$backup" ios/Pods/Manifest.lock
  rm -f "$backup"
}
if [ ! -d ios/Pods ]; then
  install_pods
elif ! diff -q ios/Podfile.lock ios/Pods/Manifest.lock >/dev/null; then
  if diff <(grep -v '^  hermes-engine: ' ios/Podfile.lock) <(grep -v '^  hermes-engine: ' ios/Pods/Manifest.lock) >/dev/null; then
    cp ios/Podfile.lock ios/Pods/Manifest.lock
  else
    install_pods
  fi
fi

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

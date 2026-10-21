#!/bin/bash
# アプリ内常駐ブリッジ dylib のビルド。
# Swift ソース(BridgeDTO を共有)+ ObjC 構成子を1つの自己完結 dylib にリンクする。
#
#   build.sh            シミュレータ用 → build/libFTInAppBridge.dylib
#   build.sh device     実機用(iphoneos・未署名)→ build/libFTInAppBridge-device.dylib
#
# 注入(シミュレータ): SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<dylib> SIMCTL_CHILD_FT_PORT=<port> xcrun simctl launch <udid> <bundleID>
#   シミュレータプロセスは SIP/hardened runtime 非適用のためリビルドなしで注入できる。
# 注入(実機): dylib を SUT と同じチームの証明書で codesign(InAppCodeSign.swift)→ devicectl でアプリのデータコンテナへ置く →
#   DYLD_INSERT_LIBRARIES 付きで devicectl process launch。**開発署名(get-task-allow)のアプリだけ**(InAppLauncher)。
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="build"

if [ "${1:-simulator}" = "device" ]; then
  SDKNAME="iphoneos"
  TARGET="arm64-apple-ios17.0"
  DYLIB="$OUT/libFTInAppBridge-device.dylib"
  TAG="device"
else
  SDKNAME="iphonesimulator"
  TARGET="arm64-apple-ios17.0-simulator"
  DYLIB="$OUT/libFTInAppBridge.dylib"
  TAG="simulator"
fi
SDK="$(xcrun --sdk "$SDKNAME" --show-sdk-path)"
# 2つのビルドが .o を踏まないよう中間物はタグ別
OBJ="$OUT/obj-$TAG"
mkdir -p "$OBJ"

# 共有 DTO(唯一の定義元)+ in-app 実装をまとめて1モジュールにコンパイル。
# 一覧は Sources/FTCore/BridgeSourceSet.swift(inApp)が唯一の定義元。ここに再掲すると needsBuild の鮮度判定とズレる
SWIFT_SOURCES=(
  "$ROOT/Sources/FTCore/BridgeDTO.swift"
  "$ROOT/Sources/FTCore/WebViewDOMSnapshot.swift"
  "$ROOT/Sources/FTCore/TypeReadback.swift"
  "$ROOT/Sources/FTCore/UIFrameworkMarkers.swift"
  "$ROOT/Sources/FTCore/AXFrameRescale.swift"
  Sources/InAppHTTPServer.swift
  Sources/InAppWebViewDOM.swift
  Sources/InAppSnapshot.swift
  Sources/InAppSettle.swift
  Sources/DisplayHeartbeat.swift
  Sources/InAppTapProbe.swift
  Sources/InAppBridge.swift
)

echo "→ [$TAG] swiftc(${#SWIFT_SOURCES[@]} sources)..."
# -wmo で全ソースを1オブジェクトに(-c 複数ソース+-o の制約回避)。
# -import-objc-header で InAppInput.h の C 関数(タッチ合成)を Swift から呼べるようにする。
xcrun --sdk "$SDKNAME" swiftc -c -wmo -parse-as-library -O \
  "${SWIFT_SOURCES[@]}" \
  -import-objc-header Sources/Bridging.h \
  -module-name FTInAppBridge \
  -target "$TARGET" -sdk "$SDK" \
  -o "$OBJ/ftinapp.o"

echo "→ [$TAG] clang(boot.m, InAppInput.m)..."
xcrun --sdk "$SDKNAME" clang -c -fobjc-arc Sources/boot.m \
  -isysroot "$SDK" -target "$TARGET" -o "$OBJ/boot.o"
xcrun --sdk "$SDKNAME" clang -c -fobjc-arc Sources/InAppInput.m \
  -isysroot "$SDK" -target "$TARGET" -o "$OBJ/InAppInput.o"

echo "→ [$TAG] link dylib..."
xcrun --sdk "$SDKNAME" clang -dynamiclib -o "$DYLIB" \
  "$OBJ/ftinapp.o" "$OBJ/boot.o" "$OBJ/InAppInput.o" \
  -isysroot "$SDK" -target "$TARGET" \
  -framework UIKit -framework Foundation -framework IOKit -framework WebKit

echo "✅ $DYLIB"

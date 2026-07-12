#!/bin/bash
# アプリ内常駐ブリッジ dylib のビルド(シミュレータ用)。
# Swift ソース(BridgeDTO を共有)+ ObjC 構成子を1つの自己完結 dylib にリンクする。
# 出力: InAppBridge/build/libFTInAppBridge.dylib
#
# 注入: SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<dylib> SIMCTL_CHILD_FT_PORT=<port> \
#         xcrun simctl launch <udid> <bundleID>
# シミュレータプロセスは SIP/hardened runtime 非適用のためリビルドなしで注入できる。
# 実機は不可(XCUITest ランナー経路を使う)。
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="build"
DYLIB="$OUT/libFTInAppBridge.dylib"
TARGET="arm64-apple-ios17.0-simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

mkdir -p "$OUT"

# 共有 DTO(唯一の定義元)+ in-app 実装をまとめて1モジュールにコンパイル
SWIFT_SOURCES=(
  "$ROOT/Sources/FTCore/BridgeDTO.swift"
  Sources/InAppHTTPServer.swift
  Sources/InAppSnapshot.swift
  Sources/InAppSettle.swift
  Sources/InAppBridge.swift
)

echo "→ swiftc(${#SWIFT_SOURCES[@]} sources)..."
# -wmo で全ソースを1オブジェクトに(-c 複数ソース+-o の制約回避)。
# -import-objc-header で InAppInput.h の C 関数(タッチ合成)を Swift から呼べるようにする。
xcrun --sdk iphonesimulator swiftc -c -wmo -parse-as-library -O \
  "${SWIFT_SOURCES[@]}" \
  -import-objc-header Sources/Bridging.h \
  -module-name FTInAppBridge \
  -target "$TARGET" -sdk "$SDK" \
  -o "$OUT/ftinapp.o"

echo "→ clang(boot.m, InAppInput.m)..."
xcrun --sdk iphonesimulator clang -c -fobjc-arc Sources/boot.m \
  -isysroot "$SDK" -target "$TARGET" -o "$OUT/boot.o"
xcrun --sdk iphonesimulator clang -c -fobjc-arc Sources/InAppInput.m \
  -isysroot "$SDK" -target "$TARGET" -o "$OUT/InAppInput.o"

echo "→ link dylib..."
xcrun --sdk iphonesimulator clang -dynamiclib -o "$DYLIB" \
  "$OUT/ftinapp.o" "$OUT/boot.o" "$OUT/InAppInput.o" \
  -isysroot "$SDK" -target "$TARGET" \
  -framework UIKit -framework Foundation

echo "✅ $DYLIB"

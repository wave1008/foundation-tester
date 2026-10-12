#!/usr/bin/env bash
#
# fleetest 自身の E2E を**実機**で回す(仮想デバイスのスイートは Scripts/e2e.sh)。
# 各 SUT の実機用プロファイルを --broadcast で流す = 同じシナリオを**全実機で1回ずつ**回し、機種の差
# (画面の高さ・性能・ホームボタンの有無)をシナリオ単位で並べる。分配はしない。
#
#   E2E-iOS     ios-device      iPhone SE3(この Mac)+ iPhone 13(M1Ultra)。XCUITest エンジン(実機は in-app 不可)
#   E2E-Android android-device  Pixel 4a + Pixel 3a(この Mac)
#   E2E-CMP / E2E-Flutter / E2E-RN  ios-device + android-device  同上(iOS は各 SUT の dist/ios-device の実機用アプリ)
# iPhone wave は個人の端末なので ios-device で無効のまま(有効にしない)。
#
# 使い方:
#   Scripts/e2e-devices.sh              # 全部(iOS 実機 2 台 × 4 SUT + Android 実機 2 台 × 4 SUT)
#   Scripts/e2e-devices.sh --ios        # OS を絞る(--android も同様)
#   Scripts/e2e-devices.sh --cmp        # SUT を絞る(--ios-native / --android-native / --flutter / --rn も同様。併記可)
#   Scripts/e2e-devices.sh --local      # この Mac の実機だけ(M1Ultra の iPhone 13 を外す)
#   Scripts/e2e-devices.sh --rebuild    # 実機用の SUT を必ずビルドし直す
#
# 前提: 実機がつながっていてロックが解除されていること(iOS は「このコンピュータを信頼」・Developer Mode・
# 証明書の信頼)。iPhone 13 は M1Ultra につながっているので、M1Ultra がこの clone と同じコミットでないと
# 適合チェックで落ちる(揃えるのは Scripts/align.sh。ここでは揃えない = push を伴うので指示があるときだけ)。
# 陽性対照(e2e-negative.sh)と、エンジンの検証済みの印(.fleetest/*-e2e-verified)には触らない
# —— 実機のスイートは利用者の既定エンジン(hybrid)の経路を通らないので、その印の根拠にならない。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FLEETEST="$ROOT/.build/debug/fleetest"

FORCE_REBUILD=0
RUN_IOS=1
RUN_ANDROID=1
LOCAL_ONLY=0
SUTS=""
for arg in "$@"; do
  case "$arg" in
    --rebuild) FORCE_REBUILD=1 ;;
    --ios) RUN_ANDROID=0 ;;
    --android) RUN_IOS=0 ;;
    --local) LOCAL_ONLY=1 ;;
    --cmp|--ios-native|--android-native|--flutter|--rn) SUTS="$SUTS ${arg#--}" ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done
[ -n "$SUTS" ] || SUTS="ios-native android-native cmp flutter rn"

[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST がありません(swift build --product fleetest)" >&2; exit 1; }

# shellcheck source=crash-dialog.sh
. "$ROOT/Scripts/crash-dialog.sh"
trap 'crash_dialog_restore' EXIT
trap 'crash_dialog_restore; exit 130' INT TERM HUP
crash_dialog_suppress

# ソースが成果物より新しいか(成果物が無い場合も真)。e2e.sh と同じ規則
needs_rebuild() {  # $1 = 成果物パス, $2.. = 監視するソースディレクトリ
  local artifact="$1"; shift
  [ "$FORCE_REBUILD" = 1 ] && return 0
  [ -e "$artifact" ] || return 0
  [ -n "$(find "$@" -type f -newer "$artifact" 2>/dev/null | head -1)" ]
}

FAILED=0
SUMMARY=""
run_devices() {  # $1 = プロジェクト名, $2 = プロファイル名
  echo ""
  echo "═══ $1 / $2(実機・--broadcast)═══"
  local runner_flag=""
  [ "$LOCAL_ONLY" = 1 ] && runner_flag="--runner local"
  if "$FLEETEST" run --project "$1" --profile "$2" --broadcast $runner_flag; then
    echo "✅ $1 / $2"
    SUMMARY="${SUMMARY}✅ $1 / $2
"
  else
    echo "❌ $1 / $2"
    SUMMARY="${SUMMARY}❌ $1 / $2
"
    FAILED=1
  fi
}

for sut in $SUTS; do
  case "$sut" in
    ios-native)
      [ "$RUN_IOS" = 1 ] || continue
      APP="$ROOT/E2EAppIOS"
      if needs_rebuild "$APP/dist/ios-device/FTE2EIOS.app" "$APP/Sources"; then
        echo "→ SUT ios-native(実機用)をビルドし直します..."; "$APP/scripts/build-ios-device.sh"
      fi
      run_devices E2E-iOS ios-device
      ;;
    android-native)
      [ "$RUN_ANDROID" = 1 ] || continue
      APP="$ROOT/E2EAppAndroid"
      if needs_rebuild "$APP/dist/android/ft-e2e-android-debug.apk" "$APP/app/src"; then
        echo "→ SUT android-native をビルドし直します..."; "$APP/scripts/build-android.sh"
      fi
      run_devices E2E-Android android-device
      ;;
    cmp)
      APP="$ROOT/E2EAppCMP"
      if [ "$RUN_IOS" = 1 ]; then
        if needs_rebuild "$APP/dist/ios-device/FTE2E.app" "$APP/composeApp/src" "$APP/iosApp/iosApp"; then
          echo "→ SUT cmp(iOS 実機用)をビルドし直します..."; "$APP/scripts/build-ios-device.sh"
        fi
        run_devices E2E-CMP ios-device
      fi
      [ "$RUN_ANDROID" = 1 ] || continue
      if needs_rebuild "$APP/dist/android/ft-e2e-debug.apk" "$APP/composeApp/src"; then
        echo "→ SUT cmp(Android)をビルドし直します..."; "$APP/scripts/build-android.sh"
      fi
      run_devices E2E-CMP android-device
      ;;
    flutter)
      APP="$ROOT/E2EAppFlutter"
      if [ "$RUN_IOS" = 1 ]; then
        if needs_rebuild "$APP/dist/ios-device/FTE2EFlutter.app" "$APP/lib" "$APP/ios/Runner"; then
          echo "→ SUT flutter(iOS 実機用)をビルドし直します..."; "$APP/scripts/build-ios-device.sh"
        fi
        run_devices E2E-Flutter ios-device
      fi
      [ "$RUN_ANDROID" = 1 ] || continue
      if needs_rebuild "$APP/dist/android/ft-e2e-flutter-debug.apk" "$APP/lib" "$APP/android/app"; then
        echo "→ SUT flutter(Android)をビルドし直します..."; "$APP/scripts/build-android.sh"
      fi
      run_devices E2E-Flutter android-device
      ;;
    rn)
      APP="$ROOT/E2EAppRN"
      if [ "$RUN_IOS" = 1 ]; then
        if needs_rebuild "$APP/dist/ios-device/FTE2ERN.app" "$APP/src" "$APP/App.tsx" "$APP/index.js" "$APP/ios/FTE2ERN"; then
          echo "→ SUT rn(iOS 実機用)をビルドし直します..."; "$APP/scripts/build-ios-device.sh"
        fi
        run_devices E2E-RN ios-device
      fi
      [ "$RUN_ANDROID" = 1 ] || continue
      # 監視対象に android/app を丸ごと入れない(ビルド出力が混ざり毎回ビルドし直しになる。e2e.sh と同じ)
      if needs_rebuild "$APP/dist/android/ft-e2e-rn-release.apk" "$APP/src" "$APP/App.tsx" "$APP/index.js" "$APP/android/app/src"; then
        echo "→ SUT rn(Android)をビルドし直します..."; "$APP/scripts/build-android.sh"
      fi
      run_devices E2E-RN android-device
      ;;
  esac
done

echo ""
printf '%s' "$SUMMARY"
if [ "$FAILED" = 0 ]; then
  echo "✅ 実機の E2E 全て成功"
else
  echo "❌ 実機の E2E に失敗があります(レポート: TestProjects/*/reports/。結果 JSON の worker で機種を区別)"
fi
exit "$FAILED"

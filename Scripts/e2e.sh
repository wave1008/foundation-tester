#!/usr/bin/env bash
#
# ftester 自身の E2E を全 SUT で回す。
#
# SUT は UI フレームワークごとに4つある(どれも画面・#id・ラベルは同じ契約。
# 唯一の正は E2EApp/docs/ui-contract.md、各 SUT の差分は <SUT>/docs/ui-contract.md):
#   cmp            E2EApp/         Compose Multiplatform   → Projects/E2E         (ios + android)
#   ios-native     E2EAppIOS/      SwiftUI + UIKit         → Projects/E2E-iOS     (ios のみ)
#   android-native E2EAppAndroid/  View/XML + 一部 Compose → Projects/E2E-Android (android のみ)
#   flutter        E2EAppFlutter/  Flutter                 → Projects/E2E-Flutter (ios + android)
#
# 使い方:
#   Scripts/e2e.sh                 # 全 SUT・全プロファイル(鮮度を見て必要なら SUT を再ビルド)
#   Scripts/e2e.sh --cmp           # SUT を絞る(--ios-native / --android-native / --flutter も同様。併記可)
#   Scripts/e2e.sh --ios           # OS を絞る(--android も同様)
#   Scripts/e2e.sh --rebuild       # SUT を必ず再ビルドしてから実行
#
# **両OSを1つの実行プロファイルにまとめない**: platform 未指定シナリオは既定 platform の
# キューにしか入らず、もう一方のワーカーは1本も受け取らない(docs/design.md §11.4)。
# だから ios と android を別々に回す。ここが「all プロファイルを置かない」理由でもある。
#
# SUT の再ビルドが要る条件: ソースが dist の成果物より新しいとき。ソースを変えたのに
# 再ビルドを忘れると、古いアプリに新しいシナリオを当てて謎の失敗になる。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FTESTER="$ROOT/.build/debug/ftester"

FORCE_REBUILD=0
RUN_IOS=1
RUN_ANDROID=1
SUTS=""

for arg in "$@"; do
  case "$arg" in
    --rebuild) FORCE_REBUILD=1 ;;
    --ios) RUN_ANDROID=0 ;;
    --android) RUN_IOS=0 ;;
    --cmp|--ios-native|--android-native|--flutter) SUTS="$SUTS ${arg#--}" ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done
[ -n "$SUTS" ] || SUTS="cmp ios-native android-native flutter"

[ -x "$FTESTER" ] || { echo "❌ $FTESTER がありません(swift build --product ftester)" >&2; exit 1; }

# ソースが成果物より新しいか(成果物が無い場合も真)
needs_rebuild() {  # $1 = 成果物パス, $2.. = 監視するソースディレクトリ
  local artifact="$1"; shift
  [ "$FORCE_REBUILD" = 1 ] && return 0
  [ -e "$artifact" ] || return 0
  [ -n "$(find "$@" -type f -newer "$artifact" 2>/dev/null | head -1)" ]
}

FAILED=0
run_profile() {  # $1 = プロジェクト名, $2 = プロファイル名
  echo ""
  echo "═══ $1 / $2 ═══"
  if "$FTESTER" run --project "$1" --profile "$2"; then
    echo "✅ $1 / $2"
  else
    echo "❌ $1 / $2"
    FAILED=1
  fi
}

for sut in $SUTS; do
  case "$sut" in
    cmp)
      APP="$ROOT/E2EApp"
      if [ "$RUN_IOS" = 1 ] && needs_rebuild "$APP/dist/ios-simulator/FTE2E.app" "$APP/composeApp/src" "$APP/iosApp"; then
        echo "→ SUT cmp(iOS)を再ビルドします..."; "$APP/scripts/build-ios.sh"
      fi
      if [ "$RUN_ANDROID" = 1 ] && needs_rebuild "$APP/dist/android/ft-e2e-debug.apk" "$APP/composeApp/src"; then
        echo "→ SUT cmp(Android)を再ビルドします..."; "$APP/scripts/build-android.sh"
      fi
      [ "$RUN_IOS" = 1 ] && run_profile E2E ios-xcuitest
      [ "$RUN_ANDROID" = 1 ] && run_profile E2E android
      ;;
    ios-native)
      [ "$RUN_IOS" = 1 ] || continue
      APP="$ROOT/E2EAppIOS"
      if needs_rebuild "$APP/dist/ios-simulator/FTE2EIOS.app" "$APP/Sources"; then
        echo "→ SUT ios-native を再ビルドします..."; "$APP/scripts/build-ios.sh"
      fi
      run_profile E2E-iOS ios-xcuitest
      ;;
    android-native)
      [ "$RUN_ANDROID" = 1 ] || continue
      APP="$ROOT/E2EAppAndroid"
      if needs_rebuild "$APP/dist/android/ft-e2e-android-debug.apk" "$APP/app/src"; then
        echo "→ SUT android-native を再ビルドします..."; "$APP/scripts/build-android.sh"
      fi
      run_profile E2E-Android android
      ;;
    flutter)
      APP="$ROOT/E2EAppFlutter"
      if [ "$RUN_IOS" = 1 ] && needs_rebuild "$APP/dist/ios-simulator/FTE2EFlutter.app" "$APP/lib" "$APP/ios/Runner"; then
        echo "→ SUT flutter(iOS)を再ビルドします..."; "$APP/scripts/build-ios.sh"
      fi
      if [ "$RUN_ANDROID" = 1 ] && needs_rebuild "$APP/dist/android/ft-e2e-flutter-debug.apk" "$APP/lib" "$APP/android/app"; then
        echo "→ SUT flutter(Android)を再ビルドします..."; "$APP/scripts/build-android.sh"
      fi
      [ "$RUN_IOS" = 1 ] && run_profile E2E-Flutter ios-xcuitest
      [ "$RUN_ANDROID" = 1 ] && run_profile E2E-Flutter android
      ;;
  esac
done

echo ""
if [ "$FAILED" = 0 ]; then
  echo "✅ E2E 全て成功"
else
  echo "❌ E2E に失敗があります(レポート: Projects/*/reports/)"
fi
exit "$FAILED"

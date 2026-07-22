#!/usr/bin/env bash
#
# ftester 自身の E2E(Projects/E2E)を両OSで回す。
#
# 使い方:
#   Scripts/e2e.sh              # SUT の鮮度を確認 → ios-xcuitest → android を順に実行
#   Scripts/e2e.sh --rebuild    # SUT を必ず再ビルドしてから実行
#   Scripts/e2e.sh --ios        # iOS だけ / --android で Android だけ
#
# **両OSを1つの実行プロファイルにまとめない**: platform 未指定シナリオは既定 platform の
# キューにしか入らず、もう一方のワーカーは1本も受け取らない(docs/design.md §11.4)。
# だから ios と android を別々に回す。ここが「all プロファイルを置かない」理由でもある。
#
# SUT(E2EApp)の再ビルドが要る条件: composeApp/iosApp のソースが dist の成果物より新しいとき。
# ソースを変えたのに再ビルドを忘れると、古いアプリに対して新しいシナリオを当てて謎の失敗になる。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/E2EApp"
IOS_APP="$APP/dist/ios-simulator/FTE2E.app"
ANDROID_APK="$APP/dist/android/ft-e2e-debug.apk"
FTESTER="$ROOT/.build/debug/ftester"

FORCE_REBUILD=0
RUN_IOS=1
RUN_ANDROID=1
for arg in "$@"; do
  case "$arg" in
    --rebuild) FORCE_REBUILD=1 ;;
    --ios) RUN_ANDROID=0 ;;
    --android) RUN_IOS=0 ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done

[ -x "$FTESTER" ] || { echo "❌ $FTESTER がありません(swift build --product ftester)" >&2; exit 1; }

# SUT ソースが成果物より新しいか(find -newer は成果物が無い場合も真になるよう分岐)
needs_rebuild() {  # $1 = 成果物パス
  [ "$FORCE_REBUILD" = 1 ] && return 0
  [ -e "$1" ] || return 0
  [ -n "$(find "$APP/composeApp/src" "$APP/iosApp" -type f -newer "$1" 2>/dev/null | head -1)" ]
}

if [ "$RUN_IOS" = 1 ] && needs_rebuild "$IOS_APP"; then
  echo "→ SUT(iOS)を再ビルドします..."
  "$APP/scripts/build-ios.sh"
fi
if [ "$RUN_ANDROID" = 1 ] && needs_rebuild "$ANDROID_APK"; then
  echo "→ SUT(Android)を再ビルドします..."
  "$APP/scripts/build-android.sh"
fi

FAILED=0
run_profile() {  # $1 = プロファイル名
  echo ""
  echo "═══ $1 ═══"
  if "$FTESTER" run --project E2E --profile "$1"; then
    echo "✅ $1"
  else
    echo "❌ $1"
    FAILED=1
  fi
}

[ "$RUN_IOS" = 1 ] && run_profile ios-xcuitest
[ "$RUN_ANDROID" = 1 ] && run_profile android

echo ""
if [ "$FAILED" = 0 ]; then
  echo "✅ E2E 全て成功"
else
  echo "❌ E2E に失敗があります(レポート: Projects/E2E/reports/)"
fi
exit "$FAILED"

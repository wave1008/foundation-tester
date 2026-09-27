#!/usr/bin/env bash
#
# CMP 固有部品の E2E(E2EXAppCMP → TestProjects/E2EX-CMP)を回す。
# 共通契約の5 SUT は Scripts/e2e.sh。こちらは Material3 の定番部品(ページャ・ボトムシート・メニュー・
# 日付ピッカー・ドロワー・引っ張って更新・検索バー 等)だけを持つ SUT で、契約は E2EXAppCMP/docs/ui-contract.md。
#
# 使い方(オプションの意味は Scripts/e2e.sh に揃えてある):
#   Scripts/e2ex.sh                 # iOS(in-app = 利用者の既定エンジン hybrid)と Android
#   Scripts/e2ex.sh --ios-xcuitest  # **iOS だけ**を XCUITest エンジンで
#   Scripts/e2ex.sh --ios-inapp     # **iOS だけ**を in-app エンジンで(既定と同じ経路)
#   Scripts/e2ex.sh --ios           # OS を絞る(--android も同様)
#   Scripts/e2ex.sh --rebuild       # SUT を必ず再ビルドしてから実行
#
# **プロファイルは手元の3台だけ**なので常に `--runner local` で回す(同名のデバイスがリモートにもあり、
# --runner を付けないとリモートへ飛ぶ)。--align は持たない(リモートを使わない)。
# **iOS XCUITest の 90_不具合の回帰.swift S0020 は未修正で赤**(XCUITest は容器が「まだ送れるか」を
# 申告しないので、scrollToTop の端の確認が上端で「引っ張る」になる)。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FLEETEST="$ROOT/.build/debug/fleetest"
PROJECT="E2EX-CMP"
APP="$ROOT/E2EXAppCMP"

FORCE_REBUILD=0
RUN_IOS=1
RUN_ANDROID=1
IOS_ENGINE_ONLY=0
IOS_PROFILE="ios-inapp"

for arg in "$@"; do
  case "$arg" in
    --rebuild) FORCE_REBUILD=1 ;;
    --ios) RUN_ANDROID=0 ;;
    --android) RUN_IOS=0 ;;
    --ios-inapp) IOS_PROFILE="ios-inapp"; IOS_ENGINE_ONLY=1 ;;
    --ios-xcuitest) IOS_PROFILE="ios-xcuitest"; IOS_ENGINE_ONLY=1 ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done

# エンジンの指定は iOS だけを回す(Android にエンジンの選択肢は無い。理由は Scripts/e2e.sh の同じ箇所)
if [ "$IOS_ENGINE_ONLY" = 1 ] && [ "$RUN_IOS" = 0 ]; then
  echo "❌ --ios-inapp / --ios-xcuitest と --android は併記できません(前者は iOS だけを回します)" >&2
  exit 2
fi
if [ "$IOS_ENGINE_ONLY" = 1 ]; then
  RUN_ANDROID=0
fi

[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST がありません(swift build --product fleetest)" >&2; exit 1; }

# ソースが成果物より新しいか(成果物が無い場合も真)。Scripts/e2e.sh の needs_rebuild と同じ
needs_rebuild() {  # $1 = 成果物パス, $2.. = 監視するソース
  local artifact="$1"; shift
  [ "$FORCE_REBUILD" = 1 ] && return 0
  [ -e "$artifact" ] || return 0
  [ -n "$(find "$@" -type f -newer "$artifact" 2>/dev/null | head -1)" ]
}

FAILED=0

if [ "$RUN_IOS" = 1 ] && needs_rebuild "$APP/dist/ios-simulator/FTE2EX.app" \
    "$APP/composeApp/src" "$APP/iosApp/iosApp" "$APP/iosApp/project.yml" "$APP/composeApp/build.gradle.kts"; then
  echo "==> E2EXAppCMP(iOS Simulator)を再ビルドします"
  "$APP/scripts/build-ios.sh"
fi
if [ "$RUN_ANDROID" = 1 ] && needs_rebuild "$APP/dist/android/ft-e2ex-debug.apk" \
    "$APP/composeApp/src" "$APP/composeApp/build.gradle.kts"; then
  echo "==> E2EXAppCMP(Android)を再ビルドします"
  "$APP/scripts/build-android.sh"
fi

# ${RESULTS} と括る: bash 3.2 は $RESULTS の直後の絵文字の先頭バイトを変数名に含めて unbound で落ちる
RESULTS=""
run_profile() {  # $1 = プロファイル名
  echo ""
  echo "═══ $PROJECT / $1 ═══"
  if "$FLEETEST" run --project "$PROJECT" --profile "$1" --runner local; then
    RESULTS="${RESULTS}✅ $PROJECT / $1
"
  else
    RESULTS="${RESULTS}❌ $PROJECT / $1
"
    FAILED=1
  fi
}

if [ "$RUN_IOS" = 1 ]; then
  run_profile "$IOS_PROFILE"
fi
if [ "$RUN_ANDROID" = 1 ]; then
  run_profile "android"
fi

echo ""
printf '%s' "$RESULTS"
if [ "$FAILED" = 0 ]; then
  echo "✅ E2EX 全て成功"
else
  echo "❌ E2EX に失敗があります(レポート: TestProjects/$PROJECT/reports/)"
fi
exit "$FAILED"

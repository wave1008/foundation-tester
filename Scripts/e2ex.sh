#!/usr/bin/env bash
#
# 固有部品の E2E(E2EX)を回す。共通契約の5 SUT は Scripts/e2e.sh。こちらは各フレームワークの
# **定番部品**(ページャ・ボトムシート・メニュー・日付/時刻ピッカー・ドロワー・引っ張って更新・検索バー・
# 伸縮するヘッダ・並べ替え 等)を持つ SUT で、画面・#id・echo の契約は E2EXAppCMP/docs/ui-contract.md と
# ui-contract-wave2.md(各 SUT の差分は <SUT>/docs/ui-contract.md):
#   cmp            E2EXAppCMP/      Compose Multiplatform → TestProjects/E2EX-CMP     (ios + android)
#   flutter        E2EXAppFlutter/  Flutter               → TestProjects/E2EX-Flutter (ios + android)
#   rn             E2EXAppRN/       React Native          → TestProjects/E2EX-RN      (ios + android)
#   android-native E2EXAppAndroid/  View/XML + Material   → TestProjects/E2EX-Android (android のみ)
#   ios-native     E2EXAppIOS/      SwiftUI(+UIKit)       → TestProjects/E2EX-iOS     (ios のみ)
#
# 使い方(オプションの意味は Scripts/e2e.sh に揃えてある):
#   Scripts/e2ex.sh                 # 全 SUT。iOS は in-app(利用者の既定エンジン hybrid)と Android
#   Scripts/e2ex.sh --cmp           # SUT を絞る(--flutter / --rn / --android-native / --ios-native も同様。併記可)
#   Scripts/e2ex.sh --ios-xcuitest  # **iOS だけ**を XCUITest エンジンで(--ios-inapp も同様)
#   Scripts/e2ex.sh --ios           # OS を絞る(--android も同様)
#   Scripts/e2ex.sh --rebuild       # SUT を必ず再ビルドしてから実行
#   Scripts/e2ex.sh --on M1Ultra    # **丸ごとその機械で回す**(ssh でランナーのクローンに入り、そこで SUT を建てて
#                                   # そこのデバイスで実行する。残りの引数はそのまま向こうへ渡す)。向こうで動くのは
#                                   # align 済みのコミット + そこの clone の中身なので、ツールを直したら
#                                   # commit → Scripts/align.sh → これ、の順。E2E をこの Mac(`e2e.sh --local`)で
#                                   # 回しながら E2EX を M1Ultra で回すのが既定の分担(ユーザー指示 2026-09-28)。
#                                   # 向こうに要る道具(xcodegen / Flutter / CocoaPods / node)は ~/.zshrc の
#                                   # fleetest-tools ブロックの PATH にある
#
# **プロファイルは -01〜-08 の8台を名前で指す(udid を持たない)**ので、同名のデバイスを持つどの機でも同じ
# プロファイルで回る。常に `--runner local`(同名のデバイスがリモートにもあり、--runner を付けないと
# リモートへ飛ぶ)。--align は持たない(Scripts/align.sh を先に)。
# **`--ios-xcuitest` は既定エンジン(in-app)で緑のシナリオが 13 本赤のまま**(XCUITest エンジンだけの制約。
# 一覧は docs/framework-differences.md §5.1 末尾の「残っている制約」)。代表は 90_不具合の回帰.swift S0020
# (XCUITest は容器が「まだ送れるか」を申告しないので、scrollToTop の端の確認が上端で「引っ張る」になる)。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FLEETEST="$ROOT/.build/debug/fleetest"

FORCE_REBUILD=0
RUN_IOS=1
RUN_ANDROID=1
IOS_ENGINE_ONLY=0
IOS_PROFILE="ios-inapp"
SUTS=""

[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST がありません(swift build --product fleetest)" >&2; exit 1; }

# --on <機械名>: 残りの引数ごと向こうの e2ex.sh へ渡して、その出力をそのまま流す
if [ "${1:-}" = "--on" ]; then
  MACHINE="${2:-}"
  [ -n "$MACHINE" ] || { echo "❌ --on には機械名が要ります(fleetest remote machines)" >&2; exit 2; }
  shift 2
  HOST=$("$FLEETEST" api remote-machines | python3 -c '
import json,sys
m=sys.argv[1]
for h in json.load(sys.stdin).get("hosts", []):
    if h.get("machine") == m: print(h["host"]); break' "$MACHINE")
  [ -n "$HOST" ] || { echo "❌ 登録簿に $MACHINE が無い(fleetest remote machines)" >&2; exit 2; }
  # ランナーのクローン(fleetest remote align が揃える場所)。dist/ は gitignore なので align で消えない
  REMOTE_CLONE="~/fleetest-runner/foundation-tester"
  echo "==> $MACHINE($HOST)で回す: Scripts/e2ex.sh $*"
  # ログイン shell(zsh -lc)で起こす = ~/.zshrc の PATH(fleetest-tools)と非対話 ssh の PATH 補正を兼ねる
  exec ssh -tt -o BatchMode=yes "$HOST" "zsh -lc 'cd $REMOTE_CLONE && Scripts/e2ex.sh $*'"
fi

for arg in "$@"; do
  case "$arg" in
    --rebuild) FORCE_REBUILD=1 ;;
    --ios) RUN_ANDROID=0 ;;
    --android) RUN_IOS=0 ;;
    --ios-inapp) IOS_PROFILE="ios-inapp"; IOS_ENGINE_ONLY=1 ;;
    --ios-xcuitest) IOS_PROFILE="ios-xcuitest"; IOS_ENGINE_ONLY=1 ;;
    --cmp|--flutter|--rn|--android-native|--ios-native) SUTS="$SUTS ${arg#--}" ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done
[ -n "$SUTS" ] || SUTS="cmp flutter rn android-native ios-native"

# エンジンの指定は iOS だけを回す(Android にエンジンの選択肢は無い。理由は Scripts/e2e.sh の同じ箇所)
if [ "$IOS_ENGINE_ONLY" = 1 ] && [ "$RUN_IOS" = 0 ]; then
  echo "❌ --ios-inapp / --ios-xcuitest と --android は併記できません(前者は iOS だけを回します)" >&2
  exit 2
fi
if [ "$IOS_ENGINE_ONLY" = 1 ]; then
  RUN_ANDROID=0
fi


# ソースが成果物より新しいか(成果物が無い場合も真)。Scripts/e2e.sh の needs_rebuild と同じ
needs_rebuild() {  # $1 = 成果物パス, $2.. = 監視するソース
  local artifact="$1"; shift
  [ "$FORCE_REBUILD" = 1 ] && return 0
  [ -e "$artifact" ] || return 0
  [ -n "$(find "$@" -type f -newer "$artifact" 2>/dev/null | head -1)" ]
}

FAILED=0
# ${RESULTS} と括る: bash 3.2 は $RESULTS の直後の絵文字の先頭バイトを変数名に含めて unbound で落ちる
RESULTS=""
run_profile() {  # $1 = プロジェクト名, $2 = プロファイル名
  echo ""
  echo "═══ $1 / $2 ═══"
  if "$FLEETEST" run --project "$1" --profile "$2" --runner local; then
    RESULTS="${RESULTS}✅ $1 / $2
"
  else
    RESULTS="${RESULTS}❌ $1 / $2
"
    FAILED=1
  fi
}

# $1 = SUT ディレクトリ, $2 = プロジェクト, $3 = iOS 成果物(空 = iOS 無し), $4 = Android 成果物(空 = Android 無し),
# $5 = iOS の監視ソース(空白区切り), $6 = Android の監視ソース(空白区切り)
run_sut() {
  local app="$ROOT/$1" project="$2" ios_art="$3" android_art="$4"
  local ios_src="" android_src="" s
  for s in $5; do ios_src="$ios_src $app/$s"; done
  for s in $6; do android_src="$android_src $app/$s"; done
  # 監視ソースの一覧は空白を含まない固定の語なので、未クォートの展開で語に分ける
  if [ "$RUN_IOS" = 1 ] && [ -n "$ios_art" ] && needs_rebuild "$app/$ios_art" $ios_src; then
    echo "==> $1(iOS Simulator)を再ビルドします"
    "$app/scripts/build-ios.sh"
  fi
  if [ "$RUN_ANDROID" = 1 ] && [ -n "$android_art" ] && needs_rebuild "$app/$android_art" $android_src; then
    echo "==> $1(Android)を再ビルドします"
    "$app/scripts/build-android.sh"
  fi
  if [ "$RUN_IOS" = 1 ] && [ -n "$ios_art" ]; then
    run_profile "$project" "$IOS_PROFILE"
  fi
  if [ "$RUN_ANDROID" = 1 ] && [ -n "$android_art" ]; then
    run_profile "$project" "android"
  fi
}

for sut in $SUTS; do
  case "$sut" in
    cmp)
      run_sut E2EXAppCMP E2EX-CMP dist/ios-simulator/FTE2EX.app dist/android/ft-e2ex-debug.apk \
        "composeApp/src iosApp/iosApp iosApp/project.yml composeApp/build.gradle.kts" \
        "composeApp/src composeApp/build.gradle.kts" ;;
    flutter)
      run_sut E2EXAppFlutter E2EX-Flutter dist/ios-simulator/FTE2EXFlutter.app dist/android/ft-e2ex-flutter-debug.apk \
        "lib ios/Runner pubspec.yaml" "lib android/app pubspec.yaml" ;;
    rn)
      run_sut E2EXAppRN E2EX-RN dist/ios-simulator/FTE2EXRN.app dist/android/ft-e2ex-rn-release.apk \
        "src App.tsx index.js package.json ios/FTE2EXRN" "src App.tsx index.js package.json android/app/src" ;;
    android-native)
      run_sut E2EXAppAndroid E2EX-Android "" dist/android/ft-e2ex-android-debug.apk "" "app/src app/build.gradle.kts" ;;
    ios-native)
      run_sut E2EXAppIOS E2EX-iOS dist/ios-simulator/FTE2EXIOS.app "" "Sources project.yml" "" ;;
  esac
done

echo ""
printf '%s' "$RESULTS"
if [ "$FAILED" = 0 ]; then
  echo "✅ E2EX 全て成功"
else
  echo "❌ E2EX に失敗があります(レポート: TestProjects/E2EX-*/reports/)"
fi
exit "$FAILED"

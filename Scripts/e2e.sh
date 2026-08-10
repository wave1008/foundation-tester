#!/usr/bin/env bash
#
# ftester 自身の E2E を全 SUT で回す。
#
# SUT は UI フレームワークごとに5つある(どれも画面・#id・ラベルは同じ契約。
# 唯一の正は E2EAppCMP/docs/ui-contract.md、各 SUT の差分は <SUT>/docs/ui-contract.md):
#   cmp            E2EAppCMP/      Compose Multiplatform   → TestProjects/E2E-CMP     (ios + android)
#   ios-native     E2EAppIOS/      SwiftUI + UIKit         → TestProjects/E2E-iOS     (ios のみ)
#   android-native E2EAppAndroid/  View/XML + 一部 Compose → TestProjects/E2E-Android (android のみ)
#   flutter        E2EAppFlutter/  Flutter                 → TestProjects/E2E-Flutter (ios + android)
#   rn             E2EAppRN/       React Native            → TestProjects/E2E-RN      (ios + android)
#
# 使い方:
#   Scripts/e2e.sh                 # 全 SUT・全プロファイル(鮮度を見て必要なら SUT を再ビルド)。
#                                   # **iOS は in-app エンジン** = 利用者の既定(hybrid)の経路
#   Scripts/e2e.sh --cmp           # SUT を絞る(--ios-native / --android-native / --flutter / --rn も同様。併記可)
#   Scripts/e2e.sh --ios           # OS を絞る(--android も同様)
#   Scripts/e2e.sh --ios-xcuitest  # **iOS だけ**を XCUITest エンジン(ios-xcuitest プロファイル)で回す。
#                                   # **既定は in-app** —— 利用者の既定エンジンは hybrid
#                                   # (in-app 優先)なので、既定スイートが見るのはそちらの経路。
#                                   # XCUITest ブリッジ(ランナー・スナップショット・型写像)を
#                                   # 触ったらこれを追加で回す。
#                                   # **Android は回さない** —— Android にエンジンの選択肢は無く
#                                   # (iosInappEngine は iOS 専用)、既定スイートと1バイトも違わない実行を
#                                   # もう一度回すことになる(2026-08-11 実測で 244 秒の純粋な重複)。
#                                   # Android だけ回したいときは --android
#   Scripts/e2e.sh --ios-inapp     # **iOS だけ**を in-app エンジン(= 既定と同じ)で回す
#   Scripts/e2e.sh --rebuild       # SUT を必ず再ビルドしてから実行
#   Scripts/e2e.sh --record        # 各プロファイルの一時コピー(<名前>-record-tmp.json。実行後に削除)に
#                                   # record:true を付けて実行し、録画パイプラインの整合を
#                                   # Scripts/check-recordings.py で検証する(元のプロファイルは書き換えない)
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
RECORD=0
# エンジンを明示した(--ios-inapp / --ios-xcuitest)= iOS のエンジン検証が目的。Android は回さない
IOS_ENGINE_ONLY=0
SUTS=""
# iOS の実行プロファイル。**既定は in-app**(利用者の既定エンジン hybrid = in-app 優先に合わせる)。
# --ios-xcuitest で XCUITest 側へ切り替える(E2E-Android には iOS プロファイルが無い)
IOS_PROFILE="ios-inapp"

for arg in "$@"; do
  case "$arg" in
    --rebuild) FORCE_REBUILD=1 ;;
    --ios) RUN_ANDROID=0 ;;
    --android) RUN_IOS=0 ;;
    --ios-inapp) IOS_PROFILE="ios-inapp"; IOS_ENGINE_ONLY=1 ;;
    --ios-xcuitest) IOS_PROFILE="ios-xcuitest"; IOS_ENGINE_ONLY=1 ;;
    --record) RECORD=1 ;;
    --cmp|--ios-native|--android-native|--flutter|--rn) SUTS="$SUTS ${arg#--}" ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done
[ -n "$SUTS" ] || SUTS="cmp ios-native android-native flutter rn"

# **エンジンの指定は iOS だけを回す**。Android にエンジンの選択肢は無い(iosInappEngine は iOS 専用)ので、
# エンジンを明示した実行で Android まで回すと既定スイートと同一の実行を二度払うだけになる
# (2026-08-11 実測 244 秒)。Android だけ回したいときは --android
if [ "$IOS_ENGINE_ONLY" = 1 ] && [ "$RUN_IOS" = 1 ]; then
  RUN_ANDROID=0
fi
if [ "$IOS_ENGINE_ONLY" = 1 ] && [ "$RUN_IOS" = 0 ]; then
  echo "❌ --ios-inapp / --ios-xcuitest と --android は併記できません(前者は iOS だけを回します)" >&2
  exit 2
fi

[ -x "$FTESTER" ] || { echo "❌ $FTESTER がありません(swift build --product ftester)" >&2; exit 1; }
if [ "$RECORD" = 1 ]; then
  command -v jq >/dev/null || { echo "❌ --record には jq が必要です" >&2; exit 1; }
  command -v python3 >/dev/null || { echo "❌ --record には python3 が必要です" >&2; exit 1; }
fi

# ソースが成果物より新しいか(成果物が無い場合も真)
needs_rebuild() {  # $1 = 成果物パス, $2.. = 監視するソースディレクトリ
  local artifact="$1"; shift
  [ "$FORCE_REBUILD" = 1 ] && return 0
  [ -e "$artifact" ] || return 0
  [ -n "$(find "$@" -type f -newer "$artifact" 2>/dev/null | head -1)" ]
}

# **回さなかった側のエンジン**の入力が、最後にそれを全部通した状態から動いていないか。
# 1回の実行が見るのは iOS の2エンジンのうち片方だけなので、放っておくともう片方は
# 何回変えても1度も動かないまま緑になる(2026-08-09 に実際に起きた: スナップショット生成を
# in-app/xcuitest 両方変えた回の E2E 254 本が全部 engine=xcuitest だった)。
# **警告だけで落とさない** —— 検知は警告から始める、が本リポジトリの方針。
# 一覧の定義元は Sources/FTCore/BridgeSourceSet.swift(ここに二重に書かない)
engine_digest() { "$FTESTER" api bridge-sources --set "$1" --digest 2>/dev/null; }
engine_marker() { echo "$ROOT/.ftester/$1-e2e-verified"; }
# このスイートが回す iOS エンジンと、回さない側
RUN_ENGINE=inapp; SKIP_ENGINE=xcuitest
# **`[ … ] && { … }` の形にしない**(偽のとき終了ステータス 1 を残す。末尾の exit の項も参照)
if [ "$IOS_PROFILE" = "ios-xcuitest" ]; then RUN_ENGINE=xcuitest; SKIP_ENGINE=inapp; fi
ENGINE_STALE=""
if [ "$RUN_IOS" = 1 ]; then
  CURRENT_DIGEST="$(engine_digest "$SKIP_ENGINE")"
  if [ -n "$CURRENT_DIGEST" ] && [ "$CURRENT_DIGEST" != "$(cat "$(engine_marker "$SKIP_ENGINE")" 2>/dev/null)" ]; then
    ENGINE_STALE=1
    echo "⚠️ $SKIP_ENGINE ブリッジの入力が、最後にそれを通した状態から変わっています。"
    echo "   この実行は iOS を $RUN_ENGINE でしか回さないので、$SKIP_ENGINE 経路は検証されません。"
    echo "   → Scripts/e2e.sh --ios-$SKIP_ENGINE を回してください(1 SUT だけでも可)"
  fi
fi

FAILED=0
run_profile() {  # $1 = プロジェクト名, $2 = プロファイル名
  echo ""
  echo "═══ $1 / $2 ═══"

  local profile="$2"
  local tmp_profile_path=""
  if [ "$RECORD" = 1 ]; then
    local src_path="$ROOT/TestProjects/$1/profiles/runs/$2.json"
    if [ -f "$src_path" ]; then
      profile="$2-record-tmp"
      tmp_profile_path="$ROOT/TestProjects/$1/profiles/runs/$profile.json"
      # 元のプロファイルは書き換えず、record:true を足した一時コピーを作る
      jq '. + {record: true}' "$src_path" > "$tmp_profile_path"
    else
      echo "⚠️ プロファイルが見つからないため --record をスキップします: $src_path" >&2
    fi
  fi

  if "$FTESTER" run --project "$1" --profile "$profile"; then
    echo "✅ $1 / $profile"
  else
    echo "❌ $1 / $profile"
    FAILED=1
  fi

  if [ -n "$tmp_profile_path" ]; then
    rm -f "$tmp_profile_path"
    # run の成否に関わらず録画自体は行われているはずなので整合チェックする
    if ! python3 "$ROOT/Scripts/check-recordings.py" --project "$1" --repo-root "$ROOT"; then
      echo "❌ $1 / $profile: 録画整合チェックに失敗しました"
      FAILED=1
    fi
  fi
}

for sut in $SUTS; do
  case "$sut" in
    cmp)
      APP="$ROOT/E2EAppCMP"
      if [ "$RUN_IOS" = 1 ] && needs_rebuild "$APP/dist/ios-simulator/FTE2E.app" "$APP/composeApp/src" "$APP/iosApp"; then
        echo "→ SUT cmp(iOS)を再ビルドします..."; "$APP/scripts/build-ios.sh"
      fi
      if [ "$RUN_ANDROID" = 1 ] && needs_rebuild "$APP/dist/android/ft-e2e-debug.apk" "$APP/composeApp/src"; then
        echo "→ SUT cmp(Android)を再ビルドします..."; "$APP/scripts/build-android.sh"
      fi
      [ "$RUN_IOS" = 1 ] && run_profile E2E-CMP "$IOS_PROFILE"
      [ "$RUN_ANDROID" = 1 ] && run_profile E2E-CMP android
      ;;
    ios-native)
      [ "$RUN_IOS" = 1 ] || continue
      APP="$ROOT/E2EAppIOS"
      if needs_rebuild "$APP/dist/ios-simulator/FTE2EIOS.app" "$APP/Sources"; then
        echo "→ SUT ios-native を再ビルドします..."; "$APP/scripts/build-ios.sh"
      fi
      run_profile E2E-iOS "$IOS_PROFILE"
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
      [ "$RUN_IOS" = 1 ] && run_profile E2E-Flutter "$IOS_PROFILE"
      [ "$RUN_ANDROID" = 1 ] && run_profile E2E-Flutter android
      ;;
    rn)
      APP="$ROOT/E2EAppRN"
      # 監視対象に android/app や ios/ を丸ごと入れない(ビルド出力・Pods が混ざり毎回再ビルドになる)
      if [ "$RUN_IOS" = 1 ] && needs_rebuild "$APP/dist/ios-simulator/FTE2ERN.app" "$APP/src" "$APP/App.tsx" "$APP/index.js" "$APP/ios/FTE2ERN"; then
        echo "→ SUT rn(iOS)を再ビルドします..."; "$APP/scripts/build-ios.sh"
      fi
      if [ "$RUN_ANDROID" = 1 ] && needs_rebuild "$APP/dist/android/ft-e2e-rn-release.apk" "$APP/src" "$APP/App.tsx" "$APP/index.js" "$APP/android/app/src"; then
        echo "→ SUT rn(Android)を再ビルドします..."; "$APP/scripts/build-android.sh"
      fi
      [ "$RUN_IOS" = 1 ] && run_profile E2E-RN "$IOS_PROFILE"
      [ "$RUN_ANDROID" = 1 ] && run_profile E2E-RN android
      ;;
  esac
done

echo ""
if [ "$FAILED" = 0 ]; then
  echo "✅ E2E 全て成功"
else
  echo "❌ E2E に失敗があります(レポート: TestProjects/*/reports/)"
fi

# **通した状態を覚えるのは全部成功したときだけ** —— 失敗したまま印を更新すると、
# 次回から「検証済み」と言い張る装置になる
if [ "$FAILED" = 0 ] && [ "$RUN_IOS" = 1 ]; then
  MARKER="$(engine_marker "$RUN_ENGINE")"
  mkdir -p "$(dirname "$MARKER")"
  engine_digest "$RUN_ENGINE" > "$MARKER"
  echo "→ $RUN_ENGINE 経路を検証済みとして記録しました($MARKER)"
fi
# 最後にもう一度言う: 冒頭の1行は数分のログに流されて読まれない。
# **`[ … ] && echo` の形にしない** —— 偽のとき終了ステータス 1 を残すので、
# 直後の `exit "$FAILED"` を誰かが消した瞬間に「成功したのに失敗扱い」へ化ける
if [ -n "$ENGINE_STALE" ]; then
  echo "⚠️ $SKIP_ENGINE 経路は未検証のままです(Scripts/e2e.sh --ios-$SKIP_ENGINE)"
fi

exit "$FAILED"

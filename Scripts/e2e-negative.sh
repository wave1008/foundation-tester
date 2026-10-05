#!/usr/bin/env bash
#
# 陽性対照(期待赤)スイート。緑の run では1度も通らない経路(検知・門・クラッシュの記録)を、
# _disabled/ の陽性対照で強制的に通し、**落ちた場所と理由まで**期待値と突き合わせる。
# 期待値は Scripts/negative-controls.json、判定は Scripts/negative_controls_judge.py。
# 最後に指紋照合(heal-verify.sh)と FM 経路(fm-verify.sh)の検証へ委ねる。
#
# 判定は3値: ✅ 期待どおり / ❌ 緑になった・別の場所や理由で落ちた / ⚠️ 未検証(FM が使えない・既知の見逃し)。
# **⚠️ は合否を変えない**が、何を確かめていないかを必ず出す。exit は ❌ が1つでもあれば 1。
#
# 使い方:
#   Scripts/e2e-negative.sh                  # 両 OS
#   Scripts/e2e-negative.sh --ios            # OS を絞る(--android も同様)
#   Scripts/e2e-negative.sh --project E2E-iOS   # プロジェクトを絞る(併記可)
#   Scripts/e2e-negative.sh --ios-device "<名前>" --android-device "<名前>"   # 台を変える
#
# 台は**各 OS で1台に固定**(既定 = 表の最初のプロファイルで有効な、この Mac の最初のデバイス)。
# 写真の権限アラートは台に残るので、同じ台で表の順に回す(順序の理由は表の _comment)。
# 常に --runner local(E2E のプロファイルは同名のデバイスがリモートにも並ぶ)。
# heal-verify.sh / fm-verify.sh と同時に回さない(どれも _disabled/ のシナリオを出し入れする)。
# E2E 実行中にこのスクリプトを回さない(シナリオのビルドが走る)。
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
# _disabled/ の出し入れで run ごとにシナリオの実行ファイルがビルドし直される = 毎回コールドの OCR モデルの
# コンパイル(35〜42 秒)を最初のシナリオの前に待たない(ScenarioHost.waitsForOCRModelCompile)
export FT_OCR_COMPILE_WAIT=off
FLEETEST="$ROOT/.build/debug/fleetest"
TABLE="$ROOT/Scripts/negative-controls.json"
RUN_IOS=1
RUN_ANDROID=1
PROJECTS=()
IOS_DEVICE=""
ANDROID_DEVICE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ios) RUN_ANDROID=0; shift ;;
    --android) RUN_IOS=0; shift ;;
    --project) PROJECTS+=("$2"); shift 2 ;;
    --ios-device) IOS_DEVICE="$2"; shift 2 ;;
    --android-device) ANDROID_DEVICE="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done

[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST がありません(swift build --product fleetest)" >&2; exit 1; }

# 回す対照の一覧: "<添字>\t<project>\t<file>\t<profile>\t<os>\t<class>\t<resetPhotos の bundle か ->"
SELECTED="$(RUN_IOS=$RUN_IOS RUN_ANDROID=$RUN_ANDROID PROJECTS="${PROJECTS[*]:-}" python3 - "$TABLE" <<'PY'
import json, os, sys
t = json.load(open(sys.argv[1]))["controls"]
projects = set(os.environ["PROJECTS"].split()) if os.environ["PROJECTS"] else None
for i, c in enumerate(t):
    if c["os"] == "ios" and os.environ["RUN_IOS"] != "1": continue
    if c["os"] == "android" and os.environ["RUN_ANDROID"] != "1": continue
    if projects and c["project"] not in projects: continue
    print("\t".join([str(i), c["project"], c["file"], c["profile"], c["os"], c["class"], c.get("resetPhotos", "-")]))
PY
)"
[ -n "$SELECTED" ] || { echo "回す陽性対照がありません(絞り込みを確かめる)" >&2; exit 2; }

# 既定の台 = その OS の対照が最初に使うプロファイルで有効な、machine=local の最初のデバイス
default_device() {  # $1 = os
  local first; first="$(printf '%s\n' "$SELECTED" | awk -F'\t' -v os="$1" '$5==os{print $2"\t"$4; exit}')"
  [ -n "$first" ] || return 0
  python3 - "$ROOT/TestProjects/${first%%$'\t'*}/profiles/runs/${first#*$'\t'}.json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["devices"]:
    if d.get("enabled", True) and d.get("machine", "local") == "local" and d.get("kind") != "physical":
        print(d["name"]); break
PY
}
[ "$RUN_IOS" = 1 ] && [ -z "$IOS_DEVICE" ] && IOS_DEVICE="$(default_device ios)"
[ "$RUN_ANDROID" = 1 ] && [ -z "$ANDROID_DEVICE" ] && ANDROID_DEVICE="$(default_device android)"

# 出したファイルを必ず _disabled/ へ戻す(途中で落ちても)
STAGED=()
restore() {
  local s p f d
  for s in "${STAGED[@]+"${STAGED[@]}"}"; do
    p="${s%%$'\t'*}"; f="${s#*$'\t'}"
    d="$ROOT/TestProjects/$p/scenarios"
    [ -f "$d/$f" ] && mv "$d/$f" "$d/_disabled/$f"
  done
  STAGED=()
  return 0
}
# クラッシュの対照が SUT を落とすたびに問題レポーターが出るので止める(e2e.sh から呼ばれても保持者の数で入れ子になる)
# shellcheck source=crash-dialog.sh
. "$ROOT/Scripts/crash-dialog.sh"
trap 'restore; crash_dialog_restore' EXIT
trap 'restore; crash_dialog_restore; exit 130' INT TERM HUP
crash_dialog_suppress

# アラートを閉じる補助シナリオ(表の photosAlertCleanup)。resetPhotos を持つ対照があるときだけ出す
CLEANUP="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["photosAlertCleanup"]; print("\t".join([c["project"], c["file"], c["profile"], c["class"]]))' "$TABLE")"
IFS=$'\t' read -r CLEANUP_PROJECT CLEANUP_FILE CLEANUP_PROFILE CLEANUP_CLASS <<< "$CLEANUP"
STAGE_LIST="$(printf '%s\n' "$SELECTED" | awk -F'\t' '{print $2"\t"$3}')"
if printf '%s\n' "$SELECTED" | awk -F'\t' '$7!="-"{f=1} END{exit !f}'; then
  STAGE_LIST="$STAGE_LIST"$'\n'"$CLEANUP_PROJECT"$'\t'"$CLEANUP_FILE"
fi

while IFS=$'\t' read -r p f; do
  d="$ROOT/TestProjects/$p/scenarios"
  [ -f "$d/$f" ] && continue   # 同じファイルを複数の対照が使う(OS 違い)
  [ -f "$d/_disabled/$f" ] || { echo "❌ $d/_disabled/$f がありません" >&2; exit 1; }
  mv "$d/_disabled/$f" "$d/$f"
  STAGED+=("$p"$'\t'"$f")
done <<< "$STAGE_LIST"

# 写真の権限アラートは OS が持ち、ボタンで答えるまで消えない(表の _comment)。
# 補助シナリオで「許可しない」を押して閉じ、権限を未決定へ戻す(次の要求でもアラートが出るように)
clear_photos_alert() {  # $1 = デバイス名, $2 = bundle
  local udid
  "$FLEETEST" run --project "$CLEANUP_PROJECT" --profile "$CLEANUP_PROFILE" --runner local --device "$1" \
    --scenario "$CLEANUP_CLASS" < /dev/null > /dev/null 2>&1 \
    || echo "⚠️ 写真の権限アラートを閉じられなかった($1。次の対照に持ち越しうる)" >&2
  udid="$(python3 - "$ROOT/TestProjects/$CLEANUP_PROJECT/profiles/runs/$CLEANUP_PROFILE.json" "$1" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["devices"]:
    if d["name"] == sys.argv[2] and d.get("machine", "local") == "local" and d.get("udid"):
        print(d["udid"]); break
PY
)"
  if [ -z "$udid" ]; then
    echo "⚠️ $1 の udid が $CLEANUP_PROFILE に無いので、写真の権限を未決定へ戻せない" >&2
    return 0
  fi
  xcrun simctl privacy "$udid" reset photos "$2" \
    || echo "⚠️ 写真の権限のリセットに失敗した($1 / $2)" >&2
}

list_runs() { find "$ROOT"/TestProjects/E2E-*/results/runs -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort; }
PLAN="$(mktemp -t e2e-negative-plan)"
SUMMARY="$(mktemp -t e2e-negative-summary)"

while IFS=$'\t' read -r idx p f prof os cls photos; do
  dev="$IOS_DEVICE"; [ "$os" = android ] && dev="$ANDROID_DEVICE"
  # 前にも打つ: 手で回した対照などが残したアラートから始めない
  [ "$photos" != "-" ] && clear_photos_alert "$dev" "$photos"
  echo ""
  echo "═══ 陽性対照: $p / $prof / $f($dev)═══"
  before="$(list_runs)"
  # 合否は問わない(落ちるのが正常)。結果は増えた run ディレクトリから読む
  "$FLEETEST" run --project "$p" --profile "$prof" --runner local --device "$dev" --scenario "$cls" < /dev/null || true
  printf '%s\t%s\n' "$idx" "$(comm -13 <(printf '%s\n' "$before") <(list_runs) | tail -1)" >> "$PLAN"
  [ "$photos" != "-" ] && clear_photos_alert "$dev" "$photos"
done <<< "$SELECTED"

restore

echo ""
echo "═══ 陽性対照の判定 ═══"
python3 "$ROOT/Scripts/negative_controls_judge.py" "$TABLE" "$PLAN" "$SUMMARY"
STATUS=$?

# 委ねる検証: 指紋照合(デバイスだけで決まる)/ FM 経路(FM が判定を返した回だけ意味がある)
covers() {  # $1 = project, $2 = os
  [ "$2" = ios ] && [ "$RUN_IOS" != 1 ] && return 1
  [ "${#PROJECTS[@]}" = 0 ] && return 0
  printf '%s\n' "${PROJECTS[@]}" | grep -qx "$1"
}
UNVERIFIED=()
if covers E2E-CMP ios; then
  echo ""
  "$ROOT/Scripts/heal-verify.sh" || STATUS=1
  FM_VERIFIED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("fmVerified"))' "$SUMMARY")"
  if [ "$FM_VERIFIED" = True ]; then
    echo ""
    "$ROOT/Scripts/fm-verify.sh" || STATUS=1
  else
    UNVERIFIED+=("Scripts/fm-verify.sh(遮蔽の反転で FM が判定を返さなかった = この機械の FM が使えない)")
  fi
fi
rm -f "$PLAN" "$SUMMARY"

for u in "${UNVERIFIED[@]+"${UNVERIFIED[@]}"}"; do echo "⚠️ 未検証: $u"; done
[ "$STATUS" = 0 ] && echo "✅ 陽性対照は期待どおりに落ちています(⚠️ は未検証)" || echo "❌ 陽性対照に期待と違うものがあります"
exit "$STATUS"

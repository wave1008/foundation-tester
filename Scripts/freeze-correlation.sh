#!/usr/bin/env bash
# iOS シミュレータの画面凍結が「同時に何台へ描画負荷をかけたか」に相関するかを測る対照実験。
#
# **なぜ要るか**: 凍結は 2026-08-08 と 2026-08-11 のフル E2E で、どちらも「多数台が同時に
# terminate → launch される瞬間」に集中して発生した。Android の表示凍結は「複数台同時描画」が
# トリガだと対照実験で確定済みだが、**iOS 側は同族仮説のまま**で、供給の同時実行上限
# (in-app 新規 launch は同時2台)もその仮説に基づいて置かれている。検知を厚くするより
# 発生させないほうが上流なので、条件を実測で確定させる。
#
# **測り方**: 同時起動台数(level)を変えて、その直後に凍結した台数を数える。
# 計測器は**モニター自身**(`fleetest api monitor` の NDJSON の frozen)を使う ——
# 判定を実験用に別実装すると本番と違うものを測ることになる(FrozenVerdict が唯一の定義元)。
#
# **交絡に注意**:
#   - 描画拍動の計器(DisplayHeartbeat)は条件間で必ず揃える(ブリッジの版を混ぜない)
#   - 直前のフル E2E の残熱で凍結しやすさが変わる。level の順序は毎ラウンド入れ替える
#   - 拡張のタイル配信が動いていると負荷が乗る。実験中は VSCode のモニターパネルを閉じる
#   - **この実験はフリートを揺さぶる**。他の run / 監視が動いていないことを確認してから走らせる
#
# 使い方:
#   Scripts/freeze-correlation.sh --project E2E-CMP --profile ios-inapp --levels 2,4,8 --rounds 3
#   Scripts/freeze-correlation.sh --project E2E-CMP --profile ios-inapp --levels 2 --rounds 1  # 煙試験
#
# 出力: 1行1試行の TSV(level round frozen total)+ level ごとの集計。
# 生ログは .fleetest/freeze-correlation-<日時>.log。
#
# bash 3.2(macOS 既定)で動くこと: mapfile / declare -A / tac は使わない。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROFILE="ios-inapp"
# --project は必須(モニターはプロジェクトが複数あると宛先を決められない)
PROJECT="E2E-CMP"
LEVELS="2,4,8"
ROUNDS=3
SETTLE_SECONDS=8
OBSERVE_SECONDS=10

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --levels) LEVELS="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --observe) OBSERVE_SECONDS="$2"; shift 2 ;;
    -h|--help) sed -n '1,28p' "$0"; exit 0 ;;
    *) echo "❌ 不明なオプション: $1" >&2; exit 2 ;;
  esac
done

FLEETEST="$REPO_ROOT/.build/debug/fleetest"
if [ ! -x "$FLEETEST" ]; then
  echo "❌ $FLEETEST がありません(先に swift build)" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$REPO_ROOT/.fleetest"
LOG="$REPO_ROOT/.fleetest/freeze-correlation-$STAMP.log"
TRIALS="$(mktemp)"
trap 'rm -f "$TRIALS"' EXIT

UDIDS=$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p')
TOTAL=$(printf '%s\n' "$UDIDS" | grep -c . || true)
if [ "${TOTAL:-0}" -eq 0 ]; then
  echo "❌ 起動中のシミュレータがありません" >&2
  exit 1
fi
echo "対象: $TOTAL 台 / project=$PROJECT / profile=$PROFILE / levels=$LEVELS / rounds=$ROUNDS" | tee -a "$LOG"

# level 台を「同時に」揺さぶる: 一斉 terminate → 一斉 launch(実測でトリガになった形)。
# 何を起こすかは重要ではなく、描画を一斉に走らせることが目的
shake() {
  level="$1"; i=0
  for udid in $UDIDS; do
    [ "$i" -ge "$level" ] && break
    ( xcrun simctl terminate "$udid" all >/dev/null 2>&1 ) &
    i=$((i + 1))
  done
  wait
  i=0
  for udid in $UDIDS; do
    [ "$i" -ge "$level" ] && break
    ( xcrun simctl launch "$udid" com.apple.Preferences >/dev/null 2>&1 ) &
    i=$((i + 1))
  done
  wait
}

# **本番の判定器をそのまま使う**: モニターを短時間動かし、最後の devices イベントの frozen を数える
observe_frozen() {
  seconds="$1"
  out="$(mktemp)"
  # **stdin EOF がモニターの終了指示**(ApiMonitorCommand の契約)。`sleep | monitor` にすると
  # sleep が終わった時点で EOF が届き、モニターが**自分で片付けて終わる** ——
  # kill で落とすと書き出し途中のバッファが失われ、観測が丸ごと空になる(実際に踏んだ)
  sleep "$seconds" | "$FLEETEST" api monitor --project "$PROJECT" --profile "$PROFILE" \
    --interval 2 >"$out" 2>>"$LOG"
  python3 - "$out" <<'PY'
import json, sys
last = None
for line in open(sys.argv[1], errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if isinstance(obj, dict) and isinstance(obj.get("devices"), list):
        last = obj
if last is None:
    print(-1)
else:
    print(sum(1 for d in last["devices"] if d.get("frozen")))
PY
  rm -f "$out"
}

printf 'level\tround\tfrozen\ttotal\n' | tee -a "$LOG"
LEVEL_LIST=$(printf '%s' "$LEVELS" | tr ',' ' ')
round=1
while [ "$round" -le "$ROUNDS" ]; do
  # 順序を毎ラウンド入れ替える(残熱の効果が特定の level に偏らないように)
  if [ $((round % 2)) -eq 0 ]; then
    ORDER=$(printf '%s\n' $LEVEL_LIST | tail -r | tr '\n' ' ')
  else
    ORDER="$LEVEL_LIST"
  fi
  for level in $ORDER; do
    shake "$level"
    sleep "$SETTLE_SECONDS"
    frozen="$(observe_frozen "$OBSERVE_SECONDS")"
    printf '%s\t%s\t%s\t%s\n' "$level" "$round" "$frozen" "$TOTAL" | tee -a "$LOG"
    printf '%s %s\n' "$level" "$frozen" >> "$TRIALS"
  done
  round=$((round + 1))
done

echo "" | tee -a "$LOG"
echo "=== 集計(level ごとの凍結台数: 合計 / 試行数) ===" | tee -a "$LOG"
awk '{sum[$1]+=$2; n[$1]++} END {for (l in sum) printf "level %s: %d 台 / %d 試行\n", l, sum[l], n[l]}' \
  "$TRIALS" | sort -t' ' -k2 -n | tee -a "$LOG"
echo "ログ: $LOG"

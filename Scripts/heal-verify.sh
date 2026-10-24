#!/usr/bin/env bash
#
# 自己修復(ロケータの指紋照合)の陽性対照をデバイスで回して判定する。
#
# 指紋照合は失敗経路でしか動かないので、緑の run では1度も実行されない = フル E2E を何度
# 回しても守られない。そこで _disabled の 94_指紋照合 と 95_指紋照合の前提切替 を一時的に
# 有効化し、**同じデバイス**で次の順に回す:
#   ① schema=v1 → 94 を1周(プライマリで解決して指紋を採る。修復は起きない)
#   ② schema=v2 → 94 を2周(どちらも指紋で直って緑。2周目は「直った行の鍵が次の run まで
#      刈られない」の確認 —— 2周だけだと踏まない不具合が実際にあった)
#   ③ --set heal=false で 94(指紋を使わずに赤)
#   最後に schema=v1 へ戻す(途中で落ちても trap で戻す)
#   ②の各周は run の終わりに修正提案を 94 のソースへ書き戻す(HealSourceWriteBack)。書き戻されたことを
#   確かめてから、**周ごとに元の 94 へ戻す**(戻さないと次の周がプライマリで解決し、③が緑になる)
#
# 指紋の控え(<project>/.fleetest/locator-fingerprints.json)は退避して空から回し、最後に戻す
# (過去の控えに結果を左右させない・この検証の控えを残さない)。
# schema はデバイスごとのアプリデータなので、全段を --device で1台に固定する(省略時はプロファイルの先頭)。
# fm-verify.sh と同時に回さない(どちらも _disabled のシナリオを出し入れする)。
# **既定では回さない**(e2e.sh も e2e-negative.sh も呼ばない)。見ているソース(negative-controls.json の
# watches."heal-verify")が前回 ✅ のときから変わったら e2e.sh の終わりで推奨する。回すのは指示があるときだけ。
#
# 使い方: Scripts/heal-verify.sh [--project <名前>] [--profile <名前>] [--device <デバイスの名前>]
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
# _disabled/ の出し入れで run ごとにシナリオの実行ファイルがビルドし直される = 毎回コールドの OCR モデルの
# コンパイル(35〜42 秒)を最初のシナリオの前に待たない(ScenarioHost.waitsForOCRModelCompile)
export FT_OCR_COMPILE_WAIT=off
FLEETEST="$ROOT/.build/debug/fleetest"
PROJECT="E2E-CMP"
PROFILE="ios-heal"
DEVICE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done

[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST がありません(swift build --product fleetest)" >&2; exit 1; }

PROFILE_JSON="$ROOT/TestProjects/$PROJECT/profiles/runs/$PROFILE.json"
if [ -z "$DEVICE" ]; then
  # 有効な・この Mac の・実機でない最初の台(先頭を無条件に取ると、無効にした台を指して1段も走らない)
  DEVICE=$(python3 -c 'import json,sys; print(next(d["name"] for d in json.load(open(sys.argv[1]))["devices"] if d.get("enabled", True) and d.get("machine", "local") == "local" and d.get("kind") != "physical"))' \
    "$PROFILE_JSON" 2>/dev/null) || { echo "❌ $PROFILE_JSON から台を決められない(--device で指定)" >&2; exit 1; }
fi

SCEN_DIR="$ROOT/TestProjects/$PROJECT/scenarios"
DISABLED="$SCEN_DIR/_disabled"
RUNS_DIR="$ROOT/TestProjects/$PROJECT/results/runs"
FILES=(94_指紋照合.swift 95_指紋照合の前提切替.swift)
LEDGER="$ROOT/TestProjects/$PROJECT/.fleetest/locator-fingerprints.json"
WITNESS="指紋でid変更を追従できること"
SWITCH="指紋照合の前提を切り替える"
SCHEMA_TOUCHED=0
WITNESS_FILE="$SCEN_DIR/${FILES[0]}"
WITNESS_ORIG="$(mktemp -t healverify-witness)"
WRITEBACK=""

run_step() {  # デバイスを固定して1回回す(合否は問わない。結果は results/ から読む)
  "$FLEETEST" run --project "$PROJECT" --profile "$PROFILE" --device "$DEVICE" --runner local "$@"
}

restore() {  # 途中で落ちても必ず戻す(schema → 書き戻されたソース → シナリオの配置 → 指紋の控え の順)
  if [ "$SCHEMA_TOUCHED" = 1 ]; then
    run_step --skip-build --scenario "$SWITCH.S0010" >/dev/null 2>&1 \
      || echo "⚠️ schema を v1 へ戻せなかった(台: $DEVICE)" >&2
  fi
  [ -s "$WITNESS_ORIG" ] && [ -f "$WITNESS_FILE" ] && cp "$WITNESS_ORIG" "$WITNESS_FILE"
  rm -f "$WITNESS_ORIG"
  for f in "${FILES[@]}"; do
    [ -f "$SCEN_DIR/$f" ] && mv "$SCEN_DIR/$f" "$DISABLED/$f"
  done
  rm -f "$LEDGER"
  [ -f "$LEDGER.healverify.bak" ] && mv "$LEDGER.healverify.bak" "$LEDGER"
  return 0
}
trap restore EXIT

for f in "${FILES[@]}"; do
  [ -f "$DISABLED/$f" ] || { echo "❌ $DISABLED/$f がありません" >&2; exit 1; }
  mv "$DISABLED/$f" "$SCEN_DIR/$f"
done
cp "$WITNESS_FILE" "$WITNESS_ORIG"
[ -f "$LEDGER" ] && mv "$LEDGER" "$LEDGER.healverify.bak"

list_runs() { find "$RUNS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort; }
STEPS=""
# 1段回して「その間に増えた run ディレクトリ」を控える(直近 N 本で数えると並行した run を拾う)
step() {
  local label="$1"; shift
  local before; before="$(list_runs)"
  echo "--- $label ---"
  run_step "$@" >&2 || true
  STEPS+="$label $(comm -13 <(printf '%s\n' "$before") <(list_runs) | tail -1)"$'\n'
  # 書き戻しの観測(v1 の tap が v2 に置き換わったか)→ 元へ戻す(以降の周の前提を保つ)
  if cmp -s "$WITNESS_FILE" "$WITNESS_ORIG"; then
    WRITEBACK+="$label unchanged"$'\n'
  elif grep -q 'tap("#btn_heal_v2")' "$WITNESS_FILE" && ! grep -q 'tap("#btn_heal_v1")' "$WITNESS_FILE" \
       && [ "$(diff "$WITNESS_ORIG" "$WITNESS_FILE" | grep -c '^[<>]')" = 2 ]; then
    WRITEBACK+="$label written"$'\n'
  else
    WRITEBACK+="$label unexpected"$'\n'
  fi
  cp "$WITNESS_ORIG" "$WITNESS_FILE"
}

echo "═══ $PROJECT / $PROFILE / $DEVICE(自己修復=指紋照合の検証)═══"
SCHEMA_TOUCHED=1
step setV1   --scenario "$SWITCH.S0010"
step record  --skip-build --scenario "$WITNESS"
step setV2   --skip-build --scenario "$SWITCH.S0020"
step heal1   --skip-build --scenario "$WITNESS"
step heal2   --skip-build --scenario "$WITNESS"
step healOff --skip-build --set heal=false --scenario "$WITNESS"
step restore --skip-build --scenario "$SWITCH.S0010"
SCHEMA_TOUCHED=0

restore
trap - EXIT

STEPS="$STEPS" WRITEBACK="$WRITEBACK" python3 - <<'PY'
import glob, json, os, sys

problems = []
writeback = dict(line.split(" ", 1) for line in os.environ.get("WRITEBACK", "").splitlines() if " " in line)

def result(run):
    files = sorted(glob.glob(os.path.join(run, "scenarios/*.json"))) if run else []
    if len(files) != 1:
        return None
    d = json.load(open(files[0]))
    meta = json.load(open(os.path.join(run, "run.json")))
    d["_heal"] = (meta.get("fmSettings") or {}).get("heal")
    d["_notes"] = {n for st in (d.get("timeline") or []) for n in (st.get("notes") or [])}
    d["_fixes"] = [(x.get("oldSelector"), x.get("newSelector")) for x in (d.get("fixSuggestions") or [])]
    d["_fail"] = " ".join((st.get("detail") or "") for st in (d.get("failedSteps") or []))
    return d

rows = {}
for line in os.environ.get("STEPS", "").splitlines():
    label, _, run = line.partition(" ")
    rows[label] = result(run.strip())

def check(label, cond, why):
    if not cond:
        problems.append(f"{label}: {why}")

print("\n=== 各段の結果 ===")
for label, d in rows.items():
    if d is None:
        print(f"  {label:8} (結果が無い・または1本でない)")
        problems.append(f"{label}: 結果が無い(実行されていない)")
        continue
    healed = (d.get("steps") or {}).get("healed", 0)
    print(f"  {label:8} passed={d.get('passed')} healed={healed} heal={d['_heal']} source={writeback.get(label)}"
          f" notes={sorted(d['_notes'])} fixes={d['_fixes']}"
          + (f" FAIL: {d['_fail'][:160]}" if d["_fail"] else ""))

for label in ("setV1", "setV2", "restore"):
    d = rows.get(label)
    if d: check(label, d.get("passed"), "schema を切り替えられなかった(以降の段の前提が崩れている)")

d = rows.get("record")
if d:
    check("record", d.get("passed"), f"schema=v1 で素直に通らない: {d['_fail'][:200]}")
    check("record", "heal-fingerprint-match" not in d["_notes"], "v1 なのに指紋で解決した(前提が崩れている)")

for label in ("heal1", "heal2"):
    d = rows.get(label)
    if not d: continue
    check(label, d.get("passed"), f"指紋で直らない: {d['_fail'][:200]}")
    check(label, "heal-fingerprint-match" in d["_notes"], "注記 heal-fingerprint-match が無い(指紋を通っていない)")
    check(label, ("#btn_heal_v1", "#btn_heal_v2") in d["_fixes"],
          f"修正提案が #btn_heal_v1 → #btn_heal_v2 でない: {d['_fixes']}")
    check(label, not ((d.get("fm") or {}).get("byKind") or {}).get("heal"), "自己修復で FM を呼んだ")
    check(label, writeback.get(label) == "written",
          f"94 のソースへ #btn_heal_v1 → #btn_heal_v2 の1行だけが書き戻されていない: {writeback.get(label)}")

for label in ("setV1", "record", "setV2", "healOff", "restore"):
    check(label, writeback.get(label) == "unchanged", f"直していない周でソースが変わった: {writeback.get(label)}")

d = rows.get("healOff")
if d:
    check("healOff", d["_heal"] is False, f"run.json の heal が false でない: {d['_heal']}")
    check("healOff", not d.get("passed"), "heal=false なのに緑(指紋が止まっていない)")
    check("healOff", "heal-fingerprint-match" not in d["_notes"], "heal=false なのに指紋を使った")
    check("healOff", "id=btn_heal_v1" in d["_fail"], f"狙いの tap 以外で落ちた: {d['_fail'][:200]}")

for p in problems:
    print(f"\n❌ {p}")
sys.exit(1 if problems else 0)
PY
STATUS=$?
[ "$STATUS" = 0 ] && echo "✅ 自己修復(指紋照合)はデバイスで働いています"
# ✅ を記録する(Scripts/verification_watch.py。監視対象は既定の E2E-CMP / ios-heal を指すので、その組で通したときだけ)
if [ "$STATUS" = 0 ] && [ "$PROJECT" = E2E-CMP ] && [ "$PROFILE" = ios-heal ]; then
  python3 "$ROOT/Scripts/verification_watch.py" record heal-verify \
    || echo "⚠️ 指紋照合の検証の ✅ を記録できなかった(次の e2e.sh でも推奨が出る)" >&2
fi
exit "$STATUS"

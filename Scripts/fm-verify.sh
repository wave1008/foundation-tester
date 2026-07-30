#!/usr/bin/env bash
#
# FM(Foundation Models)の実行時経路が「実際に呼ばれて成功している」ことを確認する。
#
# 全緑の E2E では FM 経路はほぼ検証できない:
#   - occlusion(偽陽性検証)は実行プロファイル既定 OFF
#   - heal は失敗しないと呼ばれない上、ヒールキャッシュが命中すると FM なしで解決する
#   - screenIs は使うシナリオが _disabled(生きた FM は非決定的でフレーク源になるため)
#   - triage は失敗しないと呼ばれない
# どれも**死んでいても素通りして緑になる**(結果 JSON の fm フィールドだけが手がかり)。
#
# そこで FM 専用シナリオ(_disabled/)を一時的に有効化し、FM を全部 ON にした
# ios-fm プロファイルで回して、結果 JSON の fm.byKind に4種が出ることを確かめる。
#
# 使い方: Scripts/fm-verify.sh [--project <名前>] [--profile <名前>]
#
# **93_triage は意図的に失敗する**(それが正常)。この失敗はスクリプトの合否には数えない。
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FTESTER="$ROOT/.build/debug/ftester"
PROJECT="E2E"
PROFILE="ios-fm"

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done

[ -x "$FTESTER" ] || { echo "❌ $FTESTER がありません(swift build --product ftester)" >&2; exit 1; }

SCEN_DIR="$ROOT/Projects/$PROJECT/Scenarios"
DISABLED="$SCEN_DIR/_disabled"
# FM を要するシナリオ(_disabled にある = 既定スイートには載らない)
FM_FILES=(90_自己修復.swift 92_screenIs.swift 93_triage.swift)
HEAL_CACHE="$ROOT/Projects/$PROJECT/.ftester/heal-cache.json"

restore() {  # 途中で落ちても必ず元へ戻す(_disabled から出したまま = 既定スイートを汚す)
  for f in "${FM_FILES[@]}"; do
    [ -f "$SCEN_DIR/$f" ] && mv "$SCEN_DIR/$f" "$DISABLED/$f"
  done
  # ヒールキャッシュは退避したものを戻す(実行で再生成された分は捨てる = 実行前の状態へ)
  [ -f "$HEAL_CACHE.fmverify.bak" ] && mv "$HEAL_CACHE.fmverify.bak" "$HEAL_CACHE"
  return 0
}
trap restore EXIT

for f in "${FM_FILES[@]}"; do
  [ -f "$DISABLED/$f" ] || { echo "❌ $DISABLED/$f がありません" >&2; exit 1; }
  mv "$DISABLED/$f" "$SCEN_DIR/$f"
done
# ヒールキャッシュ命中は FM を肩代わりする(healed=1 でも fm は nil)。必ず退避してから回す
[ -f "$HEAL_CACHE" ] && mv "$HEAL_CACHE" "$HEAL_CACHE.fmverify.bak"

echo "═══ $PROJECT / $PROFILE(FM 経路の検証)═══"
# occlusion は「疑い」が立ったときだけ発火するので、実測で最も呼ばれる2本を含める
"$FTESTER" run --project "$PROJECT" --profile "$PROFILE" \
  --scenario 自己修復でid変更を追従できること \
  --scenario 画面全体をFMで検証できること \
  --scenario スクロールで折り返し下の要素に到達できること \
  --scenario ジェスチャが正しく検出されること
echo "--- 意図的に失敗させて triage を発火させる(失敗が正常)---"
"$FTESTER" run --project "$PROJECT" --profile "$PROFILE" --skip-build \
  --scenario triage経路を検証できること || true

restore
trap - EXIT

python3 - "$ROOT/Projects/$PROJECT" <<'PY'
import glob, json, os, sys

# 直近2 run(上の2回)の fm を kind 別に合算する
runs = sorted(glob.glob(os.path.join(sys.argv[1], "results/runs/*/*/")), key=os.path.getmtime)[-2:]
agg = {}
for r in runs:
    for f in glob.glob(os.path.join(r, "scenarios/*.json")):
        fm = (json.load(open(f)) or {}).get("fm") or {}
        for kind, v in (fm.get("byKind") or {}).items():
            a = agg.setdefault(kind, {"calls": 0, "failures": 0, "maxMs": 0})
            a["calls"] += v["calls"]; a["failures"] += v["failures"]
            a["maxMs"] = max(a["maxMs"], v["maxMs"])

print("\n=== FM 呼び出しの実測(kind 別)===")
for kind in sorted(agg):
    a = agg[kind]
    print(f"  {kind:<10} calls={a['calls']:>3} failures={a['failures']:>3} max={a['maxMs']:>6}ms")
if not agg:
    print("  (1件も呼ばれていない)")

# heal / screenIs / triage は決定的に発火する。occlusion は疑いが立った時だけなので警告に留める
required = ["heal", "screenIs", "triage"]
missing = [k for k in required if k not in agg]
failed = {k: v["failures"] for k, v in agg.items() if v["failures"]}
if "occlusion" not in agg:
    print("\n⚠️ occlusion は呼ばれていない(疑いが立たなかった。FM の死とは区別できない)")
if missing:
    print(f"\n❌ 呼ばれていない経路: {', '.join(missing)}")
if failed:
    print(f"\n❌ 失敗した経路: {failed}(FM の状態を doctor で確認する)")
sys.exit(1 if missing or failed else 0)
PY
STATUS=$?
[ "$STATUS" = 0 ] && echo "✅ FM の実行時経路は生きています"
exit "$STATUS"

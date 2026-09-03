#!/usr/bin/env bash
#
# FM(Foundation Models)の実行時経路が「実際に呼ばれて成功している」ことを確認する。
#
# 全緑の E2E では FM 経路はほぼ検証できない:
#   - occlusion-guard(誤った緑の検査)は既定 ON だが、疑いが立った画面でしか発火しない
#   - heal は失敗しないと呼ばれない上、ヒールキャッシュが命中すると FM なしで解決する
#   - screenLooksLike は使うシナリオが _disabled(生きた FM は非決定的でフレーク源になるため)
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
FLEETEST="$ROOT/.build/debug/fleetest"
PROJECT="E2E-CMP"
PROFILE="ios-fm"

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done

[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST がありません(swift build --product fleetest)" >&2; exit 1; }

SCEN_DIR="$ROOT/TestProjects/$PROJECT/scenarios"
DISABLED="$SCEN_DIR/_disabled"
# FM を要するシナリオ(_disabled にある = 既定スイートには載らない)
FM_FILES=(90_自己修復.swift 92_screenLooksLike.swift 93_triage.swift)
HEAL_CACHE="$ROOT/TestProjects/$PROJECT/.fleetest/heal-cache.json"

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
"$FLEETEST" run --project "$PROJECT" --profile "$PROFILE" \
  --scenario 自己修復でid変更を追従できること \
  --scenario 画面全体をFMで検証できること \
  --scenario スクロールで折り返し下の要素に到達できること \
  --scenario ジェスチャが正しく検出されること
echo "--- 意図的に失敗させて triage を発火させる(失敗が正常)---"
"$FLEETEST" run --project "$PROJECT" --profile "$PROFILE" --skip-build \
  --scenario triage経路を検証できること || true

restore
trap - EXIT

python3 - "$ROOT/TestProjects/$PROJECT" <<'PY'
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

# **FM が「正しい要素」を選べているか**(呼ばれたかどうかとは別の軸)。
# 90_自己修復 は id が v1→v2 に変わりラベル「修復対象」は不変、という状況を作る。
# 期待する提案は #btn_heal_v2 の1つだけで、これは木を見れば決まる = 揺れる余地が無い。
#
# **このシナリオは赤のままで正常**(提案は confidence が "high" に届かず採用されない。
# confidence は信号を持たないので閾値では解けない。docs/design.md §10)。ここで見るのは
# 合否ではなく**提案の中身**で、2026-09-02 以前は壊れたロケータ `btn_heal_v1` を
# そのままオウム返ししていた。プロンプトで直したが、**モデルの応答が再び壊れたことを
# 検出できるのはここだけ**(HealPromptTests はプロンプト文字列しか見ない)。
heal_detail = ""
for r in runs:
    for f in glob.glob(os.path.join(r, "scenarios/自己修復*.json")):
        for st in (json.load(open(f)) or {}).get("failedSteps") or []:
            if "self-heal" in (st.get("detail") or ""):
                heal_detail = st["detail"]
proposal_ok = "#btn_heal_v2" in heal_detail
if heal_detail and not proposal_ok:
    print("\n❌ 自己修復の提案が誤っている(#btn_heal_v2 を選んでいない):")
    print(f"   {heal_detail[:300]}")
elif not heal_detail:
    print("\n⚠️ 自己修復の提案を確認できなかった(90_自己修復 が失敗していない、"
          "または文言が変わった)—— 提案の正しさは未検証")

# heal / screenLooksLike / triage は決定的に発火する。occlusion は疑いが立った時だけなので警告に留める
required = ["heal", "screenLooksLike", "triage"]
missing = [k for k in required if k not in agg]
failed = {k: v["failures"] for k, v in agg.items() if v["failures"]}
if "occlusion" not in agg:
    print("\n⚠️ occlusion は呼ばれていない(疑いが立たなかった。FM の死とは区別できない)")
if missing:
    print(f"\n❌ 呼ばれていない経路: {', '.join(missing)}")
if failed:
    print(f"\n❌ 失敗した経路: {failed}(FM の状態を doctor で確認する)")
sys.exit(1 if missing or failed or (heal_detail and not proposal_ok) else 0)
PY
STATUS=$?
[ "$STATUS" = 0 ] && echo "✅ FM の実行時経路は生きています"
exit "$STATUS"

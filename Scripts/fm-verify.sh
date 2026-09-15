#!/usr/bin/env bash
#
# FM(Foundation Models)の実行時経路が「実際に呼ばれて成功している」ことを確認する。
#
# 全緑の E2E では FM 経路はほぼ検証できない:
#   - occlusion-guard(誤った緑の検査)は既定 ON だが、疑いが立った画面でしか発火しない
#   - screenLooksLike は使うシナリオが _disabled(生きた FM は非決定的でフレーク源になるため)
# どちらも**死んでいても素通りして緑になる**(結果 JSON の fm フィールドだけが手がかり)。
#
# そこで FM 専用シナリオ(_disabled/)を一時的に有効化し、FM を全部 ON にした
# ios-fm プロファイルで回して、結果 JSON の fm.byKind に screenLooksLike が出ることを確かめる
# (occlusion は疑いが立ったときだけなので警告に留める)。
#
# 使い方: Scripts/fm-verify.sh [--project <名前>] [--profile <名前>]
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
RUNS_DIR="$ROOT/TestProjects/$PROJECT/results/runs"
# FM を要するシナリオ(_disabled にある = 既定スイートには載らない)
FM_FILES=(92_screenLooksLike.swift)

restore() {  # 途中で落ちても必ず元へ戻す(_disabled から出したまま = 既定スイートを汚す)
  for f in "${FM_FILES[@]}"; do
    [ -f "$SCEN_DIR/$f" ] && mv "$SCEN_DIR/$f" "$DISABLED/$f"
  done
  return 0
}
trap restore EXIT

for f in "${FM_FILES[@]}"; do
  [ -f "$DISABLED/$f" ] || { echo "❌ $DISABLED/$f がありません" >&2; exit 1; }
  mv "$DISABLED/$f" "$SCEN_DIR/$f"
done

list_runs() { find "$RUNS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort; }
# 引数のコマンドを走らせ、その間に増えた run ディレクトリを1行で返す(合否は問わない)。
# 「直近 N 本」で数えると並行した run を拾うので、実行前後の差で特定する
run_capturing() {
  local before; before="$(list_runs)"
  "$@" >&2 || true
  comm -13 <(printf '%s\n' "$before") <(list_runs) | tail -1
}

echo "═══ $PROJECT / $PROFILE(FM 経路の検証)═══"
# occlusion は「疑い」が立ったときだけ発火するので、実測で最も呼ばれる2本を含める
RUN=$(run_capturing "$FLEETEST" run --project "$PROJECT" --profile "$PROFILE" \
  --scenario 画面全体をFMで検証できること \
  --scenario スクロールで折り返し下の要素に到達できること \
  --scenario ジェスチャが正しく検出されること)

restore
trap - EXIT

python3 - "$RUN" <<'PY'
import glob, json, os, sys

run = sys.argv[1]
problems = []
agg = {}
if run:
    for f in glob.glob(os.path.join(run, "scenarios/*.json")):
        fm = (json.load(open(f)) or {}).get("fm") or {}
        for kind, v in (fm.get("byKind") or {}).items():
            a = agg.setdefault(kind, {"calls": 0, "failures": 0, "maxMs": 0})
            a["calls"] += v["calls"]; a["failures"] += v["failures"]
            a["maxMs"] = max(a["maxMs"], v["maxMs"])
else:
    problems.append("run の結果が無い(実行されていない)")

print("\n=== FM 呼び出しの実測(kind 別)===")
for kind in sorted(agg):
    a = agg[kind]
    print(f"  {kind:<15} calls={a['calls']:>3} failures={a['failures']:>3} max={a['maxMs']:>6}ms")
if not agg:
    print("  (1件も呼ばれていない)")

# screenLooksLike は決定的に発火する。occlusion は疑いが立った時だけなので警告に留める
if "screenLooksLike" not in agg:
    problems.append("呼ばれていない経路: screenLooksLike")
if "occlusion" not in agg:
    print("\n⚠️ occlusion は呼ばれていない(疑いが立たなかった。FM の死とは区別できない)")
failed = {k: v["failures"] for k, v in agg.items() if v["failures"]}
if failed:
    problems.append(f"失敗した経路: {failed}(FM の状態を doctor で確認する)")
for p in problems:
    print(f"\n❌ {p}")
sys.exit(1 if problems else 0)
PY
STATUS=$?
[ "$STATUS" = 0 ] && echo "✅ FM の実行時経路は生きています"
exit "$STATUS"

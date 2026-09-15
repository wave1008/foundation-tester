#!/usr/bin/env bash
#
# FM(Foundation Models)の実行時経路が「実際に呼ばれて成功している」ことを確認する。
#
# 全緑の E2E では FM 経路はほぼ検証できない:
#   - occlusion-guard(誤った緑の検査)は既定 ON だが、疑いが立った画面でしか発火しない
#   - heal は失敗しないと呼ばれない上、ヒールキャッシュが命中すると FM なしで解決する
#   - screenLooksLike は使うシナリオが _disabled(生きた FM は非決定的でフレーク源になるため)
# どれも**死んでいても素通りして緑になる**(結果 JSON の fm フィールドだけが手がかり)。
#
# そこで FM 専用シナリオ(_disabled/)を一時的に有効化し、FM を全部 ON にした
# ios-fm プロファイルで回して、結果 JSON の fm.byKind に heal と screenLooksLike が出ることを確かめる
# (occlusion は疑いが立ったときだけなので警告に留める)。
#
# **FM ヒールは採用門の先まで通す**。本番の門(confidence == "high")は実測で1度も開かないので、
# 90_自己修復 は注入口 FT_FAKE_HEAL_CONFIDENCE_HIGH=1(門だけを開け、提案は本物のまま使う。
# FTCore/HealConfidenceInjection.swift)で回し、
#   ① FM が選んだ要素で修復して緑になる(`tapped=v2` = 正しい要素を叩いた)
#   ② 2周目は注入なしでヒールキャッシュから通り、FM を呼ばない
# の2つを見る。ヒールキャッシュと指紋の控えは退避してから回し、最後に元へ戻す
# (注入で採用した控えを残さない・指紋に FM を肩代わりさせない)。
#
# 使い方: Scripts/fm-verify.sh [--project <名前>] [--profile <名前>]
#
# **93_存在しない要素 は意図的に失敗する**(それが正常)。この失敗はスクリプトの合否には数えない。
# 93 は**注入せずに**回す(本番の門が無関係な提案を採らないことを見るため)。
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
FM_FILES=(90_自己修復.swift 92_screenLooksLike.swift 93_存在しない要素.swift)
# 実行で書き換わる控え(ヒールキャッシュ・指紋)。退避して空から回し、最後に元へ戻す
LEDGERS=("$ROOT/TestProjects/$PROJECT/.fleetest/heal-cache.json"
         "$ROOT/TestProjects/$PROJECT/.fleetest/locator-fingerprints.json")
HEAL_CACHE="${LEDGERS[0]}"

restore() {  # 途中で落ちても必ず元へ戻す(_disabled から出したまま = 既定スイートを汚す)
  for f in "${FM_FILES[@]}"; do
    [ -f "$SCEN_DIR/$f" ] && mv "$SCEN_DIR/$f" "$DISABLED/$f"
  done
  # 実行で生成された控えは捨て、退避したものを戻す(= 実行前の状態へ。退避が無ければ消えたまま)
  for l in "${LEDGERS[@]}"; do
    rm -f "$l"
    [ -f "$l.fmverify.bak" ] && mv "$l.fmverify.bak" "$l"
  done
  return 0
}
trap restore EXIT

for f in "${FM_FILES[@]}"; do
  [ -f "$DISABLED/$f" ] || { echo "❌ $DISABLED/$f がありません" >&2; exit 1; }
  mv "$DISABLED/$f" "$SCEN_DIR/$f"
done
for l in "${LEDGERS[@]}"; do
  [ -f "$l" ] && mv "$l" "$l.fmverify.bak"
done

list_runs() { find "$RUNS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort; }
# 引数のコマンドを走らせ、その間に増えた run ディレクトリを1行で返す(合否は問わない)
run_capturing() {
  local before; before="$(list_runs)"
  "$@" >&2 || true
  comm -13 <(printf '%s\n' "$before") <(list_runs) | tail -1
}

echo "═══ $PROJECT / $PROFILE(FM 経路の検証)═══"
echo "--- ① 自己修復: 採用門を注入で開け、FM が選んだ要素で修復する ---"
RUN_HEAL=$(run_capturing env FT_FAKE_HEAL_CONFIDENCE_HIGH=1 "$FLEETEST" run --project "$PROJECT" \
  --profile "$PROFILE" --scenario 自己修復でid変更を追従できること)
# ①の採用がキャッシュに書いた rationale(注入の印を含むはず)。②の後は上書きされないが先に採る
CACHE_AFTER_HEAL=$(cat "$HEAL_CACHE" 2>/dev/null || true)
echo "--- ② 自己修復: 注入なしでヒールキャッシュから通る(FM を呼ばない)---"
RUN_CACHE=$(run_capturing "$FLEETEST" run --project "$PROJECT" --profile "$PROFILE" --skip-build \
  --scenario 自己修復でid変更を追従できること)
echo "--- screenLooksLike / occlusion ---"
# occlusion は「疑い」が立ったときだけ発火するので、実測で最も呼ばれる2本を含める
RUN_OTHERS=$(run_capturing "$FLEETEST" run --project "$PROJECT" --profile "$PROFILE" --skip-build \
  --scenario 画面全体をFMで検証できること \
  --scenario スクロールで折り返し下の要素に到達できること \
  --scenario ジェスチャが正しく検出されること)
echo "--- 存在しない要素を叩き、自己修復が置き換えないことを通す(失敗が正常・注入なし)---"
RUN_NOREPLACE=$(run_capturing "$FLEETEST" run --project "$PROJECT" --profile "$PROFILE" --skip-build \
  --scenario 存在しない要素を自己修復で置き換えないこと)

restore
trap - EXIT

CACHE_AFTER_HEAL="$CACHE_AFTER_HEAL" python3 - "$RUN_HEAL" "$RUN_CACHE" "$RUN_OTHERS" "$RUN_NOREPLACE" <<'PY'
import glob, json, os, sys, unicodedata

run_heal, run_cache, run_others, run_noreplace = sys.argv[1:5]
runs = [r for r in (run_heal, run_cache, run_others, run_noreplace) if r]
problems = []

def scenario_results(run, prefix):
    """その run の scenarioID が prefix で始まる結果。**ファイル名は NFC に揃えてから比べる** ——
    ディスク上は分解形(NFD)なので、濁点・半濁点を含む名前は glob の文字列と一致しない"""
    if not run:
        return []
    return [json.load(open(f)) for f in sorted(glob.glob(os.path.join(run, "scenarios/*.json")))
            if unicodedata.normalize("NFC", os.path.basename(f)).startswith(prefix)]

def heal_calls(s):
    return (((s.get("fm") or {}).get("byKind") or {}).get("heal") or {}).get("calls", 0)

def notes(s):
    return {n for st in (s.get("timeline") or []) for n in (st.get("notes") or [])}

def failure(s):
    return " ".join((st.get("detail") or "") for st in (s.get("failedSteps") or []))[:300]

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

# ① FM ヒールが採用され、正しい要素を叩いて緑になったか。90_自己修復 は id が v1→v2 に変わり
# ラベル「修復対象」は不変という状況を作り、scene 2 の `tapped=v2` が「FM が選んだ要素 = 正解」の
# 証拠になる(誤った要素を採れば緑にならない)。控えは空から回しているので FM 以外では直らない
heal = scenario_results(run_heal, "自己修復でid変更を追従できること")
if not heal:
    problems.append("① 90_自己修復 の結果が無い(実行されていない)")
else:
    s = heal[-1]
    healed = (s.get("steps") or {}).get("healed", 0)
    if not s.get("passed"):
        problems.append(f"① 注入しても FM ヒールで緑にならない(提案が誤っているか採用後の経路が壊れている): {failure(s)}")
    elif not healed or heal_calls(s) == 0:
        problems.append(f"① 緑だが FM ヒールを通っていない(healed={healed} fm.heal.calls={heal_calls(s)})")
    else:
        injected = "heal-confidence-injected" in notes(s)
        print(f"\n✅ ① FM ヒールで修復して緑(healed={healed}・"
              + ("採用は注入で開けた門" if injected else "confidence が high だった = 本番の門で採用") + ")")
        if "FT_FAKE_HEAL_CONFIDENCE_HIGH" not in os.environ.get("CACHE_AFTER_HEAL", "") and injected:
            problems.append("① 注入で採用したのに、ヒールキャッシュの rationale に注入の印が無い")

# ② 2周目はヒールキャッシュから通り、FM を呼ばない
cache = scenario_results(run_cache, "自己修復でid変更を追従できること")
if heal and heal[-1].get("passed"):
    if not cache:
        problems.append("② 2周目の結果が無い(実行されていない)")
    else:
        s = cache[-1]
        healed = (s.get("steps") or {}).get("healed", 0)
        if not s.get("passed") or not healed:
            problems.append(f"② 2周目がヒールキャッシュで通らない(passed={s.get('passed')} healed={healed}): {failure(s)}")
        elif heal_calls(s):
            problems.append(f"② 2周目なのに FM を呼んだ(fm.heal.calls={heal_calls(s)} = キャッシュが引けていない)")
        else:
            print("✅ ② 2周目はヒールキャッシュから通過(FM 呼び出し 0)")

# **93_存在しない要素 は「狙いの tap で失敗し、自己修復で解決したステップが 0」で正常**。
# 緑になった・healed が立った = 自己修復が存在しない要素を別の要素へ置き換えた(誤った緑の元)。
# 別のステップで落ちた(launch 等)なら、自己修復の「代わりは無い」経路は通っていない
no_replace = scenario_results(run_noreplace, "存在しない要素を自己修復で置き換えないこと")
if not no_replace:
    problems.append("93_存在しない要素 の結果が無い(実行されていない)")
else:
    s = no_replace[-1]
    healed = (s.get("steps") or {}).get("healed", 0)
    if s.get("passed") or healed:
        problems.append(f"自己修復が存在しない要素を別の要素へ置き換えた(passed={s.get('passed')} healed={healed})")
    elif "id=btn_triage_check_does_not_exist" not in failure(s):
        problems.append(f"狙いの tap より前で落ちた(自己修復の経路を通っていない): {failure(s)[:200]}")

# heal / screenLooksLike は決定的に発火する。occlusion は疑いが立った時だけなので警告に留める
missing = [k for k in ["heal", "screenLooksLike"] if k not in agg]
failed = {k: v["failures"] for k, v in agg.items() if v["failures"]}
if "occlusion" not in agg:
    print("\n⚠️ occlusion は呼ばれていない(疑いが立たなかった。FM の死とは区別できない)")
if missing:
    problems.append(f"呼ばれていない経路: {', '.join(missing)}")
if failed:
    problems.append(f"失敗した経路: {failed}(FM の状態を doctor で確認する)")
for p in problems:
    print(f"\n❌ {p}")
sys.exit(1 if problems else 0)
PY
STATUS=$?
[ "$STATUS" = 0 ] && echo "✅ FM の実行時経路は生きています"
exit "$STATUS"

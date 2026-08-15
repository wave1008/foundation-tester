#!/usr/bin/env bash
# MCP の使い勝手を「まっさらなエージェントがタスクを終えられるか・何手かかったか」で測る。
#
# **なぜ要るか**(2026-08-12): これまでの評価者は「フルコンテキストの私が応答を読んで
# 違和感があるか」だった。バグは有限なので減衰するが、「もっと分かりやすく言えたはず」は
# 無限に出るので、その評価では注記も分岐も単調に増え続ける(実際そうなった)。
# **注記を1本足すか消すかは、ここで測る手数が動いたかどうかで決める**。
#
# 使い方:
#   Scripts/mcp-bench.sh --list
#   Scripts/mcp-bench.sh --task e2e-cmp-find --repeat 3
#   Scripts/mcp-bench.sh --task maps-route --variant full= --variant no-dupids=duplicateIDsNote
#
# variant は `<名前>=<FT_MCP_NOTES_OFF に渡す鍵>`(空 = 全部出す既定)。鍵は NoteCatalog の
# 鍵と同じで、`all` で全注記を落とす。**綴りを間違えた鍵はサーバが stderr で名指しする**
# (落ちていない注記を「落とした」と誤解したまま結論を出さないため)。
#
# `brief:` を頭に付けると**注記は出したまま明細(要素ごとの代替セレクタ)だけ畳む**
# (`FT_MCP_NOTES_BRIEF` へ回す)。列挙する注記は本単位で落とすと事実まで消えるので、
# 「事実が要るか」ではなく「明細まで要るか」を測るときはこちら:
#   --variant full= --variant brief=brief:duplicateIDsNote,ambiguousLabelsNote
#
# 前提: `claude` CLI と、タスクが要求するデバイス/アプリ。デバイスは各タスクの
# `requires` に書いてあるものを**先に用意しておくこと**(この台本は用意しない ——
# 用意まで抱えると、失敗したときに「エージェントが下手だった」のか「盤面が違った」のかが
# 分からなくなる)。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DIR="$ROOT/Bench/tasks"
REPEAT=3
DRY_RUN=0
LIST=0
MODEL=""
OUT=""
TASKS=()
VARIANT_NAMES=()
VARIANT_SPECS=()

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASKS+=("$2"); shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --variant)
      case "$2" in
        *=*) VARIANT_NAMES+=("${2%%=*}"); VARIANT_SPECS+=("${2#*=}") ;;
        *) die "--variant は <名前>=<鍵,…> の形("$2")" ;;
      esac
      shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "不明なオプション: $1" ;;
  esac
done

command -v node >/dev/null || die "node が要る(集計に使う)"
[ -d "$TASK_DIR" ] || die "タスクが無い: $TASK_DIR"

task_field() { node -e '
  const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
  const v = t[process.argv[2]]
  process.stdout.write(v == null ? "" : String(v))
' "$1" "$2"; }

if [ ${#TASKS[@]} -eq 0 ]; then
  for f in "$TASK_DIR"/*.json; do TASKS+=("$(basename "$f" .json)"); done
fi

if [ "$LIST" = 1 ]; then
  printf '%-22s %-14s %s\n' "id" "archetype" "requires"
  for id in "${TASKS[@]}"; do
    f="$TASK_DIR/$id.json"
    printf '%-22s %-14s %s\n' "$id" "$(task_field "$f" archetype)" "$(task_field "$f" requires)"
  done
  exit 0
fi

# 既定は「全部出す」1本だけ。A/B は --variant を2つ以上渡したときに成立する
if [ ${#VARIANT_NAMES[@]} -eq 0 ]; then VARIANT_NAMES=(full); VARIANT_SPECS=(""); fi

STAMP="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT" ] || OUT="$ROOT/.ftester/bench/$STAMP"
mkdir -p "$OUT"
# **絶対パスへ正規化する**: run は `cd "$CWD"` してから claude を起動するので、相対の
# `--mcp-config` は cwd 側で解決されて必ず見つからない。それでも claude は 1 イベントも
# 出さずに終わるだけなので、集計は `0/3` = **タスク失敗と区別が付かない**(実際に踏んだ)
OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/bench.log"

say() { echo "$*" | tee -a "$LOG"; }

# **測る対象は「今のソースで建てた」サーバ**(古いバイナリを測ると、直したはずの注記が
# 反映されないまま結論が出る)
say "==> ftester-mcp を建てる"
if [ "$DRY_RUN" = 0 ]; then
  (cd "$ROOT" && swift build --product ftester-mcp) >>"$LOG" 2>&1 \
    || die "ビルドに失敗($LOG)"
fi
BIN="$ROOT/.build/debug/ftester-mcp"
[ "$DRY_RUN" = 1 ] || [ -x "$BIN" ] || die "実行ファイルが無い: $BIN"

# **CLAUDE.md の無い作業ディレクトリで走らせる**: 保守者向けの指示を読んだエージェントは
# 「まっさらな読み手」ではない(このリポジトリの事情を知っている)
CWD="$OUT/cwd"
mkdir -p "$CWD"

EMPTY=0
INDEX="$OUT/index.json"
echo '{"baseVariant":"'"${VARIANT_NAMES[0]}"'","runs":[' > "$INDEX"
first_entry=1

for vi in "${!VARIANT_NAMES[@]}"; do
  variant="${VARIANT_NAMES[$vi]}"
  spec="${VARIANT_SPECS[$vi]}"
  vdir="$OUT/$variant"
  mkdir -p "$vdir"
  # `brief:` 接頭辞は「落とす」ではなく「明細だけ畳む」側へ回す(冒頭の使い方を参照)
  case "$spec" in
    brief:*) off_spec=""; brief_spec="${spec#brief:}" ;;
    *) off_spec="$spec"; brief_spec="" ;;
  esac
  cat > "$vdir/mcp.json" <<JSON
{"mcpServers":{"ftester":{"command":"$BIN","env":{"FT_MCP_NOTES_OFF":"$off_spec","FT_MCP_NOTES_BRIEF":"$brief_spec"}}}}
JSON
  say "==> variant $variant (FT_MCP_NOTES_OFF='$off_spec' FT_MCP_NOTES_BRIEF='$brief_spec')"

  for id in "${TASKS[@]}"; do
    f="$TASK_DIR/$id.json"
    [ -f "$f" ] || die "タスクが無い: $f"
    prompt="$(task_field "$f" prompt)"
    expect="$(task_field "$f" expect)"
    max_turns="$(task_field "$f" maxTurns)"; [ -n "$max_turns" ] || max_turns=60
    # **`"draft": true` のタスクだけ下書きで締める**(2026-08-13)。指示は台本側に1本だけ持つ ——
    # タスクごとに文言を書くと、A/B の両側で頼み方が変わって品質の差が文言の差に化ける。
    # 既存タスクは `draft` を持たないので**1バイトも変わらない**(過去の計測と比較可能なまま)
    if [ "$(task_field "$f" draft)" = "true" ]; then
      prompt="$prompt

最後に、RESULT の行を出す前に ft_draft_scenario を呼んで、いま行った操作を Swift シナリオの
下書きへ書き戻してください(ファイルには保存しないでください)。回り道を記録していたら
drop: や lastN: で刈り込んでから、もう一度呼んでください。"
    fi

    for n in $(seq 1 "$REPEAT"); do
      transcript="$vdir/$id-$n.jsonl"
      set -- claude -p "$prompt" \
        --output-format stream-json --verbose \
        --mcp-config "$vdir/mcp.json" --strict-mcp-config \
        --allowedTools mcp__ftester \
        --max-turns "$max_turns"
      [ -z "$MODEL" ] || set -- "$@" --model "$MODEL"
      if [ "$DRY_RUN" = 1 ]; then
        say "    (dry-run) $id #$n → $transcript"
      else
        # **1本の失敗で全体を止めない**(残りの盤面は生きている)。失敗は空の記録として
        # 残り、集計では未完了として数えられる
        (cd "$CWD" && "$@") > "$transcript" 2>>"$LOG" || true
        lines="$(wc -l < "$transcript" | tr -d ' ')"
        # **記録が空 = エージェントが1手も打っていない**。集計ではこれも「未完了」に
        # 畳まれるので、ここで名指ししないと**盤面の失敗と台本の失敗が区別できない**
        if [ "$lines" = 0 ]; then
          EMPTY=$((EMPTY + 1))
          say "    $id #$n → !! 記録が空(claude が1イベントも出していない。$LOG の Error を見ること)"
        else
          say "    $id #$n → $lines events"
        fi
      fi
      [ "$first_entry" = 1 ] || echo ',' >> "$INDEX"
      first_entry=0
      printf '{"variant":"%s","task":"%s","expect":%s,"transcript":"%s"}' \
        "$variant" "$id" "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]||null))' "$expect")" \
        "$transcript" >> "$INDEX"
    done
  done
done

echo ']}' >> "$INDEX"

if [ "$DRY_RUN" = 1 ]; then
  say "==> dry-run。実行はしていない($INDEX に予定だけ書いた)"
  exit 0
fi

if [ "$EMPTY" != 0 ]; then
  say "!! $EMPTY run が1イベントも出していない。下の表の未完了はタスクの失敗ではなく台本の失敗"
fi

say "==> 集計"
node "$ROOT/Scripts/bench-summary.mjs" "$INDEX" --json "$OUT/summary.json" | tee -a "$LOG"
say ""
say "記録: $OUT"

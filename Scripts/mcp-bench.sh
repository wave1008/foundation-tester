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
# **作成フローのタスク**(`"kind": "authoring"`。2026-09-25): 壊れたシナリオを直して緑にするまでを測る。
# このときだけエージェントに**ファイルの読み書き**(Read/Edit/Write/Glob/Grep)も許し、作業場所は
# `~/.fleetest/bench/authoring-pkg/<tool-root のハッシュ>/authoring-pkg`(`fleetest init` で作る外部
# パッケージ。git の外 = まっさらな読み手の条件・TestProjects/ には触らない)。run のたびに `Bench/fixtures/<fixture>/` の .swift を置き直し、台帳(.fleetest/)と
# レポートを消す。完了は**自己申告ではなく**、最後の ft_run_scenario が通ったこと・その後に
# ファイルを書き換えていないこと・`mustContain` の文字列が最終ファイルに残っていること(検証を
# 削って緑にする抜け道を塞ぐ)で判定する(bench-summary.mjs の authoringVerdict)。任意で
# `mustNotContain`(最終ファイルに残っていてはいけない文字列)と `lastRunMustNotContain`(最後の
# ft_run_scenario の応答に出てはいけない文字列。例: 自己修復の印 🔧)も見る。
#
# `--tool-root <dir>` で測る対象のクローンを差し替える(既定はこの台本のクローン)。変更前の
# コミットを worktree に出して渡せば、同じタスク・同じ台本で前後を比べられる:
#   git worktree add /tmp/before/foundation-tester <commit>   # 名前は foundation-tester 固定
#   Scripts/mcp-bench.sh --task ios-authoring-fix-drift --repeat 5 --tool-root /tmp/before/foundation-tester
#
# 前提: `claude` CLI と、タスクが要求するデバイス/アプリ。デバイスは各タスクの
# `requires` に書いてあるものを**先に用意しておくこと**(この台本は用意しない ——
# 用意まで抱えると、失敗したときに「エージェントが下手だった」のか「盤面が違った」のかが
# 分からなくなる)。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DIR="$ROOT/Bench/tasks"
FIXTURE_DIR="$ROOT/Bench/fixtures"
TOOL_ROOT="$ROOT"
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
    --tool-root) TOOL_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --list) LIST=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
[ -n "$OUT" ] || OUT="$ROOT/.fleetest/bench/$STAMP"
mkdir -p "$OUT"
# **絶対パスへ正規化する**: run は `cd "$CWD"` してから claude を起動するので、相対の
# `--mcp-config` は cwd 側で解決されて必ず見つからない。それでも claude は 1 イベントも
# 出さずに終わるだけなので、集計は `0/3` = **タスク失敗と区別が付かない**(実際に踏んだ)
OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/bench.log"

say() { echo "$*" | tee -a "$LOG"; }

# **測る対象は「今のソースで建てた」サーバ**(古いバイナリを測ると、直したはずの注記が
# 反映されないまま結論が出る)
say "==> fleetest-mcp を建てる($TOOL_ROOT)"
if [ "$DRY_RUN" = 0 ]; then
  (cd "$TOOL_ROOT" && swift build --product fleetest-mcp) >>"$LOG" 2>&1 \
    || die "ビルドに失敗($LOG)"
fi
BIN="$TOOL_ROOT/.build/debug/fleetest-mcp"
[ "$DRY_RUN" = 1 ] || [ -x "$BIN" ] || die "実行ファイルが無い: $BIN"

# **まっさらな読み手にする**(2026-09-25 に穴を塞いだ): 保守者向けの知識を持ったエージェントは
# 「まっさらな読み手」ではない。塞ぐのは3つ ——
#  ① 作業場所を **git の外**に置く。クローンの内側(旧既定 = `<クローン>/.fleetest/bench/`)だと
#    Claude Code はクローンを同じプロジェクトと見なし、**自動メモリの置き場が保守者のメモリ**を指していた
#  ② `--setting-sources project`: 利用者設定(有効なプラグイン = fleetest のスキル・許可)を読ませない
#  ③ `--disable-slash-commands` と `autoMemoryEnabled:false`: スキルと自動メモリを切る
# 効いたかは各 run の起動イベント(memory_paths / skills / plugins)で集計が確かめる(isolated 列)
BENCH_HOME="$HOME/.fleetest/bench"
CWD="$BENCH_HOME/cwd"
mkdir -p "$CWD"
git -C "$CWD" rev-parse --show-toplevel >/dev/null 2>&1 \
  && die "作業場所が git の中にある($CWD)。Claude Code がそのリポジトリのメモリ・設定を読む"
ISOLATION_SETTINGS='{"autoMemoryEnabled":false}'

# ---- 作成フローの作業場所 ----
# `fleetest init` の Package.swift はツールを `package: "foundation-tester"` で参照し、SPM は
# パス依存をディレクトリ名で識別する = worktree も `…/foundation-tester` という名前で作る
# 作業場所は git の外(上の①)。測る対象のクローンごとに分ける(前後の比較で依存先が違う)
PKG="$BENCH_HOME/authoring-pkg/$(printf '%s' "$TOOL_ROOT" | shasum | cut -c1-12)/authoring-pkg"
PKG_PROJECT=BenchAuthoring
has_authoring=0
pkg_app=""
for id in "${TASKS[@]}"; do
  if [ "$(task_field "$TASK_DIR/$id.json" kind)" = authoring ]; then
    has_authoring=1
    [ -n "$pkg_app" ] || pkg_app="$(task_field "$TASK_DIR/$id.json" appId)"
  fi
done
[ "$has_authoring" = 0 ] || [ "$(basename "$TOOL_ROOT")" = foundation-tester ] \
  || die "--tool-root のディレクトリ名は foundation-tester にする(SPM がパス依存を名前で識別する): $TOOL_ROOT"
# 外部パッケージは一度作れば使い回す(.build が温まる)。`fleetest init` は受け手向けに
# .claude/(スキル・許可)と .vscode/ を置くが、**まっさらな読み手**には要らないので消す
if [ "$has_authoring" = 1 ] && [ "$DRY_RUN" = 0 ] && [ ! -f "$PKG/Package.swift" ]; then
  say "==> 作成フローの外部パッケージを作る($PKG)"
  (cd "$ROOT" && swift build --product fleetest) >>"$LOG" 2>&1 || die "fleetest のビルドに失敗($LOG)"
  mkdir -p "$PKG"
  (cd "$PKG" && "$ROOT/.build/debug/fleetest" init --fleetest-path "$TOOL_ROOT" \
      --name "$PKG_PROJECT" --platform ios ${pkg_app:+--app-id "$pkg_app"}) >>"$LOG" 2>&1 \
      || die "fleetest init に失敗($LOG)"
fi

# 1 run ぶんの盤面を作り直す: シナリオをフィクスチャへ戻し、台帳(#id の台帳・指紋)と
# レポートを消す(前の run の学習が次の run に漏れると手数が下がって見える)。
# **台帳はプロジェクトの下にもある**(`TestProjects/<p>/.fleetest/` = locator-fingerprints.json と
# selector-inventory.json。2026-09-25 まではここを消しておらず run をまたいで残っていた)。
# フィクスチャに `fleetest/` があれば、それをプロジェクトの `.fleetest/` として置く(指紋の控えの種)
reset_authoring() {
  local fixture="$1"
  local proj="$PKG/TestProjects/$PKG_PROJECT"
  local scen="$proj/scenarios"
  rm -rf "$PKG/.claude" "$PKG/.vscode" "$PKG/CLAUDE.md" "$PKG/AGENTS.md" "$PKG/.fleetest" "$proj/.fleetest"
  find "$scen" -name '*.swift' ! -name '_Main.swift' -delete
  cp "$FIXTURE_DIR/$fixture"/*.swift "$scen/"
  if [ -d "$FIXTURE_DIR/$fixture/fleetest" ]; then
    mkdir -p "$proj/.fleetest"
    cp "$FIXTURE_DIR/$fixture/fleetest"/* "$proj/.fleetest/"
  fi
  find "$PKG/TestProjects/$PKG_PROJECT/reports" -mindepth 1 -delete 2>/dev/null || true
}

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
{"mcpServers":{"fleetest":{"command":"$BIN","env":{"FT_MCP_NOTES_OFF":"$off_spec","FT_MCP_NOTES_BRIEF":"$brief_spec"}}}}
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

    kind="$(task_field "$f" kind)"
    run_cwd="$CWD"
    allowed=mcp__fleetest
    if [ "$kind" = authoring ]; then
      fixture="$(task_field "$f" fixture)"
      [ -d "$FIXTURE_DIR/$fixture" ] || die "フィクスチャが無い: $FIXTURE_DIR/$fixture"
      run_cwd="$PKG"
      allowed="mcp__fleetest,Read,Edit,Write,Glob,Grep"
      # **最初の run だけがビルドを払わないよう、先に1回建てておく**(2 分級。手数ではなく
      # wall が歪む)。フィクスチャは実行時にだけ落ちる形なのでコンパイルは通る
      if [ "$DRY_RUN" = 0 ]; then
        reset_authoring "$fixture"
        (cd "$PKG" && swift build --product "fleetest-scenarios-$PKG_PROJECT") >>"$LOG" 2>&1 \
          || die "フィクスチャのビルドに失敗($LOG)"
      fi
    fi

    for n in $(seq 1 "$REPEAT"); do
      transcript="$vdir/$id-$n.jsonl"
      final=""
      [ "$kind" != authoring ] || [ "$DRY_RUN" = 1 ] || reset_authoring "$fixture"
      set -- claude -p "$prompt" \
        --output-format stream-json --verbose \
        --mcp-config "$vdir/mcp.json" --strict-mcp-config \
        --allowedTools "$allowed" \
        --setting-sources project --settings "$ISOLATION_SETTINGS" --disable-slash-commands \
        --no-session-persistence \
        --max-turns "$max_turns"
      [ -z "$MODEL" ] || set -- "$@" --model "$MODEL"
      if [ "$DRY_RUN" = 1 ]; then
        say "    (dry-run) $id #$n → $transcript"
      else
        # **1本の失敗で全体を止めない**(残りの盤面は生きている)。失敗は空の記録として
        # 残り、集計では未完了として数えられる
        (cd "$run_cwd" && "$@") > "$transcript" 2>>"$LOG" || true
        # 判定は最終ファイルで行う(次の run が置き直す前に控える)
        if [ "$kind" = authoring ]; then
          final="$vdir/$id-$n.final.swift"
          cp "$PKG/TestProjects/$PKG_PROJECT/scenarios/$(task_field "$f" file)" "$final" 2>/dev/null \
            || : > "$final"
        fi
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
      printf '{"variant":"%s","task":"%s","expect":%s,"transcript":"%s","authoring":%s}' \
        "$variant" "$id" "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]||null))' "$expect")" \
        "$transcript" "$(node -e '
          const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
          process.stdout.write(t.kind === "authoring"
            ? JSON.stringify({ final: process.argv[2] || null, mustContain: t.mustContain ?? [],
                               mustNotContain: t.mustNotContain ?? [],
                               lastRunMustNotContain: t.lastRunMustNotContain ?? [] })
            : "null")' "$f" "$final")" >> "$INDEX"
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

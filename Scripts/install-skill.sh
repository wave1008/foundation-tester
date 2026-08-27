#!/usr/bin/env sh
# fleetest ブートストラップスキル導入器。
#
# 何も入れていないユーザーが、空ディレクトリで次を実行すると、カレントの
# スキルディレクトリに fleetest-setup / fleetest-update / fleetest-profiles / fleetest-scenario /
# fleetest-mcp / fleetest-remote-setup スキルを置く(この時点では repo を clone しない):
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh
#
# 置き先はエージェントの規約位置(既定は自動判定):
#   Claude Code → .claude/skills/    Codex → .agents/skills/
# 明示するときは `| sh -s -- --agent codex`(claude / codex / both / auto)。
#
# 注: プラグイン機構が使えるならそちらが推奨(スキル自動更新つき・正典を参照する薄いアダプタ)。
#   Claude Code: claude plugin marketplace add wave1008/foundation-tester →
#                claude plugin install fleetest@foundation-tester --scope user
#                (/plugin スラッシュコマンドは VSCode 拡張パネルでは使えない)
#   Codex:       codex plugin marketplace add wave1008/foundation-tester →
#                codex plugin add fleetest@foundation-tester
#                (更新は marketplace upgrade → plugin add。サブコマンド名が Claude と違う)
# 本スクリプトはプラグイン機構を使えない環境向けのフォールバック(コピーなので自動更新なし)。
# 以後 /fleetest-setup(Codex は $fleetest-setup)等を呼べる。
# clone/build/install は各スキル本体が行う(大きな取得/ビルドの前にユーザーがレビューできるようにするため)。
#
# 契約: **取得元は repo 内の正典 .claude/skills/<name>/SKILL.md(単一ソース)**。
# Codex 側の .agents/skills/ はこの正典へのシンボリックリンクなので、
# **raw.githubusercontent から取ると本文でなくリンク先の文字列が返る** —— 取得先は常に正典。
# FLEETEST_REF=<tag/branch/sha> は**保守者が未マージのブランチを検証するための口**(既定 main)。
# 受け手向けの版固定手段としては案内しない —— 配布口は main の1本(docs/releasing.md)。
set -eu

REF="${FLEETEST_REF:-main}"
REPO="wave1008/foundation-tester"
# 正典の実体パス(AgentIntegration.canonicalSkillsDirectory と一致必須)
BASE="https://raw.githubusercontent.com/${REPO}/${REF}/.claude/skills"
SKILLS="fleetest-setup fleetest-update fleetest-profiles fleetest-scenario fleetest-mcp fleetest-remote-setup"
AGENT="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="${2:-}"; shift 2 ;;
    --agent=*) AGENT="${1#--agent=}"; shift ;;
    -h|--help)
      echo "usage: install-skill.sh [--agent claude|codex|both|auto]"; exit 0 ;;
    *) echo "エラー: 不明なオプション $1" >&2; exit 2 ;;
  esac
done

# 自動判定は FTCore の AgentIntegration.detect と同じ規則
# (.claude / CLAUDE.md / ~/.claude → claude、.agents / AGENTS.md / ~/.codex → codex、
#  どれも無ければ claude 単独)。判定を変えるときは両方を直す。
if [ "$AGENT" = "auto" ]; then
  AGENT=""
  if [ -d ".claude" ] || [ -f "CLAUDE.md" ] || [ -d "$HOME/.claude" ]; then AGENT="claude"; fi
  if [ -d ".agents" ] || [ -f "AGENTS.md" ] || [ -d "$HOME/.codex" ]; then
    AGENT="${AGENT:+${AGENT} }codex"
  fi
  [ -n "$AGENT" ] || AGENT="claude"
  if [ "$AGENT" = "claude codex" ]; then AGENT="both"; fi
fi

case "$AGENT" in
  claude) DIRS=".claude/skills" ;;
  codex)  DIRS=".agents/skills" ;;
  both)   DIRS=".claude/skills .agents/skills" ;;
  *) echo "エラー: --agent は claude / codex / both / auto のいずれか(受け取った値: $AGENT)" >&2; exit 2 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "エラー: curl が必要です" >&2; exit 1; }

# 全スキルを一時ディレクトリへ取得・検証してから、まとめて配置する(all-or-nothing)。
# set -e 下で curl 失敗が即中断すると後片付けが走らず空ディレクトリを残すため、
# fetch/validate は明示 if で扱い、全て成功して初めて配置する。
WORK="${TMPDIR:-/tmp}/fleetest-skill.$$"
mkdir -p "${WORK}"
trap 'rm -rf "${WORK}"' EXIT INT TERM

for name in ${SKILLS}; do
  raw="${BASE}/${name}/SKILL.md"
  tmp="${WORK}/${name}.md"
  echo "==> 取得 ${raw}"
  if ! curl -fsSL "${raw}" -o "${tmp}"; then
    echo "エラー: ${name} の取得に失敗しました。repo の公開状態と REF=${REF} を確認してください" >&2
    exit 1
  fi
  # 中身検証: 空でない・先頭が YAML frontmatter(誤 REF や権限エラーだと GitHub が
  # HTML/404 本文を 200 で返すことがあるため、SKILL.md 実体であることを最低限確認する。
  # 取得元をシンボリックリンクへ変えてしまった場合もここで落ちる = リンク先の1行が返る)。
  if [ ! -s "${tmp}" ] || ! head -n 1 "${tmp}" | grep -q '^---$'; then
    echo "エラー: ${name} の取得内容が SKILL.md ではありません(空/HTML/シンボリックリンク)。REF=${REF} を確認してください" >&2
    exit 1
  fi
done

for base in ${DIRS}; do
  for name in ${SKILLS}; do
    dir="${base}/${name}"
    mkdir -p "${dir}"
    cp "${WORK}/${name}.md" "${dir}/SKILL.md"
    echo "    → ${dir}/SKILL.md"
  done
done

echo "✅ fleetest のスキル6本を ${DIRS} に導入しました。"
cat <<'EOF'
次の手順:
  1. このフォルダをエージェント(Claude Code / Codex)で開く(既に開いているなら再読込)
  2. /fleetest-setup を実行する(Codex は $fleetest-setup。初回導入: clone → build → install)
     エージェントを使わないなら同じ機械作業を1コマンドで:
       curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh \
         | bash -s -- --name <ProjectName>
     以後、修正版の取り込みは /fleetest-update
     マシン/アプリ/実行プロファイルの一括作成は /fleetest-profiles
     テストシナリオ(.swift)の作成は /fleetest-scenario
     MCP サーバ(ft_* ツール)だけの登録は /fleetest-mcp
     別の Mac をランナーにしてリモート実行するなら /fleetest-remote-setup
EOF

#!/usr/bin/env sh
# fleetest ブートストラップスキル導入器。
#
# 何も入れていないユーザーが、空ディレクトリで次を実行すると、カレントの
# スキルディレクトリに fleetest-setup / fleetest-update / fleetest-profiles / fleetest-scenario /
# fleetest-mcp / fleetest-remote-setup スキルを置く(この時点では repo を clone しない):
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh
#
# 置き先は Claude Code の規約位置 `.claude/skills/`。**他のエージェント**(Codex・Cline 等)は
# `--dir <path>` でそのエージェントのスキル置き場を指定する(SKILL.md はツール中立の
# markdown なので、スキル機構が無いエージェントには必要なときに読ませればよい。
# docs/user-docs/tools/other_agents.md)。
#
# 注: Claude Code はプラグイン機構が推奨(スキル自動更新つき・正典を参照する薄いアダプタ):
#   claude plugin marketplace add wave1008/foundation-tester →
#   claude plugin install fleetest@foundation-tester --scope user
#   (/plugin スラッシュコマンドは VSCode 拡張パネルでは使えない)
# 本スクリプトはプラグイン機構を使えない環境向けのフォールバック(コピーなので自動更新なし)。
# 以後 /fleetest-setup 等を呼べる。
# clone/build/install は各スキル本体が行う(大きな取得/ビルドの前にユーザーがレビューできるようにするため)。
#
# 契約: **取得元は repo 内の正典 .claude/skills/<name>/SKILL.md(単一ソース)**。
# 取得元をシンボリックリンクへ変えない —— **raw.githubusercontent はリンクを本文でなく
# リンク先の文字列として返す**ので、SKILL.md ではなく1行のパスが降ってくる。
# FLEETEST_REF=<tag/branch/sha> は**保守者が未マージのブランチを検証するための口**(既定 main)。
# 受け手向けの版固定手段としては案内しない —— 配布口は main の1本(docs/releasing.md)。
set -eu

REF="${FLEETEST_REF:-main}"
REPO="wave1008/foundation-tester"
# 正典の実体パス(AgentIntegration.canonicalSkillsDirectory と一致必須)
BASE="https://raw.githubusercontent.com/${REPO}/${REF}/.claude/skills"
SKILLS="fleetest-setup fleetest-update fleetest-profiles fleetest-scenario fleetest-mcp fleetest-remote-setup"
# 置き先(既定は Claude Code の規約位置 = AgentIntegration.skillsDirectory)。
# 他のエージェントは自分のスキル置き場を --dir で渡す
DEST=".claude/skills"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DEST="${2:?--dir にはパスが必要です}"; shift 2 ;;
    --dir=*) DEST="${1#--dir=}"; shift ;;
    -h|--help)
      echo "usage: install-skill.sh [--dir <skills-dir>]  (default: .claude/skills)"; exit 0 ;;
    *) echo "エラー: 不明なオプション $1" >&2; exit 2 ;;
  esac
done
[ -n "$DEST" ] || { echo "エラー: --dir が空です" >&2; exit 2; }

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

for name in ${SKILLS}; do
  dir="${DEST}/${name}"
  mkdir -p "${dir}"
  cp "${WORK}/${name}.md" "${dir}/SKILL.md"
  echo "    → ${dir}/SKILL.md"
done

echo "✅ fleetest のスキル6本を ${DEST} に導入しました。"
cat <<'EOF'
次の手順:
  1. このフォルダをエージェントで開く(既に開いているなら再読込)
  2. /fleetest-setup を実行する(初回導入: clone → build → install。
     スキル機構の無いエージェントでは SKILL.md を読ませて手順どおり進める)
     エージェントを使わないなら同じ機械作業を1コマンドで:
       curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh \
         | bash -s -- --name <ProjectName>
     以後、修正版の取り込みは /fleetest-update
     マシン/アプリ/実行プロファイルの一括作成は /fleetest-profiles
     テストシナリオ(.swift)の作成は /fleetest-scenario
     MCP サーバ(ft_* ツール)だけの登録は /fleetest-mcp
     別の Mac をランナーにしてリモート実行するなら /fleetest-remote-setup
EOF

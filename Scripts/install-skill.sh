#!/usr/bin/env sh
# fleetest ブートストラップスキル導入器。
#
# 何も入れていないユーザーが、空ディレクトリで次を実行すると、カレントの
# .claude/skills/ に fleetest-setup / fleetest-update / fleetest-profiles / fleetest-scenario / fleetest-mcp /
# fleetest-remote-setup スキルを置く
# (この時点では repo を clone しない):
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh
#
# 注: Claude Code なら plugin 導入(ターミナルで claude plugin marketplace add wave1008/foundation-tester →
# claude plugin install fleetest@foundation-tester --scope user。スキル自動更新つき・正典 .claude/skills/ を参照。
# /plugin スラッシュコマンドは VSCode 拡張パネルでは使えない)が推奨。
# 本スクリプトはプラグイン機構を使えない環境向けのフォールバック(コピーなので自動更新なし)。
# 以後 Claude Code で /fleetest-setup(初回導入)・/fleetest-update(更新)・
# /fleetest-profiles(プロファイル一括作成)・/fleetest-scenario(シナリオ作成)を呼べる。
# clone/build/install は各スキル本体が行う(大きな取得/ビルドの前にユーザーがレビューできるようにするため)。
#
# 契約: 取得元は repo 内の正典 .claude/skills/<name>/SKILL.md(単一ソース)。
# 版を固定したいときは FLEETEST_REF=<tag/branch/sha> で上書き(既定 main)。
set -eu

REF="${FLEETEST_REF:-main}"
REPO="wave1008/foundation-tester"
BASE="https://raw.githubusercontent.com/${REPO}/${REF}/.claude/skills"
SKILLS="fleetest-setup fleetest-update fleetest-profiles fleetest-scenario fleetest-mcp fleetest-remote-setup"

command -v curl >/dev/null 2>&1 || { echo "エラー: curl が必要です" >&2; exit 1; }

# 全スキルを一時ディレクトリへ取得・検証してから、まとめて配置する(all-or-nothing)。
# set -e 下で curl 失敗が即中断すると後片付けが走らず空ディレクトリを残すため、
# fetch/validate は明示 if で扱い、全て成功して初めて .claude/skills/ を作る。
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
  # HTML/404 本文を 200 で返すことがあるため、SKILL.md 実体であることを最低限確認する)。
  if [ ! -s "${tmp}" ] || ! head -n 1 "${tmp}" | grep -q '^---$'; then
    echo "エラー: ${name} の取得内容が SKILL.md ではありません(空/HTML)。REF=${REF} を確認してください" >&2
    exit 1
  fi
done

for name in ${SKILLS}; do
  dir=".claude/skills/${name}"
  mkdir -p "${dir}"
  cp "${WORK}/${name}.md" "${dir}/SKILL.md"
  echo "    → ${dir}/SKILL.md"
done

cat <<'EOF'
✅ fleetest-setup / fleetest-update / fleetest-profiles / fleetest-scenario / fleetest-mcp / fleetest-remote-setup スキルを .claude/skills/ に導入しました。
次の手順:
  1. このフォルダを Claude Code で開く(既に開いているなら再読込)
  2. /fleetest-setup を実行する(初回導入: clone → build → install)
     エージェントを使わないなら同じ機械作業を1コマンドで:
       curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh \
         | bash -s -- --name <ProjectName>
     以後、修正版の取り込みは /fleetest-update
     マシン/アプリ/実行プロファイルの一括作成は /fleetest-profiles
     テストシナリオ(.swift)の作成は /fleetest-scenario
     MCP サーバ(ft_* ツール)だけの登録は /fleetest-mcp
     別の Mac をランナーにしてリモート実行するなら /fleetest-remote-setup
EOF

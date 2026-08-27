#!/usr/bin/env bash
# fleetest インストーラ。/fleetest-setup スキルの「機械作業」だけを1コマンドに固めたもの。
#
#   bash Scripts/install.sh --work-dir <受け手ディレクトリ> --name <ProjectName> [--app <bundleID>]
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh \
#     | bash -s -- --name <ProjectName>          # clone から丸ごと(TOOL_ROOT は隣に作られる)
#
# やること: clone(既存クローンは git pull --ff-only で更新)/ swift build /
#           fleetest init(または project create)/ .gitignore 整備 / VSCode 拡張 /
#           MCP 登録(Claude Code=.mcp.json / Codex=codex mcp add)/ エージェントの入口
#           (CLAUDE.md / AGENTS.md)/ 検証ゲート。**冪等**(済んだ手順は skip)。
#           --machine と --app-name があればプロファイル作成(profile setup --auto-device)も。
# やらないこと: appPath や bundle ID の探索
#           (値は引数で受けるだけ。スキルの「探索禁止」原則と対)。
#
# 契約: 各手順は .claude/skills/fleetest-setup/SKILL.md のステップ番号と 1:1。失敗時は
#       「→ SKILL.md ステップ N」を出すので、エージェントはそこだけ手作業で直して再実行する
#       (この対応表を崩すときは SKILL.md 側も一緒に直す)。
# ログ: 全出力を <WORK_DIR>/.fleetest/install-<日時>.log にも落とす(実行ごとに別ファイル)。
#       画面に出すのは**各ステップの1行(その場で逐次)+ 見出し + 最後の集計**だけ。
#       swift build・npm・vsce の生ログはファイルへ(画面に出すと呼び出し元のエージェントで
#       切られ、結果を探す grep が承認を増やす)。--verbose で従来どおり画面にも出す。
#       **無音の時間を作らない**のが逐次表示の目的(クローン〜ビルドは数分。人が「止まった」と
#       誤解して中断するのを防ぐ)。数分かかる工程には経過時間を付ける。
# 終了コード: 0=完了 / 1=必須ステップの失敗 / 2=任意ステップのみ失敗(CLI は使える)
set -euo pipefail

# FLEETEST_REPO_URL はフォーク・ローカル検証用の差し替え口(既定は本家)
REPO_URL="${FLEETEST_REPO_URL:-https://github.com/wave1008/foundation-tester.git}"
# FLEETEST_REF は**保守者が未マージのブランチを受け手経路で検証するための口**(タグ・ブランチ・SHA。
# 既定 = 既定ブランチ)。受け手向けの版固定手段としては案内しない —— 配布口は main の1本
# (docs/releasing.md)。
# **スクリプトの取得元とクローンの ref を必ず揃える**ためにある —— スキルは
# `.../${FLEETEST_REF:-main}/Scripts/install.sh` を取りに行くので、ここで見ないと
# 「ブランチのスクリプトが main を clone して main のバイナリに新しい引数を渡す」
# という組み合わせが生まれ、`Unknown option` で落ちる(未マージのブランチ検証で実際に踏んだ)
REF="${FLEETEST_REF:-}"
WORK_DIR="$PWD"
TOOL_ROOT_ARG=""
PROJECT_NAME=""
APP_ID=""
APP_NAME=""
MACHINE=""
PLATFORM="both"
DO_EXTENSION=1
DO_PROJECT=1
DO_MCP=1
DO_CLAUDE_MD=1
DO_AGENTS_MD=1
DO_CLINERULES=1
AGENT_ARG=""
DO_DOCTOR=1
DO_NEXT_STEPS=1
ALLOW_CLONE=1
ALLOW_PULL=1
VERBOSE=0
KEEP_LOCAL=0

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --work-dir <dir>   Consumer directory that holds TestProjects/ (default: current directory)
  --name <name>      Project name to create (letters, digits, _ and -; derived from the directory name when omitted)
  --app <bundleID>   Bundle ID / package name of the app under test (--app-id also works; optional, can be changed later)
  --platform <p>     Which run profiles to scaffold: ios / android / both (default both)
  --app-name <name>  Display name of the app. Together with --machine, profiles are created too
  --machine <name>   This machine's name (machines/<name>.json; registered if not yet)
  --tool-root <dir>  Location of the foundation-tester clone (default: <work-dir>/../foundation-tester)
  --no-clone         Do not clone when missing (an existing clone is required)
  --no-pull          Do not update an existing clone (to pin a version, or while developing the tool)
  --skip-extension   Do not install the VSCode extension
  --skip-project     Do not create a project (TestProjects/<name>/) — e.g. MCP-only installs
  --skip-mcp         Do not generate/merge .mcp.json
  --skip-claude-md   Do not write the fleetest block into <work-dir>/CLAUDE.md
  --skip-agents-md   Do not write the fleetest block into <work-dir>/AGENTS.md (Codex)
  --skip-clinerules  Do not write the fleetest block into <work-dir>/.clinerules (Cline)
  --agent <a>        Which agent conventions to set up: claude / codex / cline / both / all / auto (default auto)
  --no-doctor        Skip the final environment report (fleetest doctor)
  --no-next-steps    Do not print "next steps" (when the caller, e.g. update.sh, guides instead)
  --keep-local       Do not auto-discard local changes in the clone (auto-discard is the default in the external layout)
  --verbose          Also print the raw swift build / npm logs to the screen (default: log file only)
  -h, --help         This help

What it does: clone (git pull if it exists; in the external layout local changes are auto-discarded) /
         swift build / project creation / .gitignore upkeep / VSCode extension / MCP registration /
         CLAUDE.md + AGENTS.md entry points / verification gates. **With --machine and --app-name it also creates profiles (--auto-device)**
         (idempotent; finished steps are skipped)
Exit codes: 0=done / 2=only optional steps incomplete (CLI and MCP work) / 1=stopped at a required step
         (on stop, the [fail] line shows the cause and the number of the manual step to complete)
EOF
}

# 再 exec(下の「自分自身が新しくなったら」)で渡し直すため、パース前に控える
ORIGINAL_ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir) WORK_DIR="${2:?--work-dir requires a value}"; shift 2 ;;
    --name) PROJECT_NAME="${2:?--name requires a value}"; shift 2 ;;
    --app|--app-id) APP_ID="${2:?--app requires a value}"; shift 2 ;;
    --platform) PLATFORM="${2:?--platform requires a value}"; shift 2 ;;
    --app-name) APP_NAME="${2:?--app-name requires a value}"; shift 2 ;;
    --machine) MACHINE="${2:?--machine requires a value}"; shift 2 ;;
    --tool-root) TOOL_ROOT_ARG="${2:?--tool-root requires a value}"; shift 2 ;;
    --no-clone) ALLOW_CLONE=0; shift ;;
    --no-pull) ALLOW_PULL=0; shift ;;
    --skip-extension) DO_EXTENSION=0; shift ;;
    --skip-project) DO_PROJECT=0; shift ;;
    --skip-mcp) DO_MCP=0; shift ;;
    --skip-claude-md) DO_CLAUDE_MD=0; shift ;;
    --skip-agents-md) DO_AGENTS_MD=0; shift ;;
    --skip-clinerules) DO_CLINERULES=0; shift ;;
    --agent) AGENT_ARG="${2:?--agent requires a value}"; shift 2 ;;
    --no-doctor) DO_DOCTOR=0; shift ;;
    --keep-local) KEEP_LOCAL=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --no-next-steps) DO_NEXT_STEPS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

STEPS=()
SOFT_FAILED=0

status_icon() {
  case "$1" in
    ok) printf '✅' ;;
    skip) printf '⏭️ ' ;;
    warn) printf '⚠️ ' ;;
    fail) printf '❌' ;;
    *) printf '・' ;;
  esac
}

# 行頭の [status] は機械可読用(エージェントが warn/fail を拾う)。書式を変えるときは
# SKILL.md の「インストーラの読み方」も直す
step_line() { printf '%s [%s] %s: %s\n' "$(status_icon "$2")" "$2" "$1" "$3"; }

# **その場でも1行出す**。生ログを画面に出さない(既定)ので、結果を最後にまとめて出すだけだと
# クローン〜ビルドの数分間まったく無音になり、人が「止まったのか」を判断できない
record() {
  STEPS+=("$1|$2|$3")
  step_line "$1" "$2" "$3"
}

# 経過時間つきの表示に使う(数分かかる工程がどれだけかかったかを人が見て判断できるように)
elapsed_since() {
  local s=$(( SECONDS - $1 ))
  if [ "$s" -ge 60 ]; then printf '%dm%ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

print_summary() {
  local entry name status detail ok=0 skip=0 attn=0
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r name status detail <<<"$entry"
    case "$status" in
      ok) ok=$((ok + 1)) ;;
      skip) skip=$((skip + 1)) ;;
      *) attn=$((attn + 1)) ;;
    esac
  done
  echo ""
  echo "──────── Install results ────────"
  printf '✅ done %d / ⏭️ skipped %d / ⚠️ needs attention %d\n' "$ok" "$skip" "$attn"
  # 各ステップの1行は実行時に出している。ここで全行を再掲すると同じ表が画面に2つ並ぶので、
  # **要対応(warn/fail)だけ**を再掲する。--verbose のときは生ログに埋もれるので全行を出す
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r name status detail <<<"$entry"
    if [ "$VERBOSE" = "1" ] || [ "$status" = "warn" ] || [ "$status" = "fail" ]; then
      step_line "$name" "$status" "$detail"
    fi
  done
}

die() {
  record "$1" fail "$2"
  print_summary
  echo ""
  echo "❌ Aborted. → Complete .claude/skills/fleetest-setup/SKILL.md step $3 by hand, then"
  echo "   re-run install.sh with the same arguments (finished steps are skipped)." >&2
  [ -n "${LOG_FILE:-}" ] && echo "   Log: $LOG_FILE"
  exit 1
}

soft_fail() {
  record "$1" warn "$2 → SKILL.md step $3"
  SOFT_FAILED=1
}

abspath() { (cd "$1" 2>/dev/null && pwd); }

# package-lock.json は package.json の version を内包する。版上げのときに lock を更新し忘れると、
# 受け手の `npm install` が **version 行だけ**を書き換え、クローンが dirty になって
# **次の更新が pull ガードで必ず止まる**(実害。2026-07-29)。version 行だけの差分は生成物と
# みなして黙って復元する。**それ以外の差分(依存の追加・更新)には触らない**。
# 根治は保守者側の版上げを `npm version --no-git-tag-version` にすること(CLAUDE.md)
restore_lock_version_churn() {
  local lock="vscode-fleetest/package-lock.json" pkg="vscode-fleetest/package.json" stat want added
  [ -d "$TOOL_ROOT/.git" ] || return 0
  git -C "$TOOL_ROOT" diff --quiet -- "$lock" 2>/dev/null && return 0
  # package.json も変わっているなら**保守者の版上げ**(npm version)。lock はそれに追随した正しい
  # 状態なので巻き戻さない
  git -C "$TOOL_ROOT" diff --quiet -- "$pkg" 2>/dev/null || return 0
  # 差分が「ルートの version 2行」ちょうどでなければ人の変更(依存の追加・更新)とみなす。
  # `| head` は使わない(pipefail 下で SIGPIPE を失敗と誤判定する。preflight.sh と同じ罠)
  stat="$(git -C "$TOOL_ROOT" diff --numstat -- "$lock" 2>/dev/null | awk '{print $1"/"$2; exit}')"
  [ "$stat" = "2/2" ] || return 0
  # 増えた側が package.json の version と一致するときだけ = npm install が同期しただけ
  want="$(awk -F'"' '/"version":/{print $4; exit}' "$TOOL_ROOT/$pkg" 2>/dev/null)"
  added="$(git -C "$TOOL_ROOT" diff -U0 -- "$lock" 2>/dev/null \
    | awk -F'"' '/^\+[[:space:]]*"version":/{print $4}' | sort -u || true)"
  [ -n "$want" ] && [ "$added" = "$want" ] || return 0
  if git -C "$TOOL_ROOT" checkout -- "$lock" 2>/dev/null; then
    echo "・Restored the package-lock.json version churn (a generated diff written by npm install)"
  fi
  # **必ず 0 で返す** ―― set -e 下で素の呼び出しをしているので、非0で返すと install.sh が
  # [fail] を1行も出さずに死ぬ(復元できなくても、下の dirty ガードが人に確認すればよい)
  return 0
}

# ---- 0. 前提(SKILL ステップ0) -------------------------------------------------
[ -d "$WORK_DIR" ] || die "prerequisites" "--work-dir does not exist: $WORK_DIR" 0
WORK_DIR="$(abspath "$WORK_DIR")"

# ここから先の出力をすべてログにも落とす(失敗の報告に丸ごと添付できるようにする)。
# 実行のたびに別ファイル(前回の記録を上書きしない)。人への質問は /dev/tty へ直接書くので
# tee の影響を受けない。ログを作れない場合でもインストールは続行する
LOG_FILE=""
if [ -n "${FT_INSTALL_LOG:-}" ]; then
  # 再 exec された2周目。1周目と同じログへ続けて書く
  LOG_FILE="$FT_INSTALL_LOG"
  exec > >(tee -a "$LOG_FILE") 2>&1
elif mkdir -p "$WORK_DIR/.fleetest" 2>/dev/null; then
  LOG_FILE="$WORK_DIR/.fleetest/install-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "==> Log: $LOG_FILE"
  echo "    (build details are not shown on screen; follow them with tail -f '$LOG_FILE' in another terminal)"
fi

# 生ログ(swift build・npm・vsce)の行き先。既定は**ログファイルだけ**に落とす ―― 画面に出すと
# 数万行になり、呼び出し元のエージェントでは「出力が大きすぎる」で切られて、結果表を探すのに
# grep を何度も打つ羽目になる(2026-07-29 の受け手実測で 54KB・grep 4回)。
# --verbose では従来どおり画面にも出す(/dev/stdout は上の tee 経由でログにも入る)。
# ログを作れなかった場合は捨てずに画面へ出す(失敗の手がかりを失わないため)
if [ "$VERBOSE" = "1" ] || [ -z "$LOG_FILE" ]; then
  RAW_SINK="/dev/stdout"
else
  RAW_SINK="$LOG_FILE"
fi
# 失敗したときだけ、生ログの末尾を画面に出す(quiet でも原因が分かるように)
show_log_tail() {
  if [ "$RAW_SINK" != "/dev/stdout" ] && [ -f "$LOG_FILE" ]; then
    echo "── Log just before the failure (last 40 lines; full log: $LOG_FILE) ──"
    tail -40 "$LOG_FILE"
  fi
}

[ "$(uname -s)" = "Darwin" ] || die "prerequisites" "macOS only (the iOS simulator is required)" 0
command -v git >/dev/null 2>&1 || die "prerequisites" "git not found" 0
command -v swift >/dev/null 2>&1 || die "prerequisites" "swift not found (install Xcode)" 0

if ! xcodebuild -version >/dev/null 2>&1; then
  # 原因の切り分け(license 未同意 / xcode-select が CommandLineTools / Xcode 未導入)は
  # preflight.sh に一本化してある。ここでは同じ判定を二重に持たない
  die "prerequisites" "xcodebuild is unusable. Scripts/preflight.sh tells the causes apart (license not accepted / xcode-select pointing at CommandLineTools / Xcode missing — all need sudo, so a human runs the fix)" 0
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  die "prerequisites" "Xcode first-launch setup is incomplete (run xcodebuild -runFirstLaunch)" 0
fi
xcode_version="$(xcodebuild -version 2>/dev/null)"
# `xcodebuild -version | head -1` はダメ(pipefail 下で SIGPIPE を失敗と誤判定する。preflight.sh の
# first_line のコメント参照)。パラメータ展開で1行目を取る
record "prerequisites" ok "macOS $(sw_vers -productVersion) / ${xcode_version%%$'\n'*}"

# ---- 0.5 TOOL_ROOT(SKILL ステップ0.5) ----------------------------------------
# クローン内から実行されたならそれが TOOL_ROOT(curl | bash では $0 が読めないので clone へ倒す)
SELF_ROOT=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
  if [ -n "$candidate" ] && [ -f "$candidate/Package.swift" ] && [ -d "$candidate/Sources/FTScenarioRunner" ]; then
    SELF_ROOT="$candidate"
  fi
fi

if [ -n "$TOOL_ROOT_ARG" ]; then
  TOOL_ROOT_RAW="$TOOL_ROOT_ARG"
elif [ -n "$SELF_ROOT" ]; then
  TOOL_ROOT_RAW="$SELF_ROOT"
else
  TOOL_ROOT_RAW="$WORK_DIR/../foundation-tester"
fi

if [ -d "$TOOL_ROOT_RAW/.git" ] || [ -f "$TOOL_ROOT_RAW/Package.swift" ]; then
  TOOL_ROOT="$(abspath "$TOOL_ROOT_RAW")" || die "clone" "cannot resolve TOOL_ROOT: $TOOL_ROOT_RAW" 0.5
  # 既存クローンは更新してから使う(古いまま build して「入れ直したのに直らない」を防ぐ)。
  # マージコミットを勝手に作らないため ff-only。版固定(detached)は意図的とみなして触らない。
  # ローカル変更の始末(外部構成は自動破棄・それ以外は人に確認)。**REF 経路と pull 経路の
  # 両方から呼ぶ** —— どちらも checkout / pull の前にツリーを綺麗にする必要がある
  settle_local_changes() {
  # 前回の更新が残した npm の版差分を先に片付ける(これを残すと下の dirty ガードで止まる)
  restore_lock_version_churn
  # **外部パッケージ構成ではクローンに受け手の資産が無い**(TestProjects/・プロファイル・.mcp.json は
  # すべて WORK_DIR 側)。そこに出る差分は生成物か上流コードの改変だけなので、聞かずに捨てる
  # ―― 聞くと更新1回あたりの承認が3手増える(ダイアログ + reset + 再実行。受け手実測)。
  # 捨てた内容は画面とログに残す(追跡分は reset、未追跡は clean。どちらも下の行を参照)。
  # clone 構成(保守者・資産が同居)と --keep-local は従来どおり人に確認する
  if [ "$WORK_DIR" != "$TOOL_ROOT" ] && [ "$KEEP_LOCAL" = "0" ] \
     && [ -n "$(git -C "$TOOL_ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "⚠️ Discarding local changes in the clone before updating (external layout; use --keep-local to keep them):"
    git -C "$TOOL_ROOT" status --short
    git -C "$TOOL_ROOT" reset --hard >/dev/null \
      || die "clone" "failed to discard local changes (git reset --hard)" 0.5
    # **未追跡も消す** ―― reset は追跡分しか戻さず、残った未追跡ファイルは下のガードで止まるうえ、
    # 上流に同名ファイルが増えると `pull --ff-only` 自体が失敗する。`-x` は付けない
    # (.gitignore 対象 = .build/・node_modules・.vsix は消さない。消すと再ビルドで数分かかる)。
    # clone 構成では受け手の TestProjects/ が未追跡のことがあるので**外部構成に限る**(この分岐の条件)
    git -C "$TOOL_ROOT" clean -fd >/dev/null 2>&1 || true
  fi
  if [ -n "$(git -C "$TOOL_ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "⚠️ The existing clone has local changes: $TOOL_ROOT"
    git -C "$TOOL_ROOT" status --short | head -20
    answer=""
    # curl | bash では stdin がスクリプト自身なので、質問と回答は端末から直接行う。
    # 制御端末が無い(エージェント・CI)と /dev/tty は存在しても open に失敗するので、
    # test -r ではなく実際に書けたかで判定する。聞けない場合は破棄せず中止する(黙って捨てない・
    # 古いクローンのまま進めない)
    if { printf "Discard the local changes above and update to the latest? [y/N]: " > /dev/tty; } 2>/dev/null; then
      read -r answer < /dev/tty 2>/dev/null || answer=""
    fi
    case "$answer" in
      [yY]*)
        # 追跡ファイルの変更だけを戻す。未追跡は消さない(clone 構成では TestProjects/ が
        # 未追跡のことがあり、git clean で受け手の資産を巻き込む)
        git -C "$TOOL_ROOT" reset --hard >/dev/null \
          || die "clone" "failed to discard local changes (git reset --hard)" 0.5
        echo "   → Discarded the local changes"
        ;;
      *)
        # 古いクローンのまま build すると「入れ直したのに直らない」になるため中止する
        die "clone" "aborted because the local changes were not discarded. Stash or commit them, "\
"or run git reset --hard in $TOOL_ROOT, then re-run" 0.5
        ;;
    esac
  fi
  }

  # ローカル変更は**人に確認してから**破棄する(黙って捨てない)
  if [ "$ALLOW_PULL" = "0" ]; then
    record "clone" skip "using the existing clone as-is (--no-pull): $TOOL_ROOT"
  elif [ ! -d "$TOOL_ROOT/.git" ]; then
    record "clone" skip "using the existing directory (not under git): $TOOL_ROOT"
  elif [ -n "$REF" ]; then
    # **「版固定(detached)」ガードより前に置く** —— FLEETEST_REF は「ここへ動かせ」という
    # 明示指示なので、いまタグに固定されていても従う。後ろに置くと、一度タグへ固定した
    # クローンが二度とブランチへ戻れない(実測で踏んだ)
    settle_local_changes
    echo "==> git fetch + checkout $REF (aligning the existing clone)"
    step_started=$SECONDS
    # **再 exec の判定に使うので fetch の前に控える**。控えないと、揃えた先の新しい
    # install.sh が**その回に1つも実行されない**(CLAUDE.md の再 exec の項と同じ実害)
    HEAD_BEFORE_PULL="$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null || echo none)"
    # **ブランチとそれ以外(タグ・SHA)を分ける**。ブランチは追跡付きで checkout する ——
    # 追跡を張らないと、次に FLEETEST_REF 無しで実行したとき `git pull` が
    # 「no tracking information」で失敗し、**戻れないまま毎回 warn が出る**
    # (しかも既存の warn 文言は network/diverged を疑わせるので切り分けを誤らせる)。
    # タグ・SHA は detached にする(ブランチ名を騙らせない。既存の「版固定」判定と揃う)
    if git -C "$TOOL_ROOT" ls-remote --exit-code --heads origin "$REF" >/dev/null 2>&1; then
      ref_checkout=(checkout -q -B "$REF" --track "origin/$REF")
    else
      ref_checkout=(checkout -q --detach FETCH_HEAD)
    fi
    if git -C "$TOOL_ROOT" fetch --tags origin "$REF" >>"$RAW_SINK" 2>&1 \
       && git -C "$TOOL_ROOT" "${ref_checkout[@]}" >>"$RAW_SINK" 2>&1; then
      record "clone" ok "aligned the existing clone to $REF ($(git -C "$TOOL_ROOT" rev-parse --short HEAD), $(elapsed_since $step_started))"
    else
      show_log_tail
      die "clone" "failed to align $TOOL_ROOT to $REF" 0.5
    fi
  elif ! branch="$(git -C "$TOOL_ROOT" symbolic-ref --short -q HEAD)"; then
    record "clone" skip "using the existing clone (version pinned: $(git -C "$TOOL_ROOT" describe --tags --always 2>/dev/null); FLEETEST_REF=<ref> moves it)"
  else
    settle_local_changes
    echo "==> git pull (updating the existing clone $TOOL_ROOT)"
    step_started=$SECONDS
    HEAD_BEFORE_PULL="$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null || echo none)"
    if git -C "$TOOL_ROOT" pull --ff-only >>"$RAW_SINK" 2>&1; then
      record "clone" ok "updated the existing clone: $TOOL_ROOT ($branch $(git -C "$TOOL_ROOT" rev-parse --short HEAD), $(elapsed_since $step_started))"
    else
      soft_fail "clone" "git pull failed (continuing with the existing clone; check the network or a diverged history)" 0.5
    fi
  fi
else
  [ "$ALLOW_CLONE" = "1" ] || die "clone" "no clone at: $TOOL_ROOT_RAW (--no-clone was given)" 0.5
  echo "==> clone: $REPO_URL → $TOOL_ROOT_RAW"
  step_started=$SECONDS
  git clone ${REF:+--branch "$REF"} "$REPO_URL" "$TOOL_ROOT_RAW" >>"$RAW_SINK" 2>&1 \
    || { show_log_tail; die "clone" "git clone failed${REF:+ (ref: $REF)}" 0.5; }
  TOOL_ROOT="$(abspath "$TOOL_ROOT_RAW")"
  record "clone" ok "$TOOL_ROOT${REF:+ @ $REF} ($(elapsed_since $step_started))"
fi

[ -f "$TOOL_ROOT/Package.swift" ] && [ -d "$TOOL_ROOT/Sources/FTScenarioRunner" ] \
  || die "clone" "$TOOL_ROOT is not a foundation-tester clone" 0.5

# ---- pull で自分自身が新しくなったら、新版で実行し直す ------------------------
# **bash は実行中にファイルが差し替わっても古い内容を最後まで実行する**(git は rename で
# 置換するので、開いた fd は旧 inode を指し続ける。2026-08-06 に実験で確認)。
# そのため update.sh 経由(= クローンの Scripts/install.sh を bash で起動する経路)では、
# **pull で入った新しいステップがその回は1つも実行されない**。しかも次回は update.sh が
# up-to-date で即終了するので**永久に実行されない**(実害: ステップ7.6 の CLAUDE.md が
# 版だけ上がって一度も走らなかった)。スキル既定の curl 形は常に新鮮なので対象外。
#
# 条件は「**いま実行しているファイルが、たった今 pull したクローンの install.sh 自身**」のときだけ。
# ダウンロード済みの控えを実行している場合に再 exec しても意味が無い(同じ古い内容を読み直す)。
if [ "${FT_REEXEC:-0}" != "1" ] && [ -f "$0" ] && [ -n "${HEAD_BEFORE_PULL:-}" ] \
   && [ "$HEAD_BEFORE_PULL" != "$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null || echo none)" ] \
   && [ "$(abspath "$(dirname "$0")")/$(basename "$0")" = "$TOOL_ROOT/Scripts/install.sh" ]; then
  echo "==> The clone moved to a new revision — restarting with the updated install.sh"
  export FT_REEXEC=1 FT_INSTALL_LOG="$LOG_FILE"
  exec bash "$0" "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"
fi

# clone 構成 = 受け手ディレクトリがクローン自身(TestProjects/ はクローン内に作る)
LAYOUT="external"
if [ "$WORK_DIR" = "$TOOL_ROOT" ]; then
  LAYOUT="clone"
fi
record "layout" ok "$LAYOUT (TOOL_ROOT=$TOOL_ROOT / WORK_DIR=$WORK_DIR)"

# ---- どのエージェントの規約位置を用意するか -----------------------------------
# 判定規則は FTCore の AgentIntegration.detect と 1:1(.claude / CLAUDE.md / ~/.claude → claude、
# .agents / AGENTS.md / ~/.codex → codex、どれも無ければ claude 単独 = 既存の受け手の挙動を変えない)。
# 片方だけ変えない —— agentIntegration.test.mjs が Swift 側との一致を見る。
#
# 決め方は3段。**どこから来た決定かを record に出す**(pinned/auto/明示)—— 出さないと、
# 固定されていることに受け手が気づけず「後から Claude Code を入れたのに何も起きない」で詰まる:
#   ① 明示指定(--agent claude|codex|both)が常に勝つ
#   ② 引数なしなら **前回の判定を state.json から引き継ぐ**。引き継がないと `--agent codex` で
#      入れた受け手が更新のたびに自動判定へ戻り、ホームに ~/.claude があるだけで
#      .claude/settings.json と CLAUDE.md が湧く(update.sh は install.sh を呼び直すだけ)
#   ③ `--agent auto` を明示したとき、または記録が無い/壊れているときは判定し直す。
#      **clone 構成では WORK_DIR 側の手掛かりを見ない** —— クローン自身が `.claude/` も
#      `.agents/` も `CLAUDE.md` も持っている(このツールのアダプタであって、受け手が
#      Codex を使っている証拠ではない)。見るとどのクローンでも codex と判定され、
#      クローンの中に AGENTS.md を書いて次の更新を pull ガードで止める
AGENTS=""
AGENT_SOURCE=""
detect_agents() {
  AGENTS=""
  if [ "$LAYOUT" = "clone" ]; then
    if [ -d "$HOME/.claude" ]; then AGENTS="claude"; fi
    if [ -d "$HOME/.codex" ]; then AGENTS="${AGENTS:+${AGENTS} }codex"; fi
    if [ -d "$HOME/.cline" ]; then AGENTS="${AGENTS:+${AGENTS} }cline"; fi
  else
    if [ -d "$WORK_DIR/.claude" ] || [ -f "$WORK_DIR/CLAUDE.md" ] || [ -d "$HOME/.claude" ]; then
      AGENTS="claude"
    fi
    if [ -d "$WORK_DIR/.agents" ] || [ -f "$WORK_DIR/AGENTS.md" ] || [ -d "$HOME/.codex" ]; then
      AGENTS="${AGENTS:+${AGENTS} }codex"
    fi
    # `.clinerules` は**ファイルでもディレクトリでもあり得る**ので -e で見る
    if [ -d "$WORK_DIR/.cline" ] || [ -e "$WORK_DIR/.clinerules" ] || [ -d "$HOME/.cline" ]; then
      AGENTS="${AGENTS:+${AGENTS} }cline"
    fi
  fi
  [ -n "$AGENTS" ] || AGENTS="claude"
}
# **知らない名前を素通しさせない**。素通しすると has_agent がどれにも当たらず、MCP 登録も
# 入口も行われないまま `[ok]` で終わる(= 何もしないのに成功。実際に state.json 経由で踏んだ)
valid_agents() {
  for candidate in $1; do
    case "$candidate" in claude|codex|cline) ;; *) return 1 ;; esac
  done
  [ -n "$1" ]
}
case "$AGENT_ARG" in
  claude|codex|cline) AGENTS="$AGENT_ARG"; AGENT_SOURCE="--agent $AGENT_ARG" ;;
  both)         AGENTS="claude codex"; AGENT_SOURCE="--agent both" ;;
  all)          AGENTS="claude codex cline"; AGENT_SOURCE="--agent all" ;;
  auto)         detect_agents; AGENT_SOURCE="auto (re-detected)" ;;
  "")
    PINNED="$(python3 -c 'import json,sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("agents", ""))
except Exception:
    pass' "$WORK_DIR/.fleetest/state.json" 2>/dev/null || true)"
    if [ -n "$PINNED" ] && valid_agents "$PINNED"; then
      AGENTS="$PINNED"; AGENT_SOURCE="pinned by the previous install (pass --agent auto to re-detect)"
    else
      [ -n "$PINNED" ] && record "agent" warn \
        "state.json records an unknown agent set ($PINNED) — re-detecting"
      detect_agents; AGENT_SOURCE="auto"
    fi
    ;;
  *) die "agent" "--agent must be claude / codex / cline / both / all / auto (got: $AGENT_ARG)" 0.5 ;;
esac
has_agent() { case " $AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
record "agent" ok "$AGENTS — $AGENT_SOURCE"

# **DO_MCP のブロックの外で定義する** —— ステップ7.7(サンドボックス判定)も参照するので、
# `--skip-mcp` のときに未定義だと set -u で落ちる([fail] 行も出ないまま exit 1)。
# `fleetest remote setup` は常に --skip-mcp を渡すので、~/.codex のあるランナー機で必ず踏む
CODEX_CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
# Cline の MCP 登録先(公式が CLI 向けに明記しているユーザーレベルの JSON)。
# **VSCode 拡張は自前の globalStorage を見ることがある**ので、そちらは UI から追加してもらう
CLINE_MCP_JSON="${CLINE_HOME:-$HOME/.cline}/mcp.json"

FT="$TOOL_ROOT/.build/debug/fleetest"

# ---- 1. xcodegen(SKILL ステップ1) --------------------------------------------
if command -v xcodegen >/dev/null 2>&1; then
  record "xcodegen" skip "already installed"
elif command -v brew >/dev/null 2>&1; then
  echo "==> brew install xcodegen"
  if brew install xcodegen; then
    record "xcodegen" ok "installed via brew"
  else
    die "xcodegen" "brew install xcodegen failed (required to generate the iOS bridge)" 1
  fi
else
  die "xcodegen" "neither xcodegen nor Homebrew is available (brew install xcodegen is required)" 1
fi

# ---- 2. ビルド(SKILL ステップ2) ----------------------------------------------
# 変数名の直後に日本語を置くときは必ず ${} で囲む(マルチバイト先頭バイトが変数名に食われる)
echo "==> swift build (${TOOL_ROOT}; the first build takes minutes)"
step_started=$SECONDS
( cd "$TOOL_ROOT" && swift build ) >>"$RAW_SINK" 2>&1 \
  || { show_log_tail; die "build" "swift build failed" 2; }
[ -x "$FT" ] || die "build" "the CLI was not produced: $FT" 2
# MCP サーバは .mcp.json が起動のたびにビルドし直すが、初回だけ先に通しておく(初回起動の失敗回避)
( cd "$TOOL_ROOT" && swift build --product fleetest-mcp ) >/dev/null 2>&1 || true
record "build" ok "$FT ($(elapsed_since $step_started))"

# ---- 4 の前: Bash 許可リストの補修(承認回数を減らす) --------------------------
# **毎回呼ぶ**。許可リストは従来 `fleetest init` でしか書かれず、更新は --skip-project で init を
# 回さないため、エントリを増やしても**既存の受け手には一生届かなかった**(実害: 更新のたびに
# update.sh の承認が出る)。冪等・追加のみ・fleetest 由来のコマンドだけ(ProjectScaffold が保証)
# **--agent を渡す**。渡さないと CLI 側が独自に判定し、受け手のホームに ~/.claude が
# あるだけで Codex 専用の導入に .claude/settings.json ができる(実際に踏んだ)
if perms_out="$( "$FT" api ensure-settings --work-dir "$WORK_DIR" --tool-root "$TOOL_ROOT" \
                   --agent "${AGENTS// /,}" 2>&1 )"; then
  record "permissions" ok "$perms_out"
else
  record "permissions" warn "could not top up (only means more approval prompts; behaviour is unaffected)"
fi

# ---- 4. プロジェクト作成(SKILL ステップ4) ------------------------------------
project_exists() {
  [ -n "$PROJECT_NAME" ] && [ -d "$WORK_DIR/TestProjects/$PROJECT_NAME" ]
}

# 省略可能な引数は配列で渡す(空文字列を引数として渡さないため)
APP_ARGS=()
[ -n "$APP_ID" ] && APP_ARGS=(--app "$APP_ID")
# 指示していないプラットフォームの run を作らない(machines と runs の名前不整合の温床)
PLATFORM_ARGS=(--platform "$PLATFORM")
NAME_ARGS=()
[ -n "$PROJECT_NAME" ] && NAME_ARGS=(--name "$PROJECT_NAME")

if [ "$DO_PROJECT" = "0" ]; then
  record "project" skip "--skip-project"
elif project_exists; then
  record "project" skip "TestProjects/$PROJECT_NAME already exists"
elif [ "$LAYOUT" = "clone" ]; then
  [ -n "$PROJECT_NAME" ] || die "project" "--name is required in the clone layout" 4
  echo "==> fleetest project create $PROJECT_NAME"
  ( cd "$WORK_DIR" && "$FT" project create "$PROJECT_NAME" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" \
      "${PLATFORM_ARGS[@]}" ) || die "project" "project create failed" 4
  record "project" ok "TestProjects/$PROJECT_NAME"
elif [ -f "$WORK_DIR/Package.swift" ]; then
  # fleetest と無関係の既存パッケージへの導入は事故になる(init も拒否する)
  grep -q "fleetest projects begin\|foundation-tester" "$WORK_DIR/Package.swift" \
    || die "project" "$WORK_DIR/Package.swift is not an fleetest package (run this in an empty, test-only directory)" 0
  # 受け手パッケージは確立済み。プロジェクトだけ追加する
  [ -n "$PROJECT_NAME" ] || die "project" "--name is required to add to an existing package" 4
  echo "==> fleetest project create $PROJECT_NAME"
  ( cd "$WORK_DIR" && "$FT" project create "$PROJECT_NAME" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" \
      "${PLATFORM_ARGS[@]}" ) || die "project" "project create failed" 4
  record "project" ok "TestProjects/$PROJECT_NAME (added to the existing package)"
else
  # 新規の受け手パッケージ。TOOL_ROOT はローカルパス依存で引く(git 依存は手動・SKILL ステップ4参照)
  echo "==> fleetest init($WORK_DIR)"
  ( cd "$WORK_DIR" && "$FT" init --fleetest-path "$TOOL_ROOT" --agent "${AGENTS// /,}" \
      "${NAME_ARGS[@]+"${NAME_ARGS[@]}"}" "${APP_ARGS[@]+"${APP_ARGS[@]}"}" "${PLATFORM_ARGS[@]}" ) \
    || die "project" "fleetest init failed" 4
  record "project" ok "created the consumer package${PROJECT_NAME:+ (TestProjects/$PROJECT_NAME)}"
fi

# ---- 4 の検証ゲート: .gitignore(SKILL ステップ4) -----------------------------
# clone 構成(WORK_DIR = クローン自身)では触らない。リポジトリの .gitignore は本体が管理しており、
# ここで追記すると**クローンが dirty になり、次回の更新が pull ガードで止まる**
if [ "$LAYOUT" = "clone" ]; then
  record ".gitignore" skip "clone layout (managed by the repository)"
elif [ -d "$WORK_DIR/.git" ]; then
  added=""
  # 対の実装: FTCore.ProjectScaffold.ensureGitignore(fleetest init が使う)。片方だけ変えない
  for line in ".build/" ".fleetest/" "TestProjects/*/reports/"; do
    if ! grep -qxF "$line" "$WORK_DIR/.gitignore" 2>/dev/null; then
      printf '%s\n' "$line" >> "$WORK_DIR/.gitignore"
      added="$added $line"
    fi
  done
  if [ -n "$added" ]; then
    record ".gitignore" ok "appended:$added"
  else
    record ".gitignore" skip "already in shape"
  fi
else
  record ".gitignore" skip "not a git repository"
fi

# ---- 7. VSCode 拡張(SKILL ステップ7) -----------------------------------------
if [ "$DO_EXTENSION" = "0" ]; then
  record "extension" skip "--skip-extension"
elif ! command -v npm >/dev/null 2>&1; then
  soft_fail "extension" "npm is missing (install Node.js, then run npm run install-local in vscode-fleetest)" 7
else
  echo "==> Building and installing the VSCode extension"
  step_started=$SECONDS
  if ( cd "$TOOL_ROOT/vscode-fleetest" && npm install && npm run install-local ) >>"$RAW_SINK" 2>&1; then
    record "extension" ok "installed (takes effect after Reload Window; $(elapsed_since $step_started))"
  else
    show_log_tail
    soft_fail "extension" "npm install / install-local failed (the CLI and MCP still work)" 7
  fi
  # npm install が書き換えた版差分をここでも片付ける(次回の更新を止めないため。冪等)
  restore_lock_version_churn
fi

# ---- 7.5 MCP サーバ登録(SKILL ステップ7.5) -----------------------------------
# 登録先はエージェントごとに違う(AgentIntegration.mcpRegistrationTarget):
#   Claude Code → <WORK_DIR>/.mcp.json(プロジェクトスコープ・JSON)
#   Codex       → ~/.codex/config.toml の [mcp_servers.fleetest](ユーザーレベル・TOML)
# **Codex のプロジェクトスコープ .codex/config.toml は使わない** —— あれは
# `~/.codex/config.toml` 側で trust されたプロジェクトでしか読まれないので、書いても
# 黙って効かない状態を作れてしまう(沈黙の失敗は作らない)。
if [ "$DO_MCP" = "0" ]; then
  record "MCP" skip "--skip-mcp"
else

# **clone 構成でもここで書く**(2026-08-27)。以前は repo ルートの `.mcp.json` を同梱して
# 済ませていたが、**プラグイン root = repo ルートなのでそれがプラグインに載って配られ**、
# 中身の `$PWD/Scripts/mcp-server.sh` はクローンの外では存在しないため、受け手が別の場所で
# エージェントを起動するたびに MCP が落ちていた(Codex: connection closed / Claude: plugin
# details に MCP servers (1))。同梱をやめ、どちらの構成でも**絶対パス**で登録する。
# 書き先はクローン自身になるので `.gitignore` 済み(追跡すると次の更新が pull ガードで止まる)。
# `.mcp.json` 形式(Claude Code と Cline)。**登録先だけが違うので実装は1つ**にする ——
# 写しを増やすと、片方だけ直したときに黙って挙動が割れる
merge_mcp_json() {
  mcp_path="$1"
  mcp_label="$2"
  if ! command -v python3 >/dev/null 2>&1; then
    soft_fail "MCP($mcp_label)" "python3 is missing, so $mcp_path cannot be merged (write the SKILL template by hand)" 7.5
    return 0
  fi
  if merge_out=$(python3 - "$mcp_path" "$TOOL_ROOT" <<'PYMCPJSON'
import json, os, sys

path, tool_root = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            print("INVALID %s" % e, end="")
            sys.exit(3)
servers = data.setdefault("mcpServers", {})
previous = servers.get("fleetest", {}).get("env", {}).get("FT_TOOL_ROOT")
# cwd は受け手パッケージ(TestProjects/ の在り処)、FT_TOOL_ROOT はツール本体(ブリッジ資産)。
# ビルドのため TOOL_ROOT へ cd したあと exec 前に元の cwd へ戻すのが必須。
# ランチャは Scripts/mcp-server.sh(鮮度判定・ログ・失敗の可視化はあちら)。
# **1行のシェル式を埋め込まない**: 起動のたびに約8秒の no-op ビルドを払い、失敗しても
# /dev/null で黙って起動しなかった(2026-08-06 の外部フィードバック)
servers["fleetest"] = {
    "command": "bash",
    "args": ["-lc", 'exec "%s/Scripts/mcp-server.sh"' % tool_root],
    "env": {"FT_TOOL_ROOT": tool_root},
}
# 登録先はプロジェクト内(.mcp.json)とユーザーレベル(~/.cline/mcp.json)の両方がある。
# 後者は親ディレクトリが無いことがあるので作る
parent = os.path.dirname(path)
if parent:
    os.makedirs(parent, exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
if previous and previous != tool_root:
    print("REPLACED %s" % previous, end="")
else:
    print("OK", end="")
PYMCPJSON
  ); then
    case "$merge_out" in
      REPLACED*) record "MCP($mcp_label)" ok "updated $mcp_path (replaced the old TOOL_ROOT ${merge_out#REPLACED }; delete the old clone if unneeded)" ;;
      *) record "MCP($mcp_label)" ok "registered fleetest in $mcp_path" ;;
    esac
  else
    soft_fail "MCP($mcp_label)" "failed to merge $mcp_path ($merge_out)" 7.5
  fi
}

# **clone 構成でもここで書く**。以前は repo ルートの `.mcp.json` を同梱して済ませていたが、
# **プラグイン root = repo ルートなのでそれがプラグインに載って配られ**、中身の
# `$PWD/Scripts/mcp-server.sh` はクローンの外では存在しないため、受け手が別の場所で
# エージェントを起動するたびに MCP が落ちていた(Codex: connection closed / Claude: plugin
# details に MCP servers (1))。同梱をやめ、どちらの構成でも**絶対パス**で登録する。
# 書き先はクローン自身になるので `.gitignore` 済み(追跡すると次の更新が pull ガードで止まる)。
if ! has_agent claude; then
  : # Claude Code を使わない受け手には .mcp.json を作らない
else
  merge_mcp_json "$WORK_DIR/.mcp.json" claude
fi

# Cline。登録先は**ユーザーレベルの ~/.cline/mcp.json**(公式が CLI 向けに明記している場所)。
# 形は .mcp.json と同じ mcpServers なので実装を共有する。**VSCode 拡張は自前の
# globalStorage を見ることがある**ので、その場合は UI の「Edit MCP Settings」から同じ内容を足す
if ! has_agent cline; then
  : # Cline を使わない受け手には ~/.cline を作らない
else
  merge_mcp_json "$CLINE_MCP_JSON" cline
fi

# Codex 側。**`codex` のサブコマンド名に依存しない** —— このインストーラは codex が入って
# いない機械でも回るし、CLI の引数体系はここで検証できないので、TOML を自分で扱う。
# 安全側の規律3つ:
#   ① 既存の [mcp_servers.fleetest] が無いときだけ**末尾に追記**する(既存行に触らない。
#      TOML はテーブル見出しで前のテーブルが終わるので、末尾追記は常に妥当)
#   ② 既にあって TOOL_ROOT が違うときは**書き換えず**、既存テーブルの値を差し替えるよう案内する
#      (コメント付き TOML の書き換えは受け手の設定を壊しうる。**追記させない** ——
#      同じテーブルが2つになると config.toml 全体が無効になる)
#   ③ tomllib(python 3.11+)で読めないときは1バイトも書かない
if ! has_agent codex; then
  : # Codex を使わない受け手には ~/.codex を作らない
elif ! command -v python3 >/dev/null 2>&1; then
  soft_fail "MCP(codex)" "python3 is missing, so $CODEX_CONFIG cannot be updated" 7.5
else
  if codex_out=$(python3 - "$CODEX_CONFIG" "$TOOL_ROOT" <<'PYCODEX'
import os, sys

path, tool_root = sys.argv[1], sys.argv[2]
launcher = "%s/Scripts/mcp-server.sh" % tool_root
# 起動の中身は Scripts/mcp-server.sh(Claude 側と同一のランチャ)。
# **cwd は書かない** —— cwd は受け手パッケージの特定に使うので、エージェントが開いた
# ディレクトリのままにする必要がある(mcp-server.sh の規律と対)。
block = (
    "\n# fleetest (foundation-tester) — added by Scripts/install.sh\n"
    "[mcp_servers.fleetest]\n"
    'command = "bash"\n'
    'args = ["-lc", "exec \\"%s\\""]\n'
    "\n[mcp_servers.fleetest.env]\n"
    'FT_TOOL_ROOT = "%s"\n'
) % (launcher, tool_root)

try:
    import tomllib
except ModuleNotFoundError:
    print("NOTOML%s" % block, end="")
    sys.exit(0)

existing = ""
data = {}
if os.path.exists(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        data = tomllib.loads(raw.decode("utf-8"))
    except Exception as e:
        print("INVALID %s" % e, end="")
        sys.exit(3)
    existing = raw.decode("utf-8")

current = data.get("mcp_servers", {}).get("fleetest")
if current is not None:
    previous = (current.get("env") or {}).get("FT_TOOL_ROOT")
    if previous == tool_root:
        print("PRESENT", end="")
    else:
        print("DIFFERS %s\n%s" % (previous, block), end="")
    sys.exit(0)

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "a" if existing else "w") as f:
    if existing and not existing.endswith("\n"):
        f.write("\n")
    f.write(block)
print("ADDED", end="")
PYCODEX
  ); then
    case "$codex_out" in
      PRESENT) record "MCP(codex)" ok "already registered in $CODEX_CONFIG" ;;
      ADDED) record "MCP(codex)" ok "registered fleetest in $CODEX_CONFIG" ;;
      DIFFERS*)
        record "MCP(codex)" warn "$CODEX_CONFIG already points fleetest at a different TOOL_ROOT — left it alone; to switch, replace the values in the existing [mcp_servers.fleetest] tables (do NOT append — a duplicated table invalidates the whole file):"
        printf '%s\n' "${codex_out#DIFFERS }" ;;
      NOTOML*)
        record "MCP(codex)" warn "python3 has no tomllib (3.11+ required), so $CODEX_CONFIG could not be inspected — add this only if [mcp_servers.fleetest] is not already there (a duplicated table invalidates the whole file):"
        printf '%s\n' "${codex_out#NOTOML}" ;;
      *) soft_fail "MCP(codex)" "failed to update $CODEX_CONFIG ($codex_out)" 7.5 ;;
    esac
  else
    soft_fail "MCP(codex)" "failed to update $CODEX_CONFIG ($codex_out)" 7.5
  fi
fi

fi

# ---- 7.6 エージェントの入口(SKILL ステップ7.6) --------------------------------
# **導入直後ではなく、その後のセッションのための手当て**。MCP 登録も .claude/settings.json も
# 「設定として効く」だけでエージェントが読む物ではないので、これが無いと翌週
# 「このアプリのテスト書いて」と言われたエージェントの手掛かりはスキルの description だけになる。
# 実害は3つに絞られる(素の XCTest を書き始める / 新しい ft_* に気づかない /
# DSL コマンドを推測で書く)ので、**使い方の解説は書かず入口だけ4行**置く
# —— 解説を置くとツール説明と二重管理になり必ずズレる(docs/design.md「契約は1箇所」)。
# 受け手の資産なので**マーカーの内側だけ**差し替える。共有リポジトリで嫌うなら
# --skip-claude-md / --skip-agents-md。
#
# 書き先はエージェントごと(AgentIntegration.entryPointFile): Claude Code=CLAUDE.md /
# Codex=AGENTS.md。**本文は同じで、違うのはスキルの呼び出し記法だけ**(/ と $)。
write_entry_point() {
  ep_file="$WORK_DIR/$1"
  ep_prefix="$2"
  ep_label="$3"
  # **クローンの作業ツリーの中には書かない**(2026-08-07 に自己破壊を再現)。
  # clone 構成(WORK_DIR = TOOL_ROOT)で入口ファイルへ書くと、次の更新が pull ガード
  # (「local changes」)で必ず止まる。しかも `git reset --hard` で戻しても次の更新が
  # 同じブロックを書くので**同じ状態に戻る**。
  # **判定は「追跡されているか」ではなく「クローンの中か」** —— `git status --porcelain` は
  # 未追跡ファイルも dirty と数えるので、追跡の有無で見ると **まだ存在しない AGENTS.md が
  # 素通りして**同じ轍を踏む(CLAUDE.md はクローンの追跡ファイルなので追跡判定でも
  # 止まっていたが、AGENTS.md は追跡も gitignore もされていない)。
  # 外部構成で受け手が自分のリポジトリに入口を持つのは対象外(クローンの pull を妨げない)。
  # **判定できなければ書かない**(fail-closed)—— 受け手の資産を壊す側に倒れるより、
  # 案内を1つ諦めるほうが安い。
  # 同型: packageLockSync(npm install が lock を書き換えてクローンが dirty になる)
  if [ "$(python3 -c 'import os,sys
target, clone = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
print("inside" if os.path.commonpath([target, clone]) == clone else "outside")' \
       "$ep_file" "$TOOL_ROOT" 2>/dev/null || echo inside)" = "inside" ]; then
    record "$ep_label" skip "it lives inside the clone — writing there would make the next update abort at the pull guard"
    return 0
  fi
  mkdir -p "$(dirname "$ep_file")" 2>/dev/null || true
  if guide_out=$(python3 - "$ep_file" "$ep_prefix" <<'PYGUIDE'
import os, re, sys

path, prefix = sys.argv[1], sys.argv[2]
# **マーカーは最短・不変にする**。説明文をマーカー行に埋めると、文言を変えた瞬間に
# 既存ブロックを見失って**二重に追記される**。前置き一致で拾い、説明は本文の側に置く。
BEGIN = "<!-- fleetest:begin -->"
END = "<!-- fleetest:end -->"
BODY = """## テスト(fleetest)

<!-- この範囲は Scripts/install.sh が管理しており、更新のたび上書きされます。
     不要なら begin〜end ごと削除するか、インストーラに --skip-claude-md /
     --skip-agents-md / --skip-clinerules を渡してください。 -->

- シナリオ作成は `%(p)sfleetest-scenario`、対象アプリ/デバイスの追加は `%(p)sfleetest-profiles`、更新は `%(p)sfleetest-update`
- 画面の探索・操作は `ft_*` ツール。**長いリストは `ft_swipe` の繰り返しでなく `ft_scroll_to`**
- DSL のコマンド名は推測せず `ft_dsl_commands` で索引を引く(無いコマンドを書かないため)
- シナリオは `TestProjects/<プロジェクト>/scenarios/*.swift`。実行は `ft_run_scenario` か VSCode 拡張""" % {"p": prefix}
block = BEGIN + "\n" + BODY + "\n" + END

existing = ""
if os.path.exists(path):
    with open(path) as f:
        existing = f.read()

# **マーカーが1組でないなら何も書かない**(2026-08-06。実際に消して確認した)。
# 素朴に「最初の begin 〜 最初の end」を置換すると、end だけ壊れた入口ファイルで
# 1回目に2つ目のブロックを追記 → 2回目に**間に挟まれた利用者の記述ごと**置換して消す。
# 受け手の資産を黙って壊すくらいなら、案内を諦めて人に直してもらうほうがよい。
# 行頭に限って数える(散文やコード例の中の言及に反応しないため)。
begins = len(re.findall(r"(?m)^[ \t]*<!--\s*fleetest:begin", existing))
ends = len(re.findall(r"(?m)^[ \t]*<!--\s*fleetest:end\s*-->", existing))
span = None
if begins == 1 and ends == 1:
    span = re.search(r"(?ms)^[ \t]*<!--\s*fleetest:begin.*?<!--\s*fleetest:end\s*-->", existing)

if begins == 0 and ends == 0:
    if existing.strip():
        updated = existing.rstrip("\n") + "\n\n" + block + "\n"
        verb = "appended to"
    else:
        updated = block + "\n"
        verb = "created"
elif span:
    updated = existing[: span.start()] + block + existing[span.end():]
    verb = "unchanged" if updated == existing else "refreshed"
else:
    # begin/end が 0組でも1組でもない(片方だけ・2組以上・逆順)
    updated = existing
    verb = "damaged"

if updated != existing:
    with open(path, "w") as f:
        f.write(updated)
print(verb, end="")
PYGUIDE
  ); then
    case "$guide_out" in
      damaged)
        record "$ep_label" warn "the fleetest markers in $1 are not a single begin/end pair"\
" — left the file untouched (fix or remove them by hand, then re-run)" ;;
      *)
        record "$ep_label" ok "$guide_out $1 (delete the fleetest block, or pass the matching --skip-claude-md / --skip-agents-md / --skip-clinerules, to opt out)" ;;
    esac
  else
    record "$ep_label" warn "could not write the entry point to $1 (agents may miss ft_*)"
  fi
}

if ! command -v python3 >/dev/null 2>&1; then
  record "entry point" warn "python3 is missing, so the entry point was not written (agents may miss ft_*)"
else
  if [ "$DO_CLAUDE_MD" = "0" ]; then
    record "CLAUDE.md" skip "--skip-claude-md"
  elif has_agent claude; then
    write_entry_point "CLAUDE.md" "/" "CLAUDE.md"
  fi
  if [ "$DO_AGENTS_MD" = "0" ]; then
    record "AGENTS.md" skip "--skip-agents-md"
  elif has_agent codex; then
    write_entry_point "AGENTS.md" "\$" "AGENTS.md"
  fi
  # Cline の `.clinerules` は**ファイルでもディレクトリでもあり得る**。ディレクトリのときに
  # そのパスへ書くと失敗するので、中の `fleetest.md` へ振り替える(Cline はフォルダ内の
  # 各ファイルを読む)。受け手が単体ファイルで運用しているならそのまま追記する
  if [ "$DO_CLINERULES" = "0" ]; then
    record ".clinerules" skip "--skip-clinerules"
  elif has_agent cline; then
    if [ -d "$WORK_DIR/.clinerules" ]; then
      write_entry_point ".clinerules/fleetest.md" "/" ".clinerules/fleetest.md"
    else
      write_entry_point ".clinerules" "/" ".clinerules"
    fi
  fi
fi

# ---- 7.7 Codex サンドボックスの適合判定(SKILL ステップ7.7) --------------------
# **判定するが緩めない**。`~/.codex/config.toml` の sandbox_mode は**受け手のグローバル設定であり
# セキュリティ境界**なので、インストーラは1バイトも書かない。出すのは事実と選択肢だけ。
#
# **実測で分かった構造(2026-08-27。writable_roots では直らない)**:
#   ・`swift build` / `swift package` は **workspace-write の中では起動できない** ——
#     SwiftPM が自前で `sandbox-exec` を入れ子に使い `sandbox_apply: Operation not permitted`
#   ・`xcrun simctl` も通らない —— CoreSimulatorService への mach 接続が塞がれる
#   ・`adb` は通る(TCP 5037 なので network_access で足りる)
#   したがって **network_access と writable_roots をどう積んでも workspace-write は救えない**。
#   これらを「揃えれば OK」と報告していた頃は false green で、受け手の切り分けを誤らせた。
#
# **一方 MCP サーバはサンドボックスの外で動く**(実測: --sandbox read-only でもワークスペース外
# 書込と loopback が通る)。つまり `ft_*` 経由の作成・実行・デバイス駆動は既定設定のまま動き、
# 通らないのは**エージェントがシェルで叩く導入・更新**だけ。ここを取り違えない。
if ! has_agent codex; then
  : # Codex を使わない受け手には関係しない
elif ! command -v python3 >/dev/null 2>&1; then
  record "codex sandbox" warn "python3 is missing, so $CODEX_CONFIG could not be inspected"
else
  if sandbox_out=$(python3 - "$CODEX_CONFIG" <<'PYSANDBOX'
import os, sys

path = sys.argv[1]

# **選択肢は2つだけ**。どちらも受け手が決めること(このスクリプトは書かない)。
advice = (
    "Codex runs shell commands inside a sandbox. `swift build` cannot start there (SwiftPM nests\n"
    "its own sandbox-exec) and `xcrun simctl` cannot reach CoreSimulatorService, so the install and\n"
    "update runbooks will not complete. Adding network_access or writable_roots does NOT fix this.\n"
    "\n"
    "What still works with no change: everything through the MCP server (ft_* tools) — authoring,\n"
    "running scenarios and driving devices. The MCP server runs outside the sandbox.\n"
    "\n"
    "Pick one:\n"
    "  (a) run the install/update sessions only with `codex --sandbox danger-full-access`\n"
    "      and keep the default sandbox for everyday work  ← narrower, recommended\n"
    "  (b) set `sandbox_mode = \"danger-full-access\"` in the config to relax it permanently\n"
)

try:
    import tomllib
except ModuleNotFoundError:
    print("UNKNOWN python3 has no tomllib (3.11+)\n%s" % advice, end=""); sys.exit(0)
if not os.path.exists(path):
    print("LIMITED %s does not exist yet, so the default sandbox applies\n%s" % (path, advice), end="")
    sys.exit(0)
try:
    with open(path, "rb") as f:
        data = tomllib.load(f)
except Exception as e:
    print("UNKNOWN could not parse %s (%s)\n%s" % (path, e, advice), end=""); sys.exit(0)

mode = data.get("sandbox_mode", "workspace-write")
if mode == "danger-full-access":
    print("OK sandbox_mode=danger-full-access (shell steps can run)", end="")
else:
    print("LIMITED sandbox_mode=%s\n%s" % (mode, advice), end="")
PYSANDBOX
  ); then
    case "$sandbox_out" in
      OK*) record "codex sandbox" ok "${sandbox_out#OK }" ;;
      LIMITED*)
        sandbox_head="${sandbox_out#LIMITED }"
        record "codex sandbox" warn "${sandbox_head%%$'\n'*} — ft_* keeps working, but the install/update runbooks cannot run under it (nothing was written; see below)"
        printf '%s\n' "${sandbox_out#*$'\n'}" ;;
      UNKNOWN*)
        sandbox_head="${sandbox_out#UNKNOWN }"
        record "codex sandbox" warn "could not verify the sandbox: ${sandbox_head%%$'\n'*} (see below if the runbooks do not complete)"
        printf '%s\n' "${sandbox_out#*$'\n'}" ;;
      *) record "codex sandbox" warn "unexpected verdict ($sandbox_out)" ;;
    esac
  else
    record "codex sandbox" warn "could not inspect $CODEX_CONFIG"
  fi
fi

# ---- 5. プロファイル(SKILL ステップ5。--machine と --app-name があるときだけ) ----------
# デバイス選定は profile setup --auto-device に任せる(エージェントが simctl / emulator を
# 個別に叩くと承認回数が増える)。失敗しても導入自体は完了しているので warn 止まり
if [ "$DO_PROJECT" = "0" ]; then
  record "profiles" skip "--skip-project"
elif [ -z "$MACHINE" ] || [ -z "$APP_NAME" ]; then
  record "profiles" skip "not created without --machine and --app-name (use /fleetest-profiles)"
else
  echo "==> fleetest profile setup (--auto-device)"
  if ( cd "$WORK_DIR" && "$FT" profile setup --platform "$PLATFORM" --auto-device \
        --machine "$MACHINE" --app-name "$APP_NAME" \
        ${PROJECT_NAME:+--project "$PROJECT_NAME"} --app-id "${APP_ID:-com.example.myapp}" ); then
    record "profiles" ok "machines/$MACHINE.json + apps + runs ($PLATFORM)"
  else
    soft_fail "profiles" "profile setup failed (no devices etc.; /fleetest-profiles can redo it)" 5
  fi
fi

# ---- 検証ゲート: ルート解決(SKILL ステップ7.5 の検証ゲート) -------------------
# ツール本体(ブリッジ資産)と受け手パッケージ(TestProjects/)の取り違えは ft_* を全滅させる。
# 表示された解決結果が、このインストールで意図した2ディレクトリと一致するかまで見る
if ! roots=$( cd "$WORK_DIR" && "$FT" doctor --roots-only 2>&1 ); then
  record "root-resolution" fail "$(printf '%s' "$roots" | tr '\n' ' ')"
  print_summary
  echo ""
  echo "❌ Cannot resolve the tool root. → See the verification gate in SKILL.md step 7.5" >&2
  exit 1
fi
# /private/tmp と /tmp(や /private/var と /var)は同じ場所。Foundation の
# resolvingSymlinksInPath は /private を落とし、シェルの pwd は付けるので、
# 突き合わせ前に両側から /private を外す(実測で食い違った)
unprivate() { printf '%s' "$1" | sed 's|^/private/|/|'; }
roots_norm="$(printf '%s' "$roots" | sed 's|/private/|/|g')"
roots_ok=1
printf '%s' "$roots_norm" | grep -qF "$(unprivate "$TOOL_ROOT")" || roots_ok=0
if [ -f "$WORK_DIR/Package.swift" ]; then
  printf '%s' "$roots_norm" | grep -qF "$(unprivate "$WORK_DIR")" || roots_ok=0
fi
if [ "$roots_ok" = "1" ]; then
  record "root-resolution" ok "tool root=$TOOL_ROOT / package=$WORK_DIR"
else
  record "root-resolution" fail "resolved to unintended roots: $(printf '%s' "$roots" | tr '\n' ' ')"
  print_summary
  echo ""
  echo "❌ Resolved to a different clone/package (suspect leftovers of an old clone)." >&2
  echo "   → See the verification gate in SKILL.md step 7.5 and the uninstall section of docs/user-docs/getting-started.md" >&2
  exit 1
fi

# ---- 2.5 Apple Intelligence(SKILL ステップ2.5・不可でも続行) -----------------
if "$FT" doctor --fm-only >/dev/null 2>&1; then
  record "Apple Intelligence" ok "available"
else
  record "Apple Intelligence" warn "off/not downloaded (only affects heal, visual verification and scenario generation; can be enabled later)"
fi

# ---- 3. 環境レポート(SKILL ステップ3。ゲートではない) ------------------------
if [ "$DO_DOCTOR" = "1" ]; then
  echo ""
  echo "==> fleetest doctor (environment report)"
  ( cd "$WORK_DIR" && "$FT" doctor ) || true
fi

# ---- 導入時点の版を記録(判定には使わない。更新が反映されないときの切り分け用) ----------
# 更新チェック本体(Scripts/update-check.sh)は git を直接見るのでこのファイルに依存しない。
# ここに書くのは「いつ・どの版を入れたか」だけ。書けなくてもインストールは成功扱い
if [ -d "$WORK_DIR/.fleetest" ]; then
  cat >"$WORK_DIR/.fleetest/state.json" 2>/dev/null <<EOF || true
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "toolRoot": "$TOOL_ROOT",
  "toolRootHead": "$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null)",
  "toolRootRef": "$(git -C "$TOOL_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)",
  "agents": "$AGENTS"
}
EOF
fi

NEXT_PROFILES=""
case " ${STEPS[*]} " in
  *"profiles|ok"*) : ;;
  *) NEXT_PROFILES="・Create the profiles (machine/app/run) → /fleetest-profiles in Claude Code
" ;;
esac

print_summary

[ "$DO_NEXT_STEPS" = "1" ] && cat <<EOF

──────── Next steps ────────
${NEXT_PROFILES}・Open $WORK_DIR in VSCode and run Developer: Reload Window (required for the extension)
・When Claude Code asks to approve the fleetest MCP server, allow it (enables the ft_* tools)

Updates: the VSCode extension checks automatically on start-up (disable via the fleetest.updateCheck setting).
      Check manually → bash $TOOL_ROOT/Scripts/update-check.sh / apply → /fleetest-update
Install log: ${LOG_FILE:-(could not be written)}
EOF

if [ "$SOFT_FAILED" = "1" ]; then
  echo ""
  echo "⚠️ Some optional steps are incomplete (the ⚠️ lines above). The CLI and MCP still work."
  exit 2
fi
echo ""
echo "✅ Install complete"

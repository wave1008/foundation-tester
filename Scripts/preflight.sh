#!/usr/bin/env bash
# 状態判定(読み取りのみ・何も変更しない)。既定モードはインストール前の判定(カレント = WORK_DIR
# 候補)。`--runner` はランナー機(`ftester run --host` / docs/remote-runner.md §5・§14)としての判定。
#
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/preflight.sh | bash
#   bash Scripts/preflight.sh
#   bash Scripts/preflight.sh --runner [--base <dir>]   # --base 既定は ~/ftester-runner
#
# 既定モード: **カレントディレクトリだけを判定対象**にする(どこで実行したかが答えを変えるため)。
# --runner モード: `<base>/foundation-tester`(クローン)・`<base>/work`(WORK_DIR)を判定対象にする
# (docs/remote-runner.md §14「構成」)。**sudo を使わない・何も書き換えない** — FileVault・
# 自動ログイン・スリープ・sshd の有効化はここでは行わず、人間がやる手順を案内するだけ。
#
# 出力は `key=value` 行(機械可読)+ 末尾の判定。判定は verdict= と終了コードの両方に出る:
#   既定モード: 0 = ready      … 未導入。ここに install.sh / ftester-setup で導入できる
#               2 = installed  … 導入済み(外部パッケージ構成が確立済み)。更新は /ftester-update
#               1 = blocked    … ここには導入できない(ftester と無関係の Package.swift・必須環境の欠落)
#   --runner:   0 = ready        … ランナーとして使える
#               2 = needs-manual … 人手の手順が残っている(列挙する)
#               1 = blocked      … 必須トールチェーンが欠落
#
# 契約: 既定モードの判定分岐は .claude/skills/ftester-setup/SKILL.md のステップ0(再実行ガード・
#       環境判定)と 0.5(構成判定)と 1:1。片方だけ変えない。**既定モードの出力は1バイトも変えない**。
set -uo pipefail

say() { printf '%s\n' "$1"; }
kv()  { printf '%s=%s\n' "$1" "$2"; }

# **`cmd | head` を条件式や値の取得に使わない**(このスクリプトは pipefail)。head が先に閉じると
# 上流が SIGPIPE(141)で死に、pipefail がそれを失敗として拾う。実害: 正常に動く Xcode を
# `xcode=unusable` と誤判定し、受け手に無関係な license 同意を案内した(2026-07-29)
first_line() { printf '%s' "${1%%$'\n'*}"; }

# ---- 引数解析 -------------------------------------------------------------------
MODE=default
# `--remote-dir` の既定値(Sources/ftester/FTester.swift・ApiRunCommand.swift・RemoteCommands.swift)と
# 揃える。ズレるとディスパッチ側とランナー判定が別ディレクトリを見る
BASE="~/ftester-runner"
while [ $# -gt 0 ]; do
  case "$1" in
    --runner)
      MODE=runner
      shift ;;
    --base)
      if [ $# -lt 2 ]; then
        printf 'usage: %s [--runner] [--base <dir>]\n' "$0" >&2
        exit 1
      fi
      BASE="$2"
      shift 2 ;;
    *)
      printf 'usage: %s [--runner] [--base <dir>]\n' "$0" >&2
      exit 1 ;;
  esac
done
case "$BASE" in
  "~") BASE="$HOME" ;;
  "~/"*) BASE="$HOME${BASE#\~}" ;;
esac

blocked_reasons=()

# ---- 共通判定(既定モード・--runner の両方が呼ぶ。docs/remote-runner.md §14 表の
#      「既存の判定をそのまま再利用(コピーせず共通部分を関数に括り出す)」) -----------------
check_core_toolchain() {
  local os xcode_select_path xcode_out xcode_usable installed_xcode
  os="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
  kv macos "$os"
  case "$os" in
    2[6-9].*|[3-9][0-9].*) : ;;
    *) blocked_reasons+=("macOS 26 or newer is required (currently $os)") ;;
  esac

  # xcodebuild が使えない理由は3つあり、対処がまったく違う(まとめて「license 未同意」と案内すると
  # 受け手が無駄な作業をする)。エラー本文と xcode-select の指す先で切り分ける
  xcode_select_path="$(xcode-select -p 2>/dev/null || echo unknown)"
  kv xcode_select_path "$xcode_select_path"
  xcode_usable=0
  if xcode_out="$(xcodebuild -version 2>&1)"; then
    xcode_usable=1
    kv xcode "$(first_line "$xcode_out")"
  else
    kv xcode unusable
    kv xcode_error "$(first_line "$xcode_out")"
    installed_xcode="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -n 1)"
    case "$xcode_out" in
      *license*|*License*)
        blocked_reasons+=("the Xcode license has not been accepted → a human must run \`sudo xcodebuild -license accept\`") ;;
      *"requires Xcode"*|*"active developer directory"*)
        if [ -n "$installed_xcode" ]; then
          blocked_reasons+=("xcode-select points at CommandLineTools ($xcode_select_path) → a human must run \`sudo xcode-select -s $installed_xcode\`")
        else
          blocked_reasons+=("Xcode itself is missing (only CommandLineTools) → install Xcode from the App Store, then \`sudo xcode-select -s /Applications/Xcode.app\`")
        fi ;;
      *)
        blocked_reasons+=("xcodebuild is unusable: $(first_line "$xcode_out")") ;;
    esac
  fi
  # xcodebuild 自体が使えないときは初回セットアップの可否を判定できない(必ず失敗して
  # 「初回セットアップが未了」という誤った理由が増えるので、上を直してから見る)
  if [ "$xcode_usable" = "0" ]; then
    kv xcode_first_launch unknown
  elif xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    kv xcode_first_launch done
  else
    kv xcode_first_launch required
    blocked_reasons+=("Xcode first-launch setup is incomplete → a human must run \`xcodebuild -runFirstLaunch\`")
  fi

  command -v git  >/dev/null 2>&1 && kv git yes  || { kv git no;  blocked_reasons+=("git is missing"); }
  command -v swift >/dev/null 2>&1 && kv swift yes || { kv swift no; blocked_reasons+=("swift is missing (install Xcode)"); }
}

check_xcodegen() {
  if command -v xcodegen >/dev/null 2>&1; then
    kv xcodegen yes
    return 0
  fi
  kv xcodegen no
  return 1
}

check_adb() {
  command -v adb >/dev/null 2>&1 && kv adb yes || kv adb no
}

if [ "$MODE" = "runner" ]; then
  # ===============================================================================
  # --runner: ランナー機としての判定(docs/remote-runner.md §5・§14)。読み取りのみ・sudo 不使用。
  # ===============================================================================
  runner_manual=()

  kv base "$BASE"

  # ---- Aqua セッション在否。§5「準備状態の判定は両モード共通で stat -f%Su /dev/console」 ------
  console_user="$(stat -f%Su /dev/console 2>/dev/null || echo unknown)"
  runner_user="$(id -un)"
  kv console_user "$console_user"
  kv runner_user "$runner_user"
  if [ "$console_user" = "$runner_user" ] && [ "$console_user" != "unknown" ]; then
    logged_in=yes
  else
    logged_in=no
  fi
  kv logged_in "$logged_in"

  # ---- システムスリープ。`disksleep`/`displaysleep` 等も部分文字列で "sleep" を含むため、
  #      行全体ではなく先頭フィールドが厳密に "sleep" の行だけを見る。head は使わない
  #      (ファイル冒頭のコメント参照。$pmset_out は既に確定した文字列なので read ループで読む)
  pmset_out="$(pmset -g 2>/dev/null || true)"
  sleep_value=""
  while IFS= read -r pm_line; do
    read -r -a pm_fields <<< "$pm_line"
    if [ "${pm_fields[0]:-}" = "sleep" ]; then
      sleep_value="${pm_fields[1]:-}"
      break
    fi
  done <<PMSET_OUT
$pmset_out
PMSET_OUT
  kv system_sleep "${sleep_value:-unknown}"

  if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
    sshd_ok=yes
  else
    sshd_ok=no
  fi
  kv sshd "$sshd_ok"

  if launchctl print system/com.apple.screensharing >/dev/null 2>&1; then
    kv screen_sharing yes
  else
    kv screen_sharing no
  fi

  # ---- モード A/B(§5)。**blocked/needs-manual にはしない** — 案内文の出し分けにだけ使う
  fv_out="$(fdesetup status 2>/dev/null || echo unknown)"
  case "$fv_out" in
    *"is On"*)  filevault=on ;;
    *"is Off"*) filevault=off ;;
    *)          filevault=unknown ;;
  esac
  kv filevault "$filevault"
  auto_login="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo "")"
  kv auto_login "$auto_login"

  check_core_toolchain
  # xcodegen は install.sh が brew で入れる。**needs-manual にしない** —— `remote setup` は
  # このモードが 0 以外を返すと install.sh に到達せず中止するので、自動で入るものを人手扱いに
  # すると「入れれば直るのに入れる工程まで進めない」で詰まる(既定モードの missing[] と同じ扱い)
  check_xcodegen || true
  check_adb

  # ---- ツール本体・作業場所(§14「構成」)。未導入は `ftester remote setup` が作るので情報のみ ----
  tool_root="$BASE/foundation-tester"
  work_dir="$BASE/work"
  kv tool_root "$tool_root"
  kv work_dir "$work_dir"
  if [ -d "$tool_root" ]; then
    kv tool_root_exists yes
    if [ -d "$tool_root/.git" ]; then
      kv tool_root_head "$(git -C "$tool_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    else
      kv tool_root_head ""
    fi
    [ -x "$tool_root/.build/debug/ftester" ] && kv cli_built yes || kv cli_built no
  else
    kv tool_root_exists no
    kv tool_root_head ""
    kv cli_built no
  fi
  [ -f "$work_dir/Package.swift" ] && kv work_package yes || kv work_package no
  if [ -d "$work_dir/TestProjects" ]; then
    kv projects "$(ls -1 "$work_dir/TestProjects" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  else
    kv projects ""
  fi

  # ---- needs-manual の判定(FileVault/自動ログインは blocked にせず、案内文だけモードで出し分け) ----
  if [ "$logged_in" != yes ]; then
    case "$filevault" in
      on)
        runner_manual+=("nobody is logged in on the console (console_user=$console_user runner_user=$runner_user) → unlock and log in once (physically or via Screen Sharing)") ;;
      off)
        if [ -n "$auto_login" ]; then
          runner_manual+=("nobody is logged in on the console even though auto-login is configured for '$auto_login' → auto-login is not taking effect, check System Settings → Users & Groups → Login Options")
        else
          runner_manual+=("nobody is logged in on the console and FileVault is off with no auto-login user configured → log in once, or configure auto-login (System Settings → Users & Groups → Login Options)")
        fi ;;
      *)
        runner_manual+=("nobody is logged in on the console (console_user=$console_user runner_user=$runner_user) → unlock and log in once") ;;
    esac
  fi
  # 値が取れなかったときに「有効になっている」と断定しない(観測できていないだけ)
  case "${sleep_value:-}" in
    0) : ;;
    "") runner_manual+=("could not read the system sleep setting (pmset -g) → check it manually: pmset -g | grep ' sleep'") ;;
    *)  runner_manual+=("system sleep is enabled → run: sudo pmset -a sleep 0") ;;
  esac
  [ "$sshd_ok" = yes ] || runner_manual+=("sshd is not running → enable Remote Login: System Settings → General → Sharing → Remote Login")

  if [ "${#blocked_reasons[@]}" -gt 0 ]; then
    verdict=blocked
  elif [ "${#runner_manual[@]}" -gt 0 ]; then
    verdict=needs-manual
  else
    verdict=ready
  fi
  kv verdict "$verdict"

  say ""
  case "$verdict" in
    ready)
      say "✅ Ready as a runner."
      say "   base=$BASE tool_root_exists=$tool_root_exists work_package=$work_package cli_built=$cli_built"
      exit 0 ;;
    needs-manual)
      say "⚠️ Manual steps are required:"
      for reason in "${runner_manual[@]}"; do say "   ・$reason"; done
      exit 2 ;;
    *)
      say "❌ Cannot run as a runner as things stand:"
      for reason in "${blocked_reasons[@]}"; do say "   ・$reason"; done
      exit 1 ;;
  esac
fi

# ===================================================================================
# 既定モード: インストール前の状態判定(この節の出力は1バイトも変えない契約)
# ===================================================================================
WORK_DIR="$PWD"
missing=()

# ---- 構成の判定(SKILL ステップ0 の再実行ガード / 0.5 の構成判定) ---------------
# clone 構成 = Package.swift と Sources/FTScenarioRunner が揃う(この2つが揃うのはクローンだけ)
# 外部パッケージ構成 = Package.swift の中身に ftester マーカーか foundation-tester 依存がある
# 無関係パッケージ = Package.swift はあるがどちらも無い(ftester init が拒否する)
layout="external-new"
if [ -f "$WORK_DIR/Package.swift" ]; then
  if [ -d "$WORK_DIR/Sources/FTScenarioRunner" ]; then
    layout="clone"
  elif grep -q "ftester projects begin\|foundation-tester" "$WORK_DIR/Package.swift" 2>/dev/null; then
    layout="external-installed"
  else
    layout="foreign-package"
    blocked_reasons+=("the current directory is a Swift package unrelated to ftester (run this in a fresh, test-only directory)")
  fi
fi
kv work_dir "$WORK_DIR"
kv layout "$layout"

# ---- TOOL_ROOT(ツール本体のクローン) ------------------------------------------
# clone 構成ならカレント。外部構成は既定で隣(../foundation-tester)。既存なら版と汚れも出す
tool_root=""
case "$layout" in
  clone) tool_root="$WORK_DIR" ;;
  *)
    # 導入済みなら Package.swift の .package(path:) が正(既定の隣とは限らない)。
    # 見つからなければ既定の隣を候補として見る
    declared="$(sed -n 's/.*\.package(path: *"\([^"]*\)".*/\1/p' "$WORK_DIR/Package.swift" 2>/dev/null | head -1)"
    for candidate in "$declared" "../foundation-tester"; do
      [ -n "$candidate" ] || continue
      case "$candidate" in /*) : ;; *) candidate="$WORK_DIR/$candidate" ;; esac
      if [ -d "$candidate/Sources/FTScenarioRunner" ]; then
        tool_root="$(cd "$candidate" && pwd)"
        break
      fi
    done
    ;;
esac
if [ -n "$tool_root" ]; then
  kv tool_root "$tool_root"
  kv tool_root_exists yes
  if [ -d "$tool_root/.git" ]; then
    kv tool_root_head "$(git -C "$tool_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    kv tool_root_ref "$(git -C "$tool_root" symbolic-ref --short -q HEAD || echo detached)"
    [ -n "$(git -C "$tool_root" status --porcelain 2>/dev/null)" ] \
      && kv tool_root_dirty yes || kv tool_root_dirty no
  fi
  [ -x "$tool_root/.build/debug/ftester" ] && kv cli_built yes || kv cli_built no
else
  kv tool_root "$WORK_DIR/../foundation-tester"
  kv tool_root_exists no
  kv cli_built no
fi

# ---- 既に作られているもの(導入済みのとき何が残っているか) ----------------------
# 器は TestProjects/(2026-08-05 に Projects/ から改名)。**旧名も見る**:
# 既に導入済みの受け手は Projects/ のままなので、見落とすと「未導入」と誤判定する
PROJECTS_DIR=""
[ -d "$WORK_DIR/TestProjects" ] && PROJECTS_DIR="$WORK_DIR/TestProjects"
[ -z "$PROJECTS_DIR" ] && [ -d "$WORK_DIR/Projects" ] && PROJECTS_DIR="$WORK_DIR/Projects"
if [ -n "$PROJECTS_DIR" ]; then
  kv projects "$(ls -1 "$PROJECTS_DIR" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
else
  kv projects ""
fi
if [ -f "$WORK_DIR/.mcp.json" ] && grep -q '"ftester"' "$WORK_DIR/.mcp.json" 2>/dev/null; then
  kv mcp_registered yes
else
  kv mcp_registered no
fi
if ls -d "$HOME/.vscode/extensions/"*ftester* >/dev/null 2>&1; then
  kv vscode_extension yes
else
  kv vscode_extension no
fi
if [ -f "$HOME/.config/ftester/config.json" ]; then
  kv machine_registered "$(sed -n 's/.*"machineName" *: *"\([^"]*\)".*/\1/p' "$HOME/.config/ftester/config.json" | head -1)"
else
  kv machine_registered ""
fi

# ---- セットアップ質問の候補値(エージェントが別コマンドを都度実行しないで済むように) ----------
kv computer_name "$(scutil --get ComputerName 2>/dev/null | tr ' ' '-' | tr -cd 'A-Za-z0-9_-')"
kv folder_name "$(basename "$WORK_DIR" | tr -cd 'A-Za-z0-9_-')"

# ---- 環境(SKILL ステップ0 の機械判定。macos/xcode/xcode_first_launch/git/swift は
#      check_core_toolchain に括り出して --runner とも共有する) --------------------
check_core_toolchain
# 以下は install.sh が自動導入・スキップできるので blocked にはしない
check_xcodegen || missing+=("xcodegen (install.sh installs it via brew)")
command -v npm >/dev/null 2>&1 && kv npm yes || { kv npm no; missing+=("npm (needed to build the VSCode extension)"); }
check_adb
command -v claude >/dev/null 2>&1 && kv claude_cli yes || kv claude_cli no

# ---- 判定 ---------------------------------------------------------------------
if [ "${#blocked_reasons[@]}" -gt 0 ]; then
  verdict=blocked
elif [ "$layout" = "external-installed" ]; then
  verdict=installed
else
  verdict=ready
fi
kv verdict "$verdict"

say ""
case "$verdict" in
  ready)
    say "✅ Not installed. It can be installed here ($layout)."
    say "   Claude Code: /ftester-setup / manual: Scripts/install.sh --name <ProjectName>"
    [ "${#missing[@]}" -gt 0 ] && printf '   Missing (installed automatically): %s\n' "${missing[*]}"
    exit 0 ;;
  installed)
    say "ℹ️ Already installed (external-package layout). Do not run setup again."
    say "   Update → /ftester-update / add profiles → /ftester-profiles / scenarios → /ftester-scenario"
    say "   To reinstall, uninstall first (docs/getting-started.md, the uninstall section)."
    say "   See projects= / mcp_registered= / vscode_extension= above for what already exists."
    exit 2 ;;
  *)
    say "❌ Cannot install as things stand:"
    for reason in "${blocked_reasons[@]}"; do say "   ・$reason"; done
    exit 1 ;;
esac

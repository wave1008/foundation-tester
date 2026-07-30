#!/usr/bin/env bash
# foundation-tester の更新。/ftester-update スキルの「機械作業」を1コマンドに固めたもの。
#
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/update.sh | bash
#   bash <TOOL_ROOT>/Scripts/update.sh [--work-dir <dir>] [--tool-root <dir>] [--skip-extension] [--skip-plugin]
#
# やること: install.sh(pull → swift build → 拡張 → .mcp.json → 検証ゲート)を再実行し、
#           更新固有の作業を足す: ftester project sync / Claude Code プラグインの更新と版照合。
#           **先に update-check.sh で判定し、up-to-date なら何もせず終える**(全工程は更新が
#           無くても約30秒かかる。壊れた導入を入れ直すときは --force)。
# やらないこと: プロファイルの作り直し(既存を尊重)・受け手パッケージの作成(それは install.sh)。
#
# 契約: 手順は .claude/skills/ftester-update/SKILL.md と 1:1。片方だけ変えない。
#       重複を避けるため、共通部分は install.sh を呼ぶ(pull の確認・ログ・検証ゲートも同じものが効く)。
# 終了コード: 0=完了 / 1=必須ステップの失敗 / 2=任意ステップのみ失敗
set -uo pipefail

WORK_DIR="$PWD"
TOOL_ROOT_ARG=""
PASS_THROUGH=()
DO_PLUGIN=1
ALLOW_PULL=1
FORCE=0
DO_DOCTOR=0

usage() {
  cat <<'EOF'
Usage: update.sh [options]

  --work-dir <dir>   Consumer directory that holds Projects/ (default: current directory)
  --tool-root <dir>  Location of the foundation-tester clone (default: <work-dir>/../foundation-tester)
  --no-pull          Do not update the clone (to pin a version, or while developing the tool)
  --force            Run everything even without an update (to redo a broken install)
  --skip-extension   Do not reinstall the VSCode extension
  --skip-plugin      Do not update the Claude Code plugin (skills)
  --doctor           Print the environment report (ftester doctor) at the end (off by default)
  --keep-local       Do not auto-discard local changes in the clone
  --verbose          Also print the raw swift build / npm logs to the screen
  -h, --help         This help

What it does: re-runs install.sh (git pull → swift build → extension → .mcp.json → verification gates)
         + ftester project sync + plugin update with version cross-check
         **Exits without doing anything when there is no update** (decided by update-check.sh; use --force to run everything)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir) WORK_DIR="${2:?--work-dir requires a value}"; shift 2 ;;
    --tool-root) TOOL_ROOT_ARG="${2:?--tool-root requires a value}"; PASS_THROUGH+=(--tool-root "$2"); shift 2 ;;
    --no-pull) ALLOW_PULL=0; PASS_THROUGH+=(--no-pull); shift ;;
    --force) FORCE=1; shift ;;
    --doctor) DO_DOCTOR=1; shift ;;
    --keep-local) PASS_THROUGH+=(--keep-local); shift ;;
    --verbose) PASS_THROUGH+=(--verbose); shift ;;
    --skip-extension) PASS_THROUGH+=(--skip-extension); shift ;;
    --skip-plugin) DO_PLUGIN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

WORK_DIR="$(cd "$WORK_DIR" 2>/dev/null && pwd)" || { echo "error: --work-dir does not exist" >&2; exit 1; }

# TOOL_ROOT の解決は install.sh と同じ規則(Package.swift の .package(path:) → 既定の隣)。
# ここでは project sync とプラグイン照合に要るので先に決めておく
resolve_tool_root() {
  if [ -n "$TOOL_ROOT_ARG" ]; then (cd "$TOOL_ROOT_ARG" && pwd); return; fi
  if [ -d "$WORK_DIR/Sources/FTScenarioRunner" ]; then printf '%s' "$WORK_DIR"; return; fi
  local declared
  declared="$(sed -n 's/.*\.package(path: *"\([^"]*\)".*/\1/p' "$WORK_DIR/Package.swift" 2>/dev/null | head -1)"
  for candidate in "$declared" "../foundation-tester"; do
    [ -n "$candidate" ] || continue
    case "$candidate" in /*) : ;; *) candidate="$WORK_DIR/$candidate" ;; esac
    if [ -d "$candidate/Sources/FTScenarioRunner" ]; then (cd "$candidate" && pwd); return; fi
  done
}
TOOL_ROOT="$(resolve_tool_root)"
if [ -z "$TOOL_ROOT" ]; then
  echo "❌ No foundation-tester clone found (WORK_DIR=$WORK_DIR)." >&2
  echo "   If not installed yet: /ftester-setup (or Scripts/install.sh). If it lives elsewhere, pass --tool-root." >&2
  echo "   **Do not go hunting through nearby directories** — ask the human instead." >&2
  exit 1
fi

# ---- 0.5 更新が無いなら何もしない ---------------------------------------------
# 以降の工程は「更新が無くても」約30秒かかる(swift build の no-op 18s + doctor 8s + 拡張の
# 再パッケージ 4s。M2 Ultra 実測)。1秒で済む判定を先に置く。
# **up-to-date のときだけ止める** ―― pinned/unknown(版固定・オフライン)は判定できないだけなので
# 従来どおり進む。取りこぼしを疑うとき(前回が途中で失敗した等)は --force
if [ "$FORCE" = "0" ] && [ "$ALLOW_PULL" = "1" ] && [ -f "$TOOL_ROOT/Scripts/update-check.sh" ]; then
  check_out="$(bash "$TOOL_ROOT/Scripts/update-check.sh" --tool-root "$TOOL_ROOT" 2>/dev/null || true)"
  case "$check_out" in
    *"verdict=up-to-date"*)
      echo "✅ Up to date ($(git -C "$TOOL_ROOT" rev-parse --short HEAD 2>/dev/null)). Nothing to pull in."
      echo "   If the last run failed midway, or to redo the install, re-run with --force."
      exit 0 ;;
  esac
fi

# ---- 1〜2・5・5.5: install.sh に委譲(pull・build・拡張・.mcp.json・検証ゲート・ログ) -------
# --skip-project: 既存の Projects/ を触らない(更新でプロジェクトを作り直さない)
echo "==> Re-running install.sh (pull → build → extension → .mcp.json → verification)"
# --no-doctor が既定: 結果表に Apple Intelligence の warn 行が出るので情報が重複し、8秒かかる
[ "$DO_DOCTOR" = "1" ] || PASS_THROUGH+=(--no-doctor)
bash "$TOOL_ROOT/Scripts/install.sh" --work-dir "$WORK_DIR" --skip-project --no-next-steps \
  "${PASS_THROUGH[@]+"${PASS_THROUGH[@]}"}"
INSTALL_STATUS=$?
if [ "$INSTALL_STATUS" = "1" ]; then
  echo "❌ Update aborted (fix the [fail] above, then re-run)" >&2
  exit 1
fi

# ---- 3. 受け手側の反映(clone 構成のみ project sync) ----------------------------
# 外部パッケージ構成はローカルパス依存なので pull だけで反映される(シナリオは実行時に自動ビルド)
FT="$TOOL_ROOT/.build/debug/ftester"
if [ "$WORK_DIR" = "$TOOL_ROOT" ] && [ -x "$FT" ]; then
  echo ""
  echo "==> ftester project sync (resyncing Projects/ ↔ Package.swift)"
  ( cd "$WORK_DIR" && "$FT" project sync ) || echo "⚠️ project sync failed (check it by hand)"
fi

# ---- 5.7. Claude Code プラグイン(スキル)の更新 ---------------------------------
# `git pull` ではスキルは更新されない(~/.claude/plugins/cache/ のスナップショットを読むため)。
# marketplace → plugin の順が必須(先に marketplace を更新しないと古い定義を見る)
PLUGIN_RESULT="skip"
plugin_installed_version() {
  claude plugin list 2>/dev/null \
    | awk '/ftester@foundation-tester/{f=1} f&&/Version:/{print $2; exit}'
}
if [ "$DO_PLUGIN" = "1" ] && command -v claude >/dev/null 2>&1; then
  if claude plugin list 2>/dev/null | grep -q "ftester@foundation-tester"; then
    echo ""
    echo "==> Updating the Claude Code plugin (skills)"
    # 更新前の版を控える。**入れ替わっていなければ Claude Code の再起動は要らない**
    # (「一致した」だけで再起動を案内すると、不要な人間作業を毎回1つ増やす)
    plugin_before="$(plugin_installed_version)"
    claude plugin marketplace update foundation-tester >/dev/null 2>&1
    claude plugin update ftester@foundation-tester >/dev/null 2>&1
    # 「実行した」ではなく「HEAD と一致した」で判定する
    plugin_version="$(plugin_installed_version)"
    # 空だと下の case のパターンが `*` になり、**何であれ「一致」と誤判定する**(false green)
    [ -n "$plugin_version" ] || plugin_version="(unavailable)"
    head_sha="$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null)"
    case "$head_sha" in
      "$plugin_version"*)
        if [ "$plugin_version" = "$plugin_before" ]; then
          PLUGIN_RESULT="unchanged"; echo "✅ Plugin: $plugin_version (same as before — no restart needed)"
        else
          PLUGIN_RESULT="ok"; echo "✅ Plugin: $plugin_before → $plugin_version (matches HEAD)"
        fi ;;
      *) PLUGIN_RESULT="stale"; echo "⚠️ Plugin: $plugin_version (does not match HEAD ${head_sha:0:12})" ;;
    esac
  else
    PLUGIN_RESULT="none"
  fi
elif [ "$DO_PLUGIN" = "1" ]; then
  echo ""
  echo "・The claude CLI is missing, so the plugin (skills) was not updated"
  echo "  (if the skills are used directly from the clone, git pull already updated them)"
fi

echo ""
echo "──────── Next steps ────────"
# install.sh には --no-next-steps を渡しているので、ログの場所はここで案内する
# (更新の詳細ログを人が後から確認できるように)。名前が install-<日時>.log なので
# **辞書順の最後が最新**。`ls | head` は使わない(pipefail 下の SIGPIPE 誤判定)
update_logs=("$WORK_DIR"/.ftester/install-*.log)
last_log="${update_logs[${#update_logs[@]} - 1]}"
[ -f "$last_log" ] && echo "・Detailed log: $last_log"
echo "・In VSCode, run Developer: Reload Window (required for the extension; reopen the monitor panel)"
[ "$PLUGIN_RESULT" = "ok" ] && echo "・Restart Claude Code (updated skills stay stale until a restart)"
[ "$PLUGIN_RESULT" = "stale" ] && echo "・The plugin does not match HEAD. Run claude plugin marketplace update → plugin update by hand"
exit "$INSTALL_STATUS"

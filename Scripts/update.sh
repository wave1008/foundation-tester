#!/usr/bin/env bash
# fleetest の更新。/fleetest-update スキルの「機械作業」を1コマンドに固めたもの。
#
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/update.sh | bash
#   bash <TOOL_ROOT>/Scripts/update.sh [--work-dir <dir>] [--tool-root <dir>] [--skip-extension] [--skip-plugin]
#
# やること: install.sh(pull → swift build → 拡張 → .mcp.json → 検証ゲート)を再実行し、
#           更新固有の作業を足す: fleetest project sync / Claude Code プラグインの更新と版照合。
#           **先に update-check.sh で判定し、up-to-date なら何もせず終える**(全工程は更新が
#           無くても約30秒かかる。壊れた導入を入れ直すときは --force)。
# やらないこと: プロファイルの作り直し(既存を尊重)・受け手パッケージの作成(それは install.sh)。
#
# 契約: 手順は .claude/skills/fleetest-update/SKILL.md と 1:1。片方だけ変えない。
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

  --work-dir <dir>   Consumer directory that holds TestProjects/ (default: current directory)
  --tool-root <dir>  Location of the foundation-tester clone (default: <work-dir>/../foundation-tester)
  --no-pull          Do not update the clone (to pin a version, or while developing the tool)
  --force            Run everything even without an update (to redo a broken install)
  --skip-extension   Do not reinstall the VSCode extension
  --skip-plugin      Do not update the skills (the Claude Code plugin and copied SKILL.md files)
  --doctor           Print the environment report (fleetest doctor) at the end (off by default)
  --keep-local       Do not auto-discard local changes in the clone
  --verbose          Also print the raw swift build / npm logs to the screen
  -h, --help         This help

What it does: re-runs install.sh (git pull → swift build → extension → .mcp.json → verification gates)
         + fleetest project sync + plugin update with version cross-check
         **Exits without doing anything when there is no update** (decided by update-check.sh; use --force to run everything)
EOF
}

# 再 exec(install.sh の pull で自分が新しくなったとき)で渡し直すため、パース前に控える
ORIGINAL_ARGS=("$@")

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
  echo "   If not installed yet: /fleetest-setup (or Scripts/install.sh). If it lives elsewhere, pass --tool-root." >&2
  echo "   **Do not go hunting through nearby directories** — ask the human instead." >&2
  exit 1
fi

# ---- 0.5 更新が無いなら何もしない ---------------------------------------------
# 以降の工程は「更新が無くても」約30秒かかる(swift build の no-op 18s + doctor 8s + 拡張の
# 再パッケージ 4s。M2 Ultra 実測)。1秒で済む判定を先に置く。
# **up-to-date のときだけ止める** ―― pinned/unknown(版固定・オフライン)は判定できないだけなので
# 従来どおり進む。取りこぼしを疑うとき(前回が途中で失敗した等)は --force
# **再 exec された2周目はこの判定を通さない** —— 直前に pull しているので必ず up-to-date になり、
# ここで抜けると project sync とプラグイン更新(= update 固有の工程)が丸ごと飛ぶ
if [ "${FT_UPDATE_REEXEC:-0}" != "1" ] \
   && [ "$FORCE" = "0" ] && [ "$ALLOW_PULL" = "1" ] && [ -f "$TOOL_ROOT/Scripts/update-check.sh" ]; then
  check_out="$(bash "$TOOL_ROOT/Scripts/update-check.sh" --tool-root "$TOOL_ROOT" 2>/dev/null || true)"
  case "$check_out" in
    *"verdict=up-to-date"*)
      echo "✅ Up to date ($(git -C "$TOOL_ROOT" rev-parse --short HEAD 2>/dev/null)). Nothing to pull in."
      echo "   If the last run failed midway, or to redo the install, re-run with --force."
      exit 0 ;;
  esac
fi

# ---- 1〜2・5・5.5: install.sh に委譲(pull・build・拡張・.mcp.json・検証ゲート・ログ) -------
# --skip-project: 既存の TestProjects/ を触らない(更新でプロジェクトを作り直さない)
echo "==> Re-running install.sh (pull → build → extension → .mcp.json → verification)"
# --no-doctor が既定: 結果表に Apple Intelligence の warn 行が出るので情報が重複し、8秒かかる
[ "$DO_DOCTOR" = "1" ] || PASS_THROUGH+=(--no-doctor)
HEAD_BEFORE_INSTALL="$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null || echo none)"
bash "$TOOL_ROOT/Scripts/install.sh" --work-dir "$WORK_DIR" --skip-project --no-next-steps \
  "${PASS_THROUGH[@]+"${PASS_THROUGH[@]}"}"
INSTALL_STATUS=$?
if [ "$INSTALL_STATUS" = "1" ]; then
  echo "❌ Update aborted (fix the [fail] above, then re-run)" >&2
  exit 1
fi

# ---- 2.5 pull で自分自身が新しくなったら、新版でやり直す --------------------------
# install.sh 側と同じ理由(**bash は実行中にファイルが差し替わっても古い内容を最後まで実行する**)。
# install.sh は自前で再 exec するようになったが、**この update.sh のロジック変更は依然1版遅れる**。
# 「委譲が中心だから影響は小さい」と一度は残したが、直後に利用者向けの修正(project sync を
# 外部構成でも走らせる)がこのファイルへ入り、**受け手は2回更新しないと直らない**状態になった
# (2026-08-06 の外部フィードバックで判明)。ここも塞ぐ。
# 2周目の install.sh は全ステップ skip で数秒。**up-to-date の早期終了は FT_UPDATE_REEXEC で回避済み**。
if [ "${FT_UPDATE_REEXEC:-0}" != "1" ] && [ -f "$0" ] \
   && [ "$HEAD_BEFORE_INSTALL" != "$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null || echo none)" ] \
   && [ "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" = "$TOOL_ROOT/Scripts/update.sh" ]; then
  echo ""
  echo "==> The clone moved to a new revision — restarting with the updated update.sh"
  export FT_UPDATE_REEXEC=1
  exec bash "$0" "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"
fi

# ---- 3. 受け手側の反映(project sync) ------------------------------------------
# **構成で分けない**(2026-08-06 に修正)。かつては「外部パッケージ構成はローカルパス依存なので
# pull だけで反映される」として clone 構成だけで走らせていたが、それが正しいのは**依存の解決**
# だけで、**受け手の Package.swift に書かれたシナリオのパス**には効かない。
# 実害: 2026-08-05 の `Projects/`→`TestProjects/` / `Scenarios/`→`scenarios/` 改名のあと、
# 外部構成の受け手だけ Package.swift が旧名のまま取り残され、
# `invalid custom path 'Projects/<name>/Scenarios'` でビルドが落ちた(外部フィードバック)。
# syncManifest は external を明示的に扱う実装なので、両構成でそのまま安全に走る。
FT="$TOOL_ROOT/.build/debug/fleetest"
if [ -x "$FT" ]; then
  echo ""
  echo "==> fleetest project sync (resyncing TestProjects/ ↔ Package.swift)"
  ( cd "$WORK_DIR" && "$FT" project sync ) || echo "⚠️ project sync failed (check it by hand)"
fi

# ---- 5.7. Claude Code プラグイン(スキル)の更新 ---------------------------------
# `git pull` ではスキルは更新されない(~/.claude/plugins/cache/ のスナップショットを読むため)。
# marketplace → plugin の順が必須(先に marketplace を更新しないと古い定義を見る)
PLUGIN_RESULT="skip"
plugin_installed_version() {
  claude plugin list 2>/dev/null \
    | awk '/fleetest@foundation-tester/{f=1} f&&/Version:/{print $2; exit}'
}
if [ "$DO_PLUGIN" = "1" ] && command -v claude >/dev/null 2>&1; then
  if claude plugin list 2>/dev/null | grep -q "fleetest@foundation-tester"; then
    echo ""
    echo "==> Updating the Claude Code plugin (skills)"
    # 更新前の版を控える。**入れ替わっていなければ Claude Code の再起動は要らない**
    # (「一致した」だけで再起動を案内すると、不要な人間作業を毎回1つ増やす)
    plugin_before="$(plugin_installed_version)"
    claude plugin marketplace update foundation-tester >/dev/null 2>&1
    claude plugin update fleetest@foundation-tester >/dev/null 2>&1
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

# ---- 5.8. コピー配置のスキルの更新(プラグイン機構を使っていない受け手) -----------
# `install-skill.sh` はスキルを**コピー**するので、`git pull` では更新されない。
# Codex にはプラグイン機構経由の自動更新が(このツールでは)無いので、ここで差分を写す。
# 契約: 写し元は正典 `<TOOL_ROOT>/.claude/skills/`(AgentIntegration.canonicalSkillsDirectory)。
# **fleetest-setup は写さない** —— 受け手のパッケージのそれは `fleetest init` が生成した
# **受け手専用の別内容**で、正典で上書きすると受け手のセットアップ手順が消える。
# **シンボリックリンクも写さない**(クローンを直接指しているので pull 済み)。
# `--skip-plugin` はプラグインだけでなく**スキル更新全体**の抑止(コピー配置はプラグイン機構を
# 使わない受け手の同じ関心事なので、ノブを分けない)
#
# **一覧は持たず、クローンの正典から導出する**。手で持つと、スキルを増やす/改名するたびに
# ここを直し忘れてコピー配置の受け手だけ取り残される(install-skill.sh は clone より前に
# 走るので一覧を手で持つしかないが、こちらは TOOL_ROOT があるので導出できる)。
# **fleetest-setup だけは除く** —— 受け手のパッケージのそれは `fleetest init` が生成した
# 受け手専用の別内容で、正典で上書きすると受け手のセットアップ手順が消える
COPIED_SKILLS="$(ls "$TOOL_ROOT/.claude/skills" 2>/dev/null | grep -v '^fleetest-setup$' | tr '\n' ' ')"
SKILLS_REFRESHED=0
refresh_copied_skills() {
  skills_dir="$1"
  [ -d "$skills_dir" ] || return 0
  for name in $COPIED_SKILLS; do
    dest="$skills_dir/$name/SKILL.md"
    src="$TOOL_ROOT/.claude/skills/$name/SKILL.md"
    [ -f "$src" ] || continue
    # `A && continue` を素の文として置くと、A が偽のとき**関数の戻り値が 1 になり**、
    # set -e の呼び出し元で更新全体が止まる。if で書く
    if [ -L "$skills_dir/$name" ] || [ -L "$dest" ]; then continue; fi
    # **既にある物を写すだけでなく、増えた物も置く**。`[ -f "$dest" ] || continue` だけだと
    # 新しいスキルがコピー配置の受け手へ永久に届かない(プラグイン経由なら自動で増えるのに、
    # コピーの受け手だけ取り残される)
    if [ ! -f "$dest" ]; then
      mkdir -p "$skills_dir/$name"
      cp "$src" "$dest"
      SKILLS_REFRESHED=$((SKILLS_REFRESHED + 1))
      continue
    fi
    if ! cmp -s "$src" "$dest"; then
      cp "$src" "$dest"
      SKILLS_REFRESHED=$((SKILLS_REFRESHED + 1))
    fi
  done
  return 0
}
if [ "$DO_PLUGIN" = "1" ] && [ "$WORK_DIR" != "$TOOL_ROOT" ]; then
  refresh_copied_skills "$WORK_DIR/.claude/skills"
  refresh_copied_skills "$WORK_DIR/.agents/skills"
  if [ "$SKILLS_REFRESHED" -gt 0 ]; then
    echo ""
    echo "✅ Skills: refreshed $SKILLS_REFRESHED copied SKILL.md from the clone"
  fi
fi

echo ""
echo "──────── Next steps ────────"
# install.sh には --no-next-steps を渡しているので、ログの場所はここで案内する
# (更新の詳細ログを人が後から確認できるように)。名前が install-<日時>.log なので
# **辞書順の最後が最新**。`ls | head` は使わない(pipefail 下の SIGPIPE 誤判定)
update_logs=("$WORK_DIR"/.fleetest/install-*.log)
last_log="${update_logs[${#update_logs[@]} - 1]}"
[ -f "$last_log" ] && echo "・Detailed log: $last_log"
echo "・In VSCode, run Developer: Reload Window (required for the extension; reopen the monitor panel)"
[ "$PLUGIN_RESULT" = "ok" ] && echo "・Restart Claude Code (updated skills stay stale until a restart)"
[ "$SKILLS_REFRESHED" -gt 0 ] && echo "・Restart the agent (Claude Code / Codex) so the refreshed skills are re-read"
[ "$PLUGIN_RESULT" = "stale" ] && echo "・The plugin does not match HEAD. Run claude plugin marketplace update → plugin update by hand"
exit "$INSTALL_STATUS"

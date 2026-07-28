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

usage() {
  cat <<'EOF'
使い方: update.sh [オプション]

  --work-dir <dir>   Projects/ がある受け手ディレクトリ(既定: カレント)
  --tool-root <dir>  foundation-tester クローンの場所(既定: <work-dir>/../foundation-tester)
  --no-pull          クローンを更新しない(版を固定したいとき・本体の開発中)
  --force            更新が無くても全工程を実行する(壊れた導入の入れ直し)
  --skip-extension   VSCode 拡張の再インストールを行わない
  --skip-plugin      Claude Code プラグイン(スキル)の更新を行わない
  -h, --help         このヘルプ

やること: install.sh の再実行(git pull → swift build → 拡張 → .mcp.json → 検証ゲート)
         + ftester project sync + プラグインの更新と版照合
         **更新が無ければ何もせず終える**(判定は update-check.sh。全部やるなら --force)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir) WORK_DIR="${2:?--work-dir に値が必要です}"; shift 2 ;;
    --tool-root) TOOL_ROOT_ARG="${2:?--tool-root に値が必要です}"; PASS_THROUGH+=(--tool-root "$2"); shift 2 ;;
    --no-pull) ALLOW_PULL=0; PASS_THROUGH+=(--no-pull); shift ;;
    --force) FORCE=1; shift ;;
    --skip-extension) PASS_THROUGH+=(--skip-extension); shift ;;
    --skip-plugin) DO_PLUGIN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; usage >&2; exit 1 ;;
  esac
done

WORK_DIR="$(cd "$WORK_DIR" 2>/dev/null && pwd)" || { echo "エラー: --work-dir が存在しません" >&2; exit 1; }

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
  echo "❌ foundation-tester のクローンが見つかりません(WORK_DIR=$WORK_DIR)。" >&2
  echo "   未導入なら /ftester-setup(または Scripts/install.sh)。場所が違うなら --tool-root で指定してください。" >&2
  echo "   **周辺ディレクトリを探索しないこと** — 見つからない場合は人に聞く。" >&2
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
      echo "✅ 最新です($(git -C "$TOOL_ROOT" rev-parse --short HEAD 2>/dev/null))。取り込む変更はありません。"
      echo "   前回が途中で失敗した・入れ直したい場合は --force を付けて再実行してください。"
      exit 0 ;;
  esac
fi

# ---- 1〜2・5・5.5: install.sh に委譲(pull・build・拡張・.mcp.json・検証ゲート・ログ) -------
# --skip-project: 既存の Projects/ を触らない(更新でプロジェクトを作り直さない)
echo "==> install.sh を再実行(pull → build → 拡張 → .mcp.json → 検証)"
bash "$TOOL_ROOT/Scripts/install.sh" --work-dir "$WORK_DIR" --skip-project --no-next-steps \
  "${PASS_THROUGH[@]+"${PASS_THROUGH[@]}"}"
INSTALL_STATUS=$?
if [ "$INSTALL_STATUS" = "1" ]; then
  echo "❌ 更新を中断しました(上の [fail] を解消してから再実行してください)" >&2
  exit 1
fi

# ---- 3. 受け手側の反映(clone 構成のみ project sync) ----------------------------
# 外部パッケージ構成はローカルパス依存なので pull だけで反映される(シナリオは実行時に自動ビルド)
FT="$TOOL_ROOT/.build/debug/ftester"
if [ "$WORK_DIR" = "$TOOL_ROOT" ] && [ -x "$FT" ]; then
  echo ""
  echo "==> ftester project sync(Projects/ ↔ Package.swift の再整合)"
  ( cd "$WORK_DIR" && "$FT" project sync ) || echo "⚠️ project sync に失敗しました(手で確認してください)"
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
    echo "==> Claude Code プラグイン(スキル)の更新"
    # 更新前の版を控える。**入れ替わっていなければ Claude Code の再起動は要らない**
    # (「一致した」だけで再起動を案内すると、不要な人間作業を毎回1つ増やす)
    plugin_before="$(plugin_installed_version)"
    claude plugin marketplace update foundation-tester >/dev/null 2>&1
    claude plugin update ftester@foundation-tester >/dev/null 2>&1
    # 「実行した」ではなく「HEAD と一致した」で判定する
    plugin_version="$(plugin_installed_version)"
    # 空だと下の case のパターンが `*` になり、**何であれ「一致」と誤判定する**(false green)
    [ -n "$plugin_version" ] || plugin_version="(取得できず)"
    head_sha="$(git -C "$TOOL_ROOT" rev-parse HEAD 2>/dev/null)"
    case "$head_sha" in
      "$plugin_version"*)
        if [ "$plugin_version" = "$plugin_before" ]; then
          PLUGIN_RESULT="unchanged"; echo "✅ プラグイン: $plugin_version(更新前と同じ・再起動不要)"
        else
          PLUGIN_RESULT="ok"; echo "✅ プラグイン: $plugin_before → $plugin_version(HEAD と一致)"
        fi ;;
      *) PLUGIN_RESULT="stale"; echo "⚠️ プラグイン: $plugin_version(HEAD ${head_sha:0:12} と不一致)" ;;
    esac
  else
    PLUGIN_RESULT="none"
  fi
elif [ "$DO_PLUGIN" = "1" ]; then
  echo ""
  echo "・claude CLI が無いためプラグイン(スキル)は更新していません"
  echo "  (clone 内で直接スキルを使う構成なら git pull で更新済み)"
fi

echo ""
echo "──────── 次にやること ────────"
echo "・VSCode で Developer: Reload Window(拡張の反映に必須。モニターパネルは開き直す)"
[ "$PLUGIN_RESULT" = "ok" ] && echo "・Claude Code を再起動(更新したスキルは再起動まで旧版のまま)"
[ "$PLUGIN_RESULT" = "stale" ] && echo "・プラグインが HEAD と一致しません。claude plugin marketplace update → plugin update を手で実行"
exit "$INSTALL_STATUS"

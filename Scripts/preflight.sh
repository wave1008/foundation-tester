#!/usr/bin/env bash
# インストール前の状態判定。カレント(= WORK_DIR 候補)を見て「入れられるか・もう入っているか」を答える。
#
#   curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/preflight.sh | bash
#   bash Scripts/preflight.sh
#
# 引数は取らない。**カレントディレクトリだけを判定対象**にする(どこで実行したかが答えを変えるため)。
# 何も変更しない(読み取りのみ)。install.sh の前段として、また /ftester-setup のステップ0/0.5 として使う。
#
# 出力は `key=value` 行(機械可読)+ 末尾の判定。判定は verdict= と終了コードの両方に出る:
#   0 = ready      … 未導入。ここに install.sh / ftester-setup で導入できる
#   2 = installed  … 導入済み(外部パッケージ構成が確立済み)。更新は /ftester-update
#   1 = blocked    … ここには導入できない(ftester と無関係の Package.swift・必須環境の欠落)
#
# 契約: 判定の分岐は .claude/skills/ftester-setup/SKILL.md のステップ0(再実行ガード・環境判定)と
#       0.5(構成判定)と 1:1。片方だけ変えない。
set -uo pipefail

WORK_DIR="$PWD"
say() { printf '%s\n' "$1"; }
kv()  { printf '%s=%s\n' "$1" "$2"; }

blocked_reasons=()
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
    blocked_reasons+=("カレントは ftester と無関係の Swift パッケージです(テスト専用の新規ディレクトリで実行してください)")
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
if [ -d "$WORK_DIR/Projects" ]; then
  kv projects "$(ls -1 "$WORK_DIR/Projects" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
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

# ---- 環境(SKILL ステップ0 の機械判定) -----------------------------------------
os="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
kv macos "$os"
case "$os" in
  2[6-9].*|[3-9][0-9].*) : ;;
  *) blocked_reasons+=("macOS 26 以上が必要です(現在 $os)") ;;
esac

if xcode_line="$(xcodebuild -version 2>/dev/null | head -n 1)"; then
  kv xcode "$xcode_line"
else
  kv xcode "unusable"
  blocked_reasons+=("xcodebuild が使えません(未導入か license 未同意。sudo xcodebuild -license accept は人間が実行)")
fi
if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  kv xcode_first_launch done
else
  kv xcode_first_launch required
  blocked_reasons+=("Xcode の初回セットアップが未了です(xcodebuild -runFirstLaunch)")
fi

command -v git  >/dev/null 2>&1 && kv git yes  || { kv git no;  blocked_reasons+=("git がありません"); }
command -v swift >/dev/null 2>&1 && kv swift yes || { kv swift no; blocked_reasons+=("swift がありません(Xcode を導入してください)"); }
# 以下は install.sh が自動導入・スキップできるので blocked にはしない
command -v xcodegen >/dev/null 2>&1 && kv xcodegen yes || { kv xcodegen no; missing+=("xcodegen(install.sh が brew で導入)"); }
command -v npm >/dev/null 2>&1 && kv npm yes || { kv npm no; missing+=("npm(VSCode 拡張のビルドに必要)"); }
command -v adb >/dev/null 2>&1 && kv adb yes || kv adb no
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
    say "✅ 未導入です。ここに導入できます($layout)。"
    say "   Claude Code: /ftester-setup / 手動: Scripts/install.sh --name <ProjectName>"
    [ "${#missing[@]}" -gt 0 ] && printf '   未導入(自動で入るもの): %s\n' "${missing[*]}"
    exit 0 ;;
  installed)
    say "ℹ️ 導入済みです(外部パッケージ構成)。セットアップをやり直さないでください。"
    say "   更新 → /ftester-update / プロファイル追加 → /ftester-profiles / シナリオ → /ftester-scenario"
    say "   入れ直すなら先にアンインストール(docs/getting-started.md「アンインストール」)。"
    say "   途中まで作られているものは上の projects= / mcp_registered= / vscode_extension= を参照。"
    exit 2 ;;
  *)
    say "❌ このままでは導入できません:"
    for reason in "${blocked_reasons[@]}"; do say "   ・$reason"; done
    exit 1 ;;
esac

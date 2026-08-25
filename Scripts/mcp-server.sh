#!/bin/bash
# `.mcp.json` から起動される fleetest-mcp のランチャ。
#
# **1行のシェル式を .mcp.json へ埋め込むのをやめてここに置いた**(2026-08-06 の外部フィードバック)。
# 埋め込み式には2つの実害があった:
#
#   1. **起動のたびに `swift build` が走る**。無変更でも約8秒(実測。初回は14秒)かかり、
#      その回に ft_* を1度も使わなくても必ず払う。→ **ソースが実行ファイルより新しいときだけ**建てる
#   2. **ビルド出力を /dev/null に捨てていた**ため、失敗すると `&&` が切れて
#      **サーバが黙って起動しない**。理由を見る手段が無かった。→ ログへ落とし、失敗は stderr へ出す
#
# 守る不変条件:
# - **stdout は JSON-RPC 専用**。診断は必ず stderr、ビルド出力はログファイルへ
#   (1バイトでも混ざるとクライアント側のパースが壊れる)
# - **cwd を変えない**。cwd は `fleetest-mcp` が受け手パッケージ(`TestProjects/` の在り処)を
#   特定する入力で、ここで cd したまま exec すると外部パッケージ構成で見失う。
#   ビルドはサブシェルで行い、親の cwd はそのまま exec へ渡す
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$TOOL_ROOT/.build/debug/fleetest-mcp"
LOG="$TOOL_ROOT/.build/fleetest-mcp-build.log"

# **鮮度で判定する(存在ではなく)**。`git pull` で入った新しいソースをそのまま使うと
# 「直したのに反映されない」になる —— InAppLauncher.buildIfNeeded と同じ規律。
needs_build=1
if [ -x "$BIN" ] \
   && [ -z "$(find "$TOOL_ROOT/Sources" "$TOOL_ROOT/Package.swift" -newer "$BIN" -print -quit 2>/dev/null)" ]; then
  needs_build=0
fi

if [ "$needs_build" = "1" ]; then
  mkdir -p "$(dirname "$LOG")"
  echo "[fleetest-mcp] sources are newer than the binary — building (first build takes minutes)…" >&2
  if ( cd "$TOOL_ROOT" && swift build --product fleetest-mcp ) >"$LOG" 2>&1; then
    # **建てた直後に実行ファイルを触る**。無変更のソースを touch しただけだと swift build は
    # 再リンクしないので、実行ファイルがソースより古いままになり毎回建て直すことになる
    touch "$BIN" 2>/dev/null || true
  else
    echo "[fleetest-mcp] build failed — not starting the server. Full log: $LOG" >&2
    tail -30 "$LOG" >&2
    exit 1
  fi
fi

exec "$BIN"

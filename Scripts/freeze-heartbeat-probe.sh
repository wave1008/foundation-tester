#!/usr/bin/env bash
# **本物の画面凍結を故意に起こし、そのとき拍動(displayIdleSeconds)が止まるかを観測する**。
#
# なぜ要るか: 凍結の判定は 2026-08-11 に「画像(一様フレーム)」から「拍動」へ移した。ところが
# **本物の wedge で tick が止まる観測はまだ1件も採れていない**(移行を決めた期間に本物が
# 起きなかった)。止まらない wedge が存在すると、いまの実装はそれを取り逃がす。
# ここが埋まるまで `FrozenEvidence.noPresent` の説明には留保が付いたままになる。
#
# **真値は拍動と独立に採る**(そうしないと循環論法になる): 「HOME を押しても画面が変わらない」
# = 表示が進んでいない、を凍結の定義として使う。HOME は必ず画面を変える入力なので、
# 変わらなければ描画が死んでいる。判定に拍動は一切使わない。
#
# トリガは Android の「複数台同時描画」(2026-07-25 の対照実験で確定済み。
# docs/verification.md / [[emulator-display-freeze-wedge]])。全機で同時にアプリを
# 起動し直すのを繰り返す。
#
# 使い方:
#   Scripts/freeze-heartbeat-probe.sh                 # 5ラウンド
#   Scripts/freeze-heartbeat-probe.sh --rounds 10 --package com.ftester.e2e.rn
#
# 出力: ラウンドごとに「凍結した機」「そのときの displayIdleSeconds」。
# 凍結が起きなければ「起こせなかった」と明示して終わる(それも情報)。
#
# bash 3.2(macOS 既定)で動くこと: mapfile / declare -A は使わない。

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ROUNDS=5
PACKAGE="com.ftester.e2e.rn"
SETTLE=4

while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) ROUNDS="$2"; shift 2 ;;
    --package) PACKAGE="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) echo "❌ 不明なオプション: $1" >&2; exit 2 ;;
  esac
done

ADB="$(ls "$HOME/Library/Android/sdk/platform-tools/adb" 2>/dev/null || command -v adb)"
[ -x "$ADB" ] || { echo "❌ adb が見つかりません" >&2; exit 1; }

SERIALS=$("$ADB" devices | awk '/^emulator-/{print $1}')
COUNT=$(printf '%s\n' "$SERIALS" | grep -c . || true)
[ "${COUNT:-0}" -ge 2 ] || { echo "❌ エミュレータが2台以上必要です(同時描画がトリガのため)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "対象 $COUNT 台 / package=$PACKAGE / rounds=$ROUNDS"

# その serial のブリッジが見えているホスト側ポート(adb forward の一覧から引く)
bridge_port() {
  "$ADB" forward --list 2>/dev/null | awk -v s="$1" '$1==s {sub(/tcp:/,"",$2); print $2; exit}'
}

display_idle() {
  port="$(bridge_port "$1")"
  [ -n "$port" ] || { echo "-"; return; }
  curl -s --max-time 2 "http://127.0.0.1:$port/status" 2>/dev/null \
    | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('displayIdleSeconds', '-'))
except Exception: print('-')" 2>/dev/null || echo "-"
}

# **凍結の真値**: HOME を押しても画面が変わらないか(拍動を使わない)
is_wedged() {
  ser="$1"
  "$ADB" -s "$ser" exec-out screencap -p > "$WORK/$ser.pre" 2>/dev/null
  "$ADB" -s "$ser" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
  sleep 2
  "$ADB" -s "$ser" exec-out screencap -p > "$WORK/$ser.post" 2>/dev/null
  [ -s "$WORK/$ser.pre" ] && [ -s "$WORK/$ser.post" ] || return 1
  a=$(shasum -a 256 < "$WORK/$ser.pre" | cut -d' ' -f1)
  b=$(shasum -a 256 < "$WORK/$ser.post" | cut -d' ' -f1)
  [ "$a" = "$b" ]
}

FOUND=0
round=1
while [ "$round" -le "$ROUNDS" ]; do
  echo "--- round $round/$ROUNDS: 全機同時にアプリを起動し直す ---"
  for ser in $SERIALS; do
    ( "$ADB" -s "$ser" shell am force-stop "$PACKAGE" >/dev/null 2>&1
      "$ADB" -s "$ser" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 ) &
  done
  wait
  sleep "$SETTLE"

  for ser in $SERIALS; do
    if is_wedged "$ser"; then
      idle="$(display_idle "$ser")"
      echo "  🧊 $ser: **凍結**(HOME でも画面が変わらない) / displayIdleSeconds=$idle"
      FOUND=$((FOUND + 1))
      # 既知の修復で戻るかまで見る(戻れば固着型と確定・戻らなければ別物)
      "$ADB" -s "$ser" shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
      sleep 1
      "$ADB" -s "$ser" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
      sleep 4
      if is_wedged "$ser"; then echo "     → sleep/wake では戻らない"; else echo "     → sleep/wake で回復(既知の固着型)"; fi
    fi
  done
  round=$((round + 1))
done

echo ""
if [ "$FOUND" -eq 0 ]; then
  echo "凍結を起こせませんでした($ROUNDS ラウンド)。**拍動の検証は未了のまま**"
  echo "(トリガの条件が当時と違う可能性がある。台数・GPU モード・同時描画の作り方を変えて再試行する)"
else
  echo "凍結を $FOUND 件観測しました。上の displayIdleSeconds が拍動の挙動そのもの"
  echo "  - 値が大きい(>5秒) → 拍動は止まる = いまの判定で捕まえられる"
  echo "  - 値が小さい       → **止まらない wedge が存在する** = 判定を作り直す必要がある"
fi

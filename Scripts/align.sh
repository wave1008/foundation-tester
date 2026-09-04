#!/usr/bin/env bash
# 手元の HEAD を全リモートランナーへ揃える(「アラインして」の機械作業ぶん)。
#
# **なぜスクリプトなのか**: 手順そのものは短いが、**並列で撃つ**という一点が人の手だと必ず落ちる
# (2026-09-03 と 2026-09-04 に計3回、`remote align` を1機ずつ送って前の出力を読んでから次を
# 送っていた。うち1回は「並列で」と明示された直後)。台数ぶん待ち時間が伸びるだけの誤りなので、
# **判断の余地を無くして機械に持たせる**。
#
# やること: ①作業ツリーが汚れていないことを確かめる ②push ③登録簿の全機へ `remote align` を
# **同時に**投げる ④`remote status` で REV が手元の HEAD と一致することまで確かめる。
#
# 使い方: Scripts/align.sh
#   コミットはしない(メッセージは人が書くもの)。**汚れたツリーでは何もせずに落ちる** ——
#   ランナーは push されたコミットを取りに行くので、未コミットの変更は絶対に届かない。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FLEETEST="${FLEETEST:-.build/debug/fleetest}"
[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST が無い(swift build を先に)" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 作業ツリーに未コミットの変更がある。align はランナーに **push 済みのコミット** を" >&2
  echo "   取りに行かせる操作なので、先にコミットすること:" >&2
  git status --short >&2
  exit 1
fi

HEAD_SHA="$(git rev-parse HEAD)"
echo "==> push (HEAD=${HEAD_SHA:0:9})"
git push origin HEAD

MACHINES=$("$FLEETEST" api remote-hosts | python3 -c '
import json,sys
print("\n".join(h["machine"] for h in json.load(sys.stdin).get("hosts", []) if h.get("machine")))')
[ -n "$MACHINES" ] || { echo "❌ 登録簿にリモート機が無い(fleetest remote setup)" >&2; exit 1; }

LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

# **ここが要点**: 全機を同時に起こし、待つのは最後にまとめて。1機ずつ待たない
echo "==> align $(echo "$MACHINES" | tr '\n' ' ')(並列)"
PIDS=""
for m in $MACHINES; do
  ( "$FLEETEST" remote align "$m" > "$LOGDIR/$m.log" 2>&1; echo $? > "$LOGDIR/$m.code" ) &
  PIDS="$PIDS $!"
done
for pid in $PIDS; do wait "$pid" || true; done

FAILED=0
for m in $MACHINES; do
  code=$(cat "$LOGDIR/$m.code" 2>/dev/null || echo 1)
  line=$(grep -E "aligned to|❌|error" "$LOGDIR/$m.log" | tail -1)
  if [ "$code" = 0 ]; then echo "  ✅ $m: ${line:-(出力なし)}"
  else echo "  ❌ $m: ${line:-(出力なし)} (exit=$code / log: $LOGDIR/$m.log)"; FAILED=1
       cp "$LOGDIR/$m.log" "/tmp/align-$m.log"; echo "     ログを /tmp/align-$m.log に残した"; fi
done

# **align の成功報告だけで終わらせない**: 版が揃ったことは REV で確かめる
HOST_ARGS=""
for m in $MACHINES; do HOST_ARGS="$HOST_ARGS --host $m"; done
echo "==> verify"
STATUS=$("$FLEETEST" remote status $HOST_ARGS 2>&1)
echo "$STATUS"
for m in $MACHINES; do
  echo "$STATUS" | grep -q "$HEAD_SHA" || { echo "❌ REV が手元の HEAD と一致しない機がある" >&2; FAILED=1; break; }
done
[ "$FAILED" = 0 ] && echo "✅ 全機 ${HEAD_SHA:0:9} に揃った"
exit "$FAILED"

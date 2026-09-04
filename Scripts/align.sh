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

# `--force` は **preflight を飛ばさない**。飛ばしても `remote align` 自身が同じロックで止まるので
# 素通しにはならず、素通しにできてしまうと**走っている他人の run を殺す**(向こうで
# `git checkout` + `swift build` をするので、実行中のバイナリが差し替わって SIGKILL される。
# maintainer-notes §4.1 と同じ事故がリモートで起きる)。
# 代わりに **`remote unlock` を試みてから測り直す** —— あれは「**自分の**死んだディスパッチの
# ロックだけ」を外すので、生きている run と他人のロックは残り、そのときは従来どおり落ちる
FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi
[ $# -eq 0 ] || { echo "usage: Scripts/align.sh [--force]" >&2; exit 2; }

FLEETEST="${FLEETEST:-.build/debug/fleetest}"
[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST が無い(swift build を先に)" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 作業ツリーに未コミットの変更がある。align はランナーに **push 済みのコミット** を" >&2
  echo "   取りに行かせる操作なので、先にコミットすること:" >&2
  git status --short >&2
  exit 1
fi

HEAD_SHA="$(git rev-parse HEAD)"

MACHINES=$("$FLEETEST" api remote-hosts | python3 -c '
import json,sys
print("\n".join(h["machine"] for h in json.load(sys.stdin).get("hosts", []) if h.get("machine")))')
[ -n "$MACHINES" ] || { echo "❌ 登録簿にリモート機が無い(fleetest remote setup)" >&2; exit 1; }

HOST_ARGS=""
for m in $MACHINES; do HOST_ARGS="$HOST_ARGS --host $m"; done

# **押し込む前に、向こうが空いているかを見る**(dispatch.lock)。`remote align` 自身も
# ロックを取るので run を壊すことは無いが、**握られていれば align 段で1機ずつ ❌ になる**だけで、
# 「向こうで誰かの run が走っている」という肝心の事実が失敗文の中に埋もれる。
# **押す前に、理由を名指しして何もせずに落ちる**(2026-09-04 ユーザー指摘)
busy_hosts() {
  local raw
  raw=$("$FLEETEST" remote status $HOST_ARGS --json 2>/dev/null | grep '^{' || true)
  python3 - "$raw" <<'PYEOF'
import json, sys
raw = sys.argv[1]
if not raw:
    sys.exit(0)          # 読めないときは止めない(align 自身のロックが最後の砦)
for h in json.loads(raw).get("hosts", []):
    if not h.get("reachable", True):
        print(f"{h.get('host')}: 到達できない")
    elif h.get("lock", "free") != "free":
        print(f"{h.get('host')}: dispatch.lock が握られている({h.get('lock')})")
PYEOF
}

echo "==> preflight (ロック・到達性)"
BUSY=$(busy_hosts)
if [ -n "$BUSY" ] && [ "$FORCE" = 1 ]; then
  echo "$BUSY" | sed 's/^/   /'
  echo "==> --force: 自分の死んだロックだけ外して測り直す(生きている run は殺さない)"
  "$FLEETEST" remote unlock $HOST_ARGS 2>&1 | sed 's/^/   /' || true
  BUSY=$(busy_hosts)
fi
if [ -n "$BUSY" ]; then
  echo "❌ 揃えられない機がある。push もしていない:" >&2
  echo "$BUSY" | sed 's/^/   /' >&2
  if [ "$FORCE" = 1 ]; then
    echo "   --force でも外れなかった = 走っている run か、他人のロック。**待つ**のが正解" >&2
  else
    echo "   (走っている run が終わるのを待つ。自分の死んだロックなら --force か fleetest remote unlock)" >&2
  fi
  exit 1
fi

echo "==> push (HEAD=${HEAD_SHA:0:9})"
git push origin HEAD

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
echo "==> verify"
STATUS=$("$FLEETEST" remote status $HOST_ARGS 2>&1)
echo "$STATUS"
# **機械ごとに数える**(全体に1個あるかではない)。`echo | grep -q` は使わない ——
# grep が先に閉じて echo が SIGPIPE を受け、`set -o pipefail` でパイプライン全体が
# 非ゼロになる(揃っているのに「揃っていない」と報告した。2026-09-04 に実際に踏んだ)
MATCHED=$(grep -c "$HEAD_SHA" <<< "$STATUS" || true)
EXPECTED=$(wc -l <<< "$MACHINES" | tr -d ' ')
if [ "$MATCHED" != "$EXPECTED" ]; then
  echo "❌ REV が手元の HEAD と一致した機は $MATCHED/$EXPECTED" >&2
  FAILED=1
fi
[ "$FAILED" = 0 ] && echo "✅ 全機 ${HEAD_SHA:0:9} に揃った"
exit "$FAILED"

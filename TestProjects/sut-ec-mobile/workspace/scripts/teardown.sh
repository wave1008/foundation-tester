#!/bin/sh
# テスト実行の後に、setup.sh と同じ機械の上で走る。setup.sh が起こした dev サーバを止める。
#
# 規則
#   - このファイルがあるときだけ実行される。要らなければ削除してよい。
#   - 終了コードは run の合否を変えない(失敗は警告として出るだけ)。片付けの失敗で
#     緑の run を赤にしないため。
#   - setup.sh が失敗したときも実行されるので、途中まで起きた状態にも耐えること。
#   - 片付ける前に run ごと殺された場合(ssh の切断・SIGKILL)は、この機械で次に走る run が
#     代わりにこのスクリプトを実行する。"ftester hooks reap" で手動でも実行でき、
#     リモートのランナー機に対しては "ftester remote clean" がこれを撃つ。
#   - 環境変数は setup.sh と同じ(FT_HOOK だけ "teardown" になる)。ただし上記の代理実行では
#     run の文脈が無いため、FT_MACHINE・FT_REPORT_DIR・デバイス一覧は空になる
#     (FT_WORKSPACE・FT_PROJECT・FT_PROFILE は常に入っている)。
#
# ここでは "set -e" を使わない。1つ失敗しただけで残りの片付けを飛ばさないため。

set -u

# 非対話 ssh の PATH に Homebrew が入らないのは setup.sh と同じ(gradlew が java を引く)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SERVER_REPO="${SUTEC_SERVER_REPO:-$HOME/github/wave1008/sut-ec-mobile}"
HEALTH_URL="http://127.0.0.1:8090/health"
# 目印は setup.sh が置く。**ワークスペースの外**(転送で消えないため。setup.sh の該当箇所参照)
MARKER="${TMPDIR:-/tmp}/sutec-dev-server-started-by-setup"
# SIGTERM 後に消えるのを待つ上限(秒)。JVM の graceful shutdown は数秒で終わるので、
# その数倍を置く。超えたら SIGKILL する
STOP_WAIT_SECONDS="${SUTEC_STOP_WAIT_SECONDS:-30}"

# **setup.sh が起こしたときだけ止める**。手で起動して使っているサーバを、テストが終わった
# 拍子に落とさないため(目印は setup.sh が置く)
if [ ! -f "$MARKER" ]; then
  echo "the dev server was not started by setup.sh — leaving it running"
  exit 0
fi

# 8090 を LISTEN しているプロセスを止める。**起動のしかた(Terminal 経由 / 直接 / 別シェル)に
# 依らず確実に掴める**ので、pid ファイルや pgrep のパターン一致より当てになる
pids=$(lsof -ti tcp:8090 -sTCP:LISTEN 2>/dev/null)
if [ -n "$pids" ]; then
  echo "stopping the dev server (pid: $(echo "$pids" | tr '\n' ' '))"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null
  waited=0
  while [ "$waited" -lt "$STOP_WAIT_SECONDS" ]; do
    [ -z "$(lsof -ti tcp:8090 -sTCP:LISTEN 2>/dev/null)" ] && break
    sleep 1
    waited=$((waited + 1))
  done
  remaining=$(lsof -ti tcp:8090 -sTCP:LISTEN 2>/dev/null)
  if [ -n "$remaining" ]; then
    echo "the dev server ignored SIGTERM for ${STOP_WAIT_SECONDS}s — killing it"
    # shellcheck disable=SC2086
    kill -9 $remaining 2>/dev/null
  fi
else
  echo "nothing is listening on 8090 — the dev server is already down"
fi

# `:server:run` は Gradle デーモンが抱えたまま残ることがあるので、デーモンごと止める
if [ -x "$SERVER_REPO/gradlew" ]; then
  (cd "$SERVER_REPO" && ./gradlew --stop >/dev/null 2>&1) || true
fi

# **PostgreSQL のコンテナは止めない**。DB はボリューム無しで、起動のたびに Flyway +
# カタログシードで作り直される(= 残しても次の run が汚れない)。逆に止めると次の setup.sh が
# コンテナ起動から始めることになり、起動時間だけが伸びる
echo "left the PostgreSQL container running (the next setup.sh reuses it)"

rm -f "$MARKER"

# 止まったことを確かめてから終える(応答が残っていれば言う。ここで run を赤にはしない)
if curl -sf -m 3 "$HEALTH_URL" >/dev/null 2>&1; then
  echo "warning: something is still answering $HEALTH_URL" >&2
else
  echo "dev server stopped"
fi

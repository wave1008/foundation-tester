#!/bin/sh
# テスト実行の前に、デバイスを動かす機械(この Mac、--host でディスパッチしたときはランナー機)
# の上で走る。ここでは sut-ec-mobile のバックエンド(dev サーバ + PostgreSQL)を、
# **何も無い機械でも一から用意して**起こす。
#
# やること(すべて冪等。既に済んでいる段は飛ばす)
#   1. サーバのリポジトリが無ければ clone する
#   2. Apple Container(`container` コマンド)が無ければ brew で入れる
#      —— PostgreSQL はこの上で動く(dev-server.sh が `container system start` から面倒を見る)
#   3. dev-server.sh を起動する(PostgreSQL 起動 → Flyway + シード → gradle :server:run)
#   4. /health が ok を返すまで待つ
#
# 規則
#   - このファイルがあるときだけ実行される。要らなければ削除してよい。
#   - 0 以外で終了すると run を中止する。シナリオは1本も実行されず、テストの失敗ではなく
#     インフラ起因の失敗として報告される。
#   - デバイスに触る前に実行される。
#   - このスクリプトが失敗した場合も含め、teardown.sh は必ず後で実行される。
#   - タイムアウトは無い。決め打ちの sleep ではなく、起きたことを確認して待つこと。
#
# 環境変数
#   FT_HOOK             "setup"
#   FT_WORKSPACE        このワークスペースの絶対パス(カレントディレクトリでもある)
#   FT_PROJECT          テストプロジェクト名
#   FT_PROFILE          実行プロファイル名
#   FT_MACHINE          マシンプロファイル名
#   FT_REPORT_DIR       レポート出力先の絶対パス
#   FT_IOS_DEVICES      この run が使うデバイス名(空白区切り。空のこともある)
#   FT_ANDROID_DEVICES  同上、Android のぶん
#
# アプリの接続先はビルド時に固定されている(ServerConfigDefaults):
# Android エミュレータ = 10.0.2.2、iOS シミュレータ = 127.0.0.1、ポートは 8090。
# つまりこのスクリプトは「**その機械の** 8090 でサーバが応答する」状態を作れば足りる
# (だからリモート実行では、リモート機の上でこのスクリプトが同じことをする)。

set -eu

# 非対話 ssh の PATH は /usr/bin:/bin:/usr/sbin:/sbin だけで Homebrew が入らない。
# リモート実行では brew も container もここに居るので、明示的に足す
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SERVER_REPO="${SUTEC_SERVER_REPO:-$HOME/github/wave1008/sut-ec-mobile}"
SERVER_GIT_URL="${SUTEC_SERVER_GIT_URL:-https://github.com/wave1008/sut-ec-mobile.git}"
HEALTH_URL="http://127.0.0.1:8090/health"
SERVER_LOG="/tmp/dev-server.log"
# 起動待ちの上限(秒)。**効くのは初回だけ**(2回目以降は数十秒で上がる)。初回は clone +
# gradle の依存解決 + Kotlin ビルド + コンテナのカーネル導入まで入るので、短く切ると
# 「まだ進んでいる途中」を失敗と誤判定する。長すぎる害は下の fail-fast で潰してある
WAIT_SECONDS="${SUTEC_WAIT_SECONDS:-1800}"

# 死活判定は /health だけを見る。**root(/)は 404 を返すのが正常**なので使わない
server_is_up() {
  curl -sf -m 3 "$HEALTH_URL" 2>/dev/null | grep -q '"status":"ok"'
}

# 既に上がっていれば何もしない。**teardown.sh はサーバを止めない**(2026-08-18 ユーザー決定)ので、
# 2回目以降は常にここで済む —— run のたびに Terminal のウィンドウが増えない・起動待ちも無い。
# サーバ側のコードを更新したときは手で止める(`kill $(lsof -ti tcp:8090)` か、ウィンドウを閉じる)
if server_is_up; then
  echo "dev server is already healthy — reusing it ($HEALTH_URL)"
  exit 0
fi

# 1. リポジトリ(無ければ clone)
if [ ! -d "$SERVER_REPO/.git" ]; then
  echo "cloning the sut-ec-mobile server repo into $SERVER_REPO"
  mkdir -p "$(dirname "$SERVER_REPO")"
  git clone --depth 1 "$SERVER_GIT_URL" "$SERVER_REPO"
fi
[ -x "$SERVER_REPO/scripts/dev-server.sh" ] || {
  echo "dev-server.sh not found under $SERVER_REPO (is the clone complete?)" >&2
  exit 1
}

# 2. Apple Container(PostgreSQL の実行基盤)。dev-server.sh は未導入なら即エラーで止まるので、
# ここで入れておく。`container system start` 側は dev-server.sh が冪等に面倒を見る
if ! command -v container >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || {
    echo "neither container nor brew is available — install Homebrew first" >&2
    exit 1
  }
  echo "installing Apple Container (brew install container) — this takes a few minutes"
  brew install container
fi

# 3. gradle が使う JDK を 17 に固定する。**コンパイルと `:server:run` の JDK がずれると
# UnsupportedClassVersionError で落ちる** —— server は jvmToolchain(17) で動くのに、shared の
# jvm ターゲットは Gradle デーモンの JDK でコンパイルされるため、既定 JDK が新しい機械では
# class file 67 vs 61 の不一致になる(2026-08-18 に M1Max で実際に踏んだ)。
# 機械ごとの既定 JDK に依存させない
if [ -x /usr/libexec/java_home ]; then
  jdk17="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
  if [ -n "$jdk17" ]; then
    export JAVA_HOME="$jdk17"
    echo "using JDK 17 for gradle: $JAVA_HOME"
  else
    echo "warning: no JDK 17 on this machine — the server build may hit a class file version mismatch" >&2
  fi
fi

# 4. 起動。**手元(VS Code 配下)からは Terminal.app 経由で起動する** —— VS Code の配下から
# 直接起動すると、macOS の「ローカルネットワーク」プライバシー権限のため java から
# DB コンテナ(192.168.64.x)への接続が EHOSTUNREACH で失敗する(2026-08-08 実測。ping や
# nc -z は成功してしまうので疎通確認に使えない)。open(1) は Terminal.app に実行させるので
# この run のプロセスツリーから外れ、権限もそちらに従う。
# **ssh 越し(= リモート実行)では直接起動する** —— GUI セッションに窓を開く必要が無く、
# nohup で ssh の切断(SIGHUP)からも切り離せる
SERVER_PID=""
if [ -n "${SSH_CONNECTION:-}" ]; then
  echo "starting the sut-ec-mobile dev server (ssh session; log: $SERVER_LOG)"
  nohup "$SERVER_REPO/scripts/dev-server.sh" > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
else
  # 目印と同じ理由でワークスペースの外に置く(生成物を転送対象に混ぜない)
  LAUNCHER="${TMPDIR:-/tmp}/sutec-start-dev-server.command"
  cat > "$LAUNCHER" <<EOS
#!/bin/bash
cd "$SERVER_REPO"
./gradlew --stop
exec ./scripts/dev-server.sh 2>&1 | tee "$SERVER_LOG"
EOS
  chmod +x "$LAUNCHER"
  # -g = 前面に出さない(実行のたびにフォーカスを奪わない)。ウィンドウは閉じずに残す ——
  # この窓こそが「ローカルネットワーク」権限の担い手で、teardown も止めないので、
  # 生きた1枚が背面に残るだけ(以後の run は上の reuse で済み、新しい窓は開かない)
  echo "starting the sut-ec-mobile dev server via Terminal.app ($SERVER_REPO)"
  open -g -a Terminal "$LAUNCHER"
fi

# 5. 秒数で待たず、/health が ok を返すことを待つ。**上限まで黙って待たない** ——
# 起動が「進んでいない」形(権限で詰まる・ビルドが落ちる・プロセスが消える)は待っても直らないので、
# 分かった時点で落として理由とログを出す(上限まで待つと run 1本あたり最大 WAIT_SECONDS を捨てる)
fail_with_log() {
  echo "$1" >&2
  if [ -f "$SERVER_LOG" ]; then
    echo "--- tail of $SERVER_LOG ---" >&2
    tail -20 "$SERVER_LOG" >&2
  fi
  exit 1
}

echo "waiting for the dev server to become healthy (log: $SERVER_LOG)"
waited=0
while [ "$waited" -lt "$WAIT_SECONDS" ]; do
  if server_is_up; then
    echo "dev server is up after ${waited}s"
    exit 0
  fi
  if [ -f "$SERVER_LOG" ]; then
    # ローカルネットワーク権限で DB コンテナへ届かない形。待っても直らない
    if grep -qE "No route to host|EHOSTUNREACH" "$SERVER_LOG"; then
      echo "the server cannot reach the PostgreSQL container (EHOSTUNREACH)." >&2
      echo "grant the local network permission to the app that launched this run" >&2
      echo "(System Settings > Privacy & Security > Local Network), then retry." >&2
      fail_with_log "aborting: local network permission is missing"
    fi
    # ビルド/起動が落ちた形
    if grep -qE "BUILD FAILED|UnsupportedClassVersionError|Exception in thread \"main\"" "$SERVER_LOG"; then
      fail_with_log "the dev server failed to start"
    fi
  fi
  # ssh 経路では起動したプロセスの生死が分かる。消えていて health も上がっていなければ即失敗
  if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail_with_log "the dev server process exited before it became healthy"
  fi
  sleep 2
  waited=$((waited + 2))
done

fail_with_log "the dev server did not become healthy within ${WAIT_SECONDS}s"

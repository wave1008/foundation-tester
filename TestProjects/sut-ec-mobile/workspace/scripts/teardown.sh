#!/bin/sh
# テスト実行の後に、setup.sh と同じ機械の上で走る。
#
# **dev サーバも PostgreSQL も止めない**(2026-08-18 ユーザー決定)。理由:
#   - 止めると run のたびに Terminal.app のウィンドウ(手元の起動経路。setup.sh 参照)が
#     死骸として溜まり、次の run は起動待ち(10〜18秒+初回は分単位)を毎回払い直す
#   - DB はボリューム無しで setup 側の再構築が冪等・サーバも /health で再利用判定するので、
#     残しても次の run は汚れない
#   - サーバ側のコードを更新したときだけ手で止める: `kill $(lsof -ti tcp:8090)`
#     (または手元ならサーバの Terminal ウィンドウを閉じる)。次の setup.sh が新しい版で起こす
#
# 規則
#   - このファイルがあるときだけ実行される。要らなければ削除してよい。
#   - 終了コードは run の合否を変えない(失敗は警告として出るだけ)。
#   - setup.sh が失敗したときも実行されるので、途中まで起きた状態にも耐えること。
#   - "fleetest hooks reap" / "fleetest remote clean" からの代理実行では run の文脈が無いため、
#     FT_MACHINE・FT_REPORT_DIR・デバイス一覧は空になる。

set -u

HEALTH_URL="http://127.0.0.1:8090/health"

if curl -sf -m 3 "$HEALTH_URL" 2>/dev/null | grep -q '"status":"ok"'; then
  echo "leaving the dev server and PostgreSQL running (the next setup.sh reuses them;"
  echo "to pick up server code changes, stop it with: kill \$(lsof -ti tcp:8090))"
else
  echo "the dev server is not answering $HEALTH_URL — nothing to keep or clean"
fi

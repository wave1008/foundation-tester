#!/bin/sh
# テスト実行の前に走る(サンドボックスの中。docs/user-docs/reference/writing/extending_ja.md)。
# バックエンドは scripts/compose.yaml で宣言してあり、fleetest が起動完了(healthcheck)を待ってからこのスクリプトを呼ぶ。
# シードはサーバーが起動時に行う(Flyway + CatalogSeed)ので、ここでは公開ポートに届くことを確かめるだけ。
# 繋げるのは compose.yaml で公開した 127.0.0.1:8090 だけ(それ以外のポート・外部へは出られない)。
set -eu

curl -sf -m 5 http://127.0.0.1:8090/health
echo
echo "sut-ec-mobile server is answering at 127.0.0.1:8090"
fleetest-services status

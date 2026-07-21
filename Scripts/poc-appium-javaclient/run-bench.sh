#!/bin/zsh
# 本物の Appium Java Client ベンチの実行。前提: Appium サーバ(4723)起動済み・
# 対象シミュレータ Booted・SUTStore インストール済み・mvn package 済み(target/deps 生成済み)。
# 使い方: run-bench.sh <出力ndjson> <反復回数(warmup除く)> [udid] [bundleId]
set -eu
cd "$(dirname "$0")"
java -cp "target/poc-appium-javaclient-0.1.0.jar:target/deps/*" PocJavaClientBench "$@"

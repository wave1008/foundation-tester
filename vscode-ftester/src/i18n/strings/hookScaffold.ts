// 「スクリプトの雛形を作成する」が書き出すファイルの中身(src/runHookScaffold.ts)。
// **UI 文字列ではなく生成物**だが、利用者が読むコメントなので locale に追従させる
// (2026-08-18 ユーザー決定: 日本語モードならコメントも日本語)。
//
// 中身は実行規則の説明そのものなので、規則を変えたら Sources/FTCore/RunHooks.swift・
// Sources/ftester/RunHookRunner.swift・docs/remote-runner.md §17 と一緒に直す。
// **ja/en は同じ内容を書く**(片方だけ詳しい状態にしない)。

import type { MessageDict } from "../core";

export const hookScaffoldStrings = {
  "hookScaffold.setupTemplate": {
    ja: `#!/bin/sh
# テスト実行の前に、デバイスを動かす機械(この Mac、--host でディスパッチしたときはランナー機)
# の上で走る。テスト対象アプリが必要とするもの —— DB・スタブサーバ・初期データ —— の用意に使う。
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
# ワークスペースは丸ごとランナー機へ運ばれる。compose ファイルや初期データは ../data/ に
# 置いておけば向こうにも届く。逆に、起こしたサービスが状態やログをワークスペースの中に書くなら、
# そのパスをワークスペースの .ftester-transfer-ignore に書く(rsync の --exclude の書き方。
# 置いたディレクトリ起点)。書かないと次のディスパッチで手元の内容がランナー機のものを上書きする。
#
# テスト対象アプリからサービスへ届かせる方法: iOS シミュレータからはこの機械が 127.0.0.1、
# Android エミュレータからは 10.0.2.2 に見える。Android 実機は
# "adb -s <シリアル> reverse tcp:<ポート> tcp:<ポート>" が要る。この時点ではデバイスのシリアルは
# まだ確定していないので、必要なら "adb devices" を自分で叩くこと。

set -eu

# --- 例: DB とスタブサーバを起こす -------------------------------------------
# docker compose -f "$FT_WORKSPACE/data/compose.yaml" up -d
#
# # 秒数ではなく、観測できることを待つ。
# until nc -z 127.0.0.1 5432; do sleep 1; done
#
# # Android 実機からこの機械のスタブサーバへ届かせる。
# for serial in $(adb devices | awk '/\\tdevice$/ {print $1}'); do
#   adb -s "$serial" reverse tcp:8080 tcp:8080
# done
`,
    en: `#!/bin/sh
# Runs before the scenarios, on the machine that drives the devices (this Mac, or the
# remote runner when the run is dispatched with --host). Use it to start whatever the app
# under test needs: a database, a stub/mock server, seed data.
#
# Rules
#   - It runs only if this file exists. Delete it and nothing happens.
#   - A non-zero exit aborts the run: no scenario is executed, and the failure is
#     reported as an infrastructure failure rather than a test failure.
#   - It runs before any device is touched.
#   - teardown.sh always runs afterwards, including when this script fails.
#   - There is no timeout. Wait for the thing to be ready instead of sleeping blindly.
#
# Environment
#   FT_HOOK             "setup"
#   FT_WORKSPACE        absolute path of this workspace (also the working directory)
#   FT_PROJECT          test project name
#   FT_PROFILE          run profile name
#   FT_MACHINE          machine profile name
#   FT_REPORT_DIR       absolute path of the report directory
#   FT_IOS_DEVICES      device names this run will use, space separated (may be empty)
#   FT_ANDROID_DEVICES  same, for Android
#
# The whole workspace is copied to the remote runner, so keep compose files and fixtures
# under ../data/ and they will be there too. Conversely, if a service you start writes its
# state or logs inside the workspace, list those paths in the workspace's
# .ftester-transfer-ignore (rsync --exclude syntax, relative to the file's directory) —
# otherwise the next dispatch overwrites the runner's copy with this machine's.
#
# Reaching the service from the app under test: an iOS simulator sees this machine as
# 127.0.0.1, an Android emulator as 10.0.2.2, and a physical Android device needs
# "adb -s <serial> reverse tcp:<port> tcp:<port>". Device serials are not resolved yet at
# this point, so call "adb devices" here if you need them.

set -eu

# --- example: a database and a stub server -----------------------------------
# docker compose -f "$FT_WORKSPACE/data/compose.yaml" up -d
#
# # Wait for something observable, not for a fixed number of seconds.
# until nc -z 127.0.0.1 5432; do sleep 1; done
#
# # Let physical Android devices reach the stub server on this machine.
# for serial in $(adb devices | awk '/\\tdevice$/ {print $1}'); do
#   adb -s "$serial" reverse tcp:8080 tcp:8080
# done
`,
  },
  "hookScaffold.teardownTemplate": {
    ja: `#!/bin/sh
# テスト実行の後に、setup.sh と同じ機械の上で走る。setup.sh が起こしたものを止めて片付ける。
#
# 規則
#   - このファイルがあるときだけ実行される。要らなければ削除してよい。
#   - 終了コードは run の合否を変えない(失敗は警告として出るだけ)。片付けの失敗で
#     緑の run を赤にしないため。
#   - setup.sh が失敗したときも実行されるので、途中まで起きた状態にも耐えること
#     (下の例が "|| true" で終わっているのはそのため)。
#   - 片付ける前に run ごと殺された場合(ssh の切断・SIGKILL)は、この機械で次に走る run が
#     代わりにこのスクリプトを実行する。"ftester hooks reap" で手動でも実行でき、
#     リモートのランナー機に対しては "ftester remote clean" がこれを撃つ。
#   - 環境変数は setup.sh と同じ(FT_HOOK だけ "teardown" になる)。ただし上記の代理実行では
#     run の文脈が無いため、FT_MACHINE・FT_REPORT_DIR・デバイス一覧は空になる
#     (FT_WORKSPACE・FT_PROJECT・FT_PROFILE は常に入っている)。
#
# ここでは "set -e" を使わない。1つ失敗しただけで残りの片付けを飛ばさないため。

set -u

# --- 例: setup.sh がやったことを元に戻す -------------------------------------
# docker compose -f "$FT_WORKSPACE/data/compose.yaml" down -v || true
#
# for serial in $(adb devices | awk '/\\tdevice$/ {print $1}'); do
#   adb -s "$serial" reverse --remove tcp:8080 || true
# done
`,
    en: `#!/bin/sh
# Runs after the scenarios, on the same machine as setup.sh. Use it to stop and remove
# whatever setup.sh started.
#
# Rules
#   - It runs only if this file exists. Delete it and nothing happens.
#   - Its exit status does not change the run result: a failure here is only a warning,
#     so that a broken cleanup cannot turn a green run red.
#   - It also runs when setup.sh failed, so every step must tolerate a half-started
#     environment (that is why the examples below end with "|| true").
#   - If the run is killed before it can clean up (ssh disconnect, SIGKILL), the next run
#     on this machine runs this script instead. "ftester hooks reap" does the same on
#     demand, and "ftester remote clean" calls it on a remote runner.
#   - Same environment variables as setup.sh, except FT_HOOK is "teardown". When it is run
#     by the reaper there is no run context, so FT_MACHINE, FT_REPORT_DIR and the device
#     lists are empty (FT_WORKSPACE, FT_PROJECT and FT_PROFILE are always set).
#
# Do not use "set -e" here: one failing step should not skip the rest of the cleanup.

set -u

# --- example: undo what setup.sh did -----------------------------------------
# docker compose -f "$FT_WORKSPACE/data/compose.yaml" down -v || true
#
# for serial in $(adb devices | awk '/\\tdevice$/ {print $1}'); do
#   adb -s "$serial" reverse --remove tcp:8080 || true
# done
`,
  },
} satisfies MessageDict;

// 「スクリプトの雛形を作成する」が書き出すファイルの中身(src/runHookScaffold.ts)。
// **UI 文字列ではなく生成物**だが、利用者が読むコメントなので locale に追従させる
// (ユーザー決定: 日本語モードならコメントも日本語)。
//
// 中身は実行規則の説明そのものなので、規則を変えたら Sources/FTCore/RunHooks.swift・
// Sources/fleetest/RunHookRunner.swift・docs/remote-runner.md §17(スクリプトの枠)と一緒に直す。
// **ja/en は同じ内容を書く**(片方だけ詳しい状態にしない)。

import type { MessageDict } from "../core";

export const hookScaffoldStrings = {
  "hookScaffold.setupTemplate": {
    ja: `#!/bin/sh
# テスト実行の前に、デバイスを動かす機械(この Mac、--runner でディスパッチしたときはランナー機)
# の上で走る。テスト対象アプリが必要とするデータ —— 初期データなど —— の用意に使う。
#
# 規則
#   - このファイルがあるときだけ実行される。要らなければ削除してよい。
#   - 0 以外で終了すると run を中止する。シナリオは1本も実行されず、テストの失敗ではなく
#     インフラ起因の失敗として報告される。
#   - デバイスに触る前に実行される。
#   - このスクリプトが失敗した場合も含め、run-teardown.sh は必ず後で実行される。
#   - タイムアウトは無い。決め打ちの sleep ではなく、起きたことを確認して待つこと。
#
# サンドボックス(Seatbelt)の中で動く
#   - 書けるのは <workspace>/data/ の中だけ(と、この Mac の設定
#     ~/.config/fleetest/config.json の hooks.writablePaths に書いた場所)。scripts/・ホーム・
#     一時領域以外・.fleetest には書けない。一時ファイルは $TMPDIR(スクリプト専用。run の後に消える)。
#   - 読めない場所: ~/.ssh などの認証情報の置き場・秘密のファイル(シナリオと同じ)。
#   - 繋げるのは compose.yaml で公開したポート(127.0.0.1:<port>)と、この Mac の設定
#     sandbox.allowedDomains に書いた外部ドメイン(プロキシ経由。HTTP_PROXY / HTTPS_PROXY が入っている)
#     だけ。それ以外のポート・外部へは繋がらない。ブリッジ・adb・Docker には繋げない。
#   - サーバー・DB・スタブはこのスクリプトで起こさない(docker / docker compose / container は使えない)。
#     同じ scripts/ の compose.yaml に宣言する(fleetest が run ごとに起動して止める。起動完了
#     (healthcheck)を待ってから run-setup.sh が走る)。
#   - コンテナの中での操作は中継コマンド fleetest-services で(PATH にある):
#       fleetest-services exec <service> -- <command...>   (標準入力も渡せる)
#       fleetest-services logs <service> [--tail N]
#       fleetest-services status
#       fleetest-services port <service> <containerPort>[/udp]   (公開先の host:port を印字)
#   - 秘密: compose.yaml の environment が \${NAME} で参照した秘密は、この Mac の
#     ~/.config/fleetest/secrets/<project>.env から読まれ、その名前だけがこのスクリプトの
#     環境変数にも入る。スクリプトに秘密を書かない。
#   - このスクリプトが背景に残したプロセスは run の後に止められる(常駐させられない)。
#
# 環境変数
#   FT_HOOK             "setup"
#   FT_WORKSPACE        このワークスペースの絶対パス(カレントディレクトリでもある)
#   FT_PROJECT          テストプロジェクト名
#   FT_PROFILE          実行プロファイル名
#   FT_MACHINE          実行対象のマシン名(登録簿のエイリアス。手元は local)
#   FT_REPORT_DIR       レポート出力先の絶対パス(読めるが書けない)
#   FT_IOS_DEVICES      この run が使うデバイス名(空白区切り。空のこともある)
#   FT_ANDROID_DEVICES  同上、Android のぶん
#
# ワークスペースは丸ごとランナー機へ運ばれる。初期データは data/ に置いておけば向こうにも届く。
# 逆に、スクリプトが状態やログを data/ の中に書くなら、そのパスをワークスペースの
# .fleetest-transfer-ignore に書く(rsync の --exclude の書き方。置いたディレクトリ起点)。
# 書かないと次のディスパッチで手元の内容がランナー機のものを上書きする。
#
# Android 実機への adb reverse は fleetest が行う(スクリプトで adb は使えない)。

set -eu

# --- 例: データ投入 ----------------------------------------------------------
# fleetest-services exec db -- psql -U app < "$FT_WORKSPACE/data/seed.sql"
#
# # data/ の中へファイルを生成する。
# echo '{"user":"demo"}' > "$FT_WORKSPACE/data/fixture.json"
`,
    en: `#!/bin/sh
# Runs before the scenarios, on the machine that drives the devices (this Mac, or the
# remote runner when the run is dispatched with --runner). Use it to prepare the data the
# app under test needs, such as seed data.
#
# Rules
#   - It runs only if this file exists. Delete it and nothing happens.
#   - A non-zero exit aborts the run: no scenario is executed, and the failure is
#     reported as an infrastructure failure rather than a test failure.
#   - It runs before any device is touched.
#   - run-teardown.sh always runs afterwards, including when this script fails.
#   - There is no timeout. Wait for the thing to be ready instead of sleeping blindly.
#
# Runs inside a sandbox (Seatbelt)
#   - The only place you can write is <workspace>/data/ (plus any location listed in
#     hooks.writablePaths of this Mac's settings, ~/.config/fleetest/config.json). scripts/, the
#     home directory, temp areas other than $TMPDIR, and .fleetest are not writable. Use $TMPDIR
#     for scratch files (private to the script; removed after the run).
#   - Unreadable: credential stores such as ~/.ssh, and secret files (same as scenarios).
#   - Network: only the ports published in compose.yaml (127.0.0.1:<port>) and the external
#     domains listed in sandbox.allowedDomains of this Mac's settings (through the proxy;
#     HTTP_PROXY / HTTPS_PROXY are set). Every other port or host is unreachable. The bridge,
#     adb and Docker cannot be reached.
#   - Do not start servers, databases or stubs from this script (docker / docker compose /
#     container do not work). Declare them in compose.yaml in the same scripts/ directory:
#     fleetest starts and stops them for each run, and run-setup.sh runs only after they are up
#     (their healthcheck passed).
#   - To act inside a container, use the relay command fleetest-services (on PATH):
#       fleetest-services exec <service> -- <command...>   (stdin can be piped in)
#       fleetest-services logs <service> [--tail N]
#       fleetest-services status
#       fleetest-services port <service> <containerPort>[/udp]   (prints the published host:port)
#   - Secrets: a secret that compose.yaml references as \${NAME} in environment is read from
#     ~/.config/fleetest/secrets/<project>.env on this Mac, and only that name is also set as an
#     environment variable of this script. Never write secrets in the script.
#   - Processes this script leaves running in the background are stopped after the run (you
#     cannot keep a daemon alive).
#
# Environment
#   FT_HOOK             "setup"
#   FT_WORKSPACE        absolute path of this workspace (also the working directory)
#   FT_PROJECT          test project name
#   FT_PROFILE          run profile name
#   FT_MACHINE          the target machine's registered alias ("local" for this Mac)
#   FT_REPORT_DIR       absolute path of the report directory (readable, not writable)
#   FT_IOS_DEVICES      device names this run will use, space separated (may be empty)
#   FT_ANDROID_DEVICES  same, for Android
#
# The whole workspace is copied to the remote runner, so keep seed data under data/ and it
# will be there too. Conversely, if the script writes state or logs inside data/, list those
# paths in the workspace's .fleetest-transfer-ignore (rsync --exclude syntax, relative to
# the file's directory) — otherwise the next dispatch overwrites the runner's copy with this
# machine's.
#
# fleetest itself runs adb reverse for physical Android devices (adb is not available here).

set -eu

# --- example: load data ------------------------------------------------------
# fleetest-services exec db -- psql -U app < "$FT_WORKSPACE/data/seed.sql"
#
# # Generate a file under data/.
# echo '{"user":"demo"}' > "$FT_WORKSPACE/data/fixture.json"
`,
  },
  "hookScaffold.teardownTemplate": {
    ja: `#!/bin/sh
# テスト実行の後に、run-setup.sh と同じ機械の上で走る。run-setup.sh が入れたデータを片付ける。
# サービスの停止は fleetest がやるので、ここには書かない。
#
# 規則
#   - このファイルがあるときだけ実行される。要らなければ削除してよい。
#   - 終了コードは run の合否を変えない(失敗は警告として出るだけ)。片付けの失敗で
#     緑の run を赤にしないため。
#   - run-setup.sh が失敗したときも実行されるので、途中まで起きた状態にも耐えること
#     (下の例が "|| true" で終わっているのはそのため)。
#   - 片付ける前に run ごと殺された場合(ssh の切断・SIGKILL)は、この機械で次に走る run が
#     代わりにこのスクリプトを実行する。"fleetest hooks reap" で手動でも実行でき、
#     リモートのランナー機に対しては "fleetest remote clean" がこれを撃つ。
#   - 環境変数は run-setup.sh と同じ(FT_HOOK だけ "teardown" になる)。ただし上記の代理実行では
#     run の文脈が無いため、FT_MACHINE・FT_REPORT_DIR・デバイス一覧は空になる
#     (FT_WORKSPACE・FT_PROJECT・FT_PROFILE は常に入っている)。
#
# サンドボックス(Seatbelt)の中で動く
#   - 書けるのは <workspace>/data/ の中だけ(と、この Mac の設定
#     ~/.config/fleetest/config.json の hooks.writablePaths に書いた場所)。scripts/・ホーム・
#     一時領域以外・.fleetest には書けない。一時ファイルは $TMPDIR(スクリプト専用。run の後に消える)。
#   - 読めない場所: ~/.ssh などの認証情報の置き場・秘密のファイル(シナリオと同じ)。
#   - 繋げるのは compose.yaml で公開したポート(127.0.0.1:<port>)と、この Mac の設定
#     sandbox.allowedDomains に書いた外部ドメイン(プロキシ経由。HTTP_PROXY / HTTPS_PROXY が入っている)
#     だけ。それ以外のポート・外部へは繋がらない。ブリッジ・adb・Docker には繋げない。
#   - サーバー・DB・スタブはこのスクリプトで起こさない(docker / docker compose / container は使えない)。
#     同じ scripts/ の compose.yaml に宣言する(fleetest が run ごとに起動して止める。起動完了
#     (healthcheck)を待ってから run-setup.sh が走る)。
#   - コンテナの中での操作は中継コマンド fleetest-services で(PATH にある):
#       fleetest-services exec <service> -- <command...>   (標準入力も渡せる)
#       fleetest-services logs <service> [--tail N]
#       fleetest-services status
#       fleetest-services port <service> <containerPort>[/udp]   (公開先の host:port を印字)
#   - 秘密: compose.yaml の environment が \${NAME} で参照した秘密は、この Mac の
#     ~/.config/fleetest/secrets/<project>.env から読まれ、その名前だけがこのスクリプトの
#     環境変数にも入る。スクリプトに秘密を書かない。
#   - このスクリプトが背景に残したプロセスは run の後に止められる(常駐させられない)。
#
# 環境変数
#   FT_HOOK             "teardown"
#   FT_WORKSPACE        このワークスペースの絶対パス(カレントディレクトリでもある)
#   FT_PROJECT          テストプロジェクト名
#   FT_PROFILE          実行プロファイル名
#   FT_MACHINE          実行対象のマシン名(登録簿のエイリアス。手元は local)
#   FT_REPORT_DIR       レポート出力先の絶対パス(読めるが書けない)
#   FT_IOS_DEVICES      この run が使うデバイス名(空白区切り。空のこともある)
#   FT_ANDROID_DEVICES  同上、Android のぶん
#
# ここでは "set -e" を使わない。1つ失敗しただけで残りの片付けを飛ばさないため。

set -u

# --- 例: データの後始末 ------------------------------------------------------
# fleetest-services exec db -- psql -U app -c 'TRUNCATE orders, users' || true
#
# rm -f "$FT_WORKSPACE/data/fixture.json" || true
`,
    en: `#!/bin/sh
# Runs after the scenarios, on the same machine as run-setup.sh. Use it to clean up the data
# run-setup.sh put in place. Stopping services is done by fleetest, so do not write that here.
#
# Rules
#   - It runs only if this file exists. Delete it and nothing happens.
#   - Its exit status does not change the run result: a failure here is only a warning,
#     so that a broken cleanup cannot turn a green run red.
#   - It also runs when run-setup.sh failed, so every step must tolerate a half-started
#     environment (that is why the examples below end with "|| true").
#   - If the run is killed before it can clean up (ssh disconnect, SIGKILL), the next run
#     on this machine runs this script instead. "fleetest hooks reap" does the same on
#     demand, and "fleetest remote clean" calls it on a remote runner.
#   - Same environment variables as run-setup.sh, except FT_HOOK is "teardown". When it is run
#     by the reaper there is no run context, so FT_MACHINE, FT_REPORT_DIR and the device
#     lists are empty (FT_WORKSPACE, FT_PROJECT and FT_PROFILE are always set).
#
# Runs inside a sandbox (Seatbelt)
#   - The only place you can write is <workspace>/data/ (plus any location listed in
#     hooks.writablePaths of this Mac's settings, ~/.config/fleetest/config.json). scripts/, the
#     home directory, temp areas other than $TMPDIR, and .fleetest are not writable. Use $TMPDIR
#     for scratch files (private to the script; removed after the run).
#   - Unreadable: credential stores such as ~/.ssh, and secret files (same as scenarios).
#   - Network: only the ports published in compose.yaml (127.0.0.1:<port>) and the external
#     domains listed in sandbox.allowedDomains of this Mac's settings (through the proxy;
#     HTTP_PROXY / HTTPS_PROXY are set). Every other port or host is unreachable. The bridge,
#     adb and Docker cannot be reached.
#   - Do not start servers, databases or stubs from this script (docker / docker compose /
#     container do not work). Declare them in compose.yaml in the same scripts/ directory:
#     fleetest starts and stops them for each run, and run-setup.sh runs only after they are up
#     (their healthcheck passed).
#   - To act inside a container, use the relay command fleetest-services (on PATH):
#       fleetest-services exec <service> -- <command...>   (stdin can be piped in)
#       fleetest-services logs <service> [--tail N]
#       fleetest-services status
#       fleetest-services port <service> <containerPort>[/udp]   (prints the published host:port)
#   - Secrets: a secret that compose.yaml references as \${NAME} in environment is read from
#     ~/.config/fleetest/secrets/<project>.env on this Mac, and only that name is also set as an
#     environment variable of this script. Never write secrets in the script.
#   - Processes this script leaves running in the background are stopped after the run (you
#     cannot keep a daemon alive).
#
# Environment
#   FT_HOOK             "teardown"
#   FT_WORKSPACE        absolute path of this workspace (also the working directory)
#   FT_PROJECT          test project name
#   FT_PROFILE          run profile name
#   FT_MACHINE          the target machine's registered alias ("local" for this Mac)
#   FT_REPORT_DIR       absolute path of the report directory (readable, not writable)
#   FT_IOS_DEVICES      device names this run will use, space separated (may be empty)
#   FT_ANDROID_DEVICES  same, for Android
#
# Do not use "set -e" here: one failing step should not skip the rest of the cleanup.

set -u

# --- example: clean up the data ----------------------------------------------
# fleetest-services exec db -- psql -U app -c 'TRUNCATE orders, users' || true
#
# rm -f "$FT_WORKSPACE/data/fixture.json" || true
`,
  },
  "hookScaffold.composeTemplate": {
    ja: `# fleetest が run ごとに起動して止めるサービスの宣言。Docker と Apple Container のどちらでも同じ書き方。
# サービスが要らなければこのファイルは削除してよい(無ければ何も起動しない)。
# 起動完了(healthcheck)を待ってから run-setup.sh が走り、run-teardown.sh の後に止まる。
# スクリプトからは fleetest-services で操作する(run-setup.sh / run-teardown.sh の説明を参照)。
#
# 書けるもの
#   services.<name>: image | build, command, entrypoint, environment, env_file, ports, volumes,
#     depends_on(condition: service_started | service_healthy | service_completed_successfully),
#     healthcheck, stop_grace_period, working_dir, user, mem_limit, cpus, tmpfs, init, platform,
#     labels, networks
#   トップレベル: networks, volumes
# 書けないもの
#   restart・privileged・cap_add・network_mode・extra_hosts・ホストのパスの bind
#   (scripts/ と data/ の下だけ。scripts/ は読み取り専用)・外部ネットワーク。
#   知らないキーは断られる。
#
# 規則
#   - コンテナは外部ネットワークへ出られない(sandbox.allowedDomains のプロキシ経由だけ)。
#   - 公開ポートは 127.0.0.1 だけ。実機のレーンを含む run は全インターフェース(0.0.0.0)に公開する
#     (この Mac の設定 services.publishForPhysicalDevices に LAN アドレスを書くことがその同意)。
#   - イメージは手元に無いときだけ取得する。
#   - build: の context は scripts/ の下か、この Mac の設定 services.buildSources に書いた場所。
#   - 秘密は environment の値に \${NAME} で書く(値は ~/.config/fleetest/secrets/<project>.env から読まれる)。
#   - healthcheck を書くこと。無いと「起動した」時点で使えるとみなす。
#   - depends_on の service_completed_successfully の相手(初期化など)は前面で実行され、
#     終了コードで決着する。
#   - 名前付きボリュームは run をまたいで残る。消すのは "fleetest services reset"。

# --- 例: DB と API ------------------------------------------------------------
# services:
#   db:
#     image: postgres:16
#     environment:
#       POSTGRES_USER: app
#       POSTGRES_PASSWORD: \${DB_PASSWORD}
#       # Apple Container のボリュームは根に lost+found があり initdb が断るので、サブディレクトリを使う
#       PGDATA: /var/lib/postgresql/data/pgdata
#     volumes:
#       - dbdata:/var/lib/postgresql/data
#     healthcheck:
#       test: ["CMD-SHELL", "pg_isready -U app"]
#       interval: 2s
#       timeout: 3s
#       retries: 30
#
#   api:
#     image: example/api:latest
#     depends_on:
#       db:
#         condition: service_healthy
#     ports:
#       - "127.0.0.1:8080:8080"
#     environment:
#       API_TOKEN: \${API_TOKEN}
#
# volumes:
#   dbdata:
`,
    en: `# Declares the services fleetest starts and stops for each run. The syntax is the same for
# Docker and Apple Container.
# Delete this file if you need no services (nothing is started without it).
# run-setup.sh runs after they are up (healthcheck passed), and they are stopped after run-teardown.sh.
# Scripts operate on them with fleetest-services (see the comments in run-setup.sh / run-teardown.sh).
#
# Allowed
#   services.<name>: image | build, command, entrypoint, environment, env_file, ports, volumes,
#     depends_on (condition: service_started | service_healthy | service_completed_successfully),
#     healthcheck, stop_grace_period, working_dir, user, mem_limit, cpus, tmpfs, init, platform,
#     labels, networks
#   Top level: networks, volumes
# Not allowed
#   restart, privileged, cap_add, network_mode, extra_hosts, bind mounts of host paths
#   (only under scripts/ and data/; scripts/ is read-only), external networks.
#   Unknown keys are rejected.
#
# Rules
#   - Containers cannot reach external networks (only through the sandbox.allowedDomains proxy).
#   - Ports are published on 127.0.0.1 only. A run that includes a physical-device lane
#     publishes them on every interface (0.0.0.0); setting services.publishForPhysicalDevices
#     to this Mac's LAN address in its settings is your consent to that.
#   - Images are pulled only when they are not present locally.
#   - The context of build: must be under scripts/ or a location listed in services.buildSources
#     of this Mac's settings.
#   - Write secrets as \${NAME} in an environment value (read from
#     ~/.config/fleetest/secrets/<project>.env).
#   - Write a healthcheck. Without one, a service counts as ready as soon as it has started.
#   - A depends_on target with service_completed_successfully (initialization) runs in the
#     foreground and is settled by its exit code.
#   - Named volumes persist across runs. "fleetest services reset" removes them.

# --- example: a database and an API -------------------------------------------
# services:
#   db:
#     image: postgres:16
#     environment:
#       POSTGRES_USER: app
#       POSTGRES_PASSWORD: \${DB_PASSWORD}
#       # Apple Container's volumes have lost+found at their root, which initdb refuses; use a subdirectory
#       PGDATA: /var/lib/postgresql/data/pgdata
#     volumes:
#       - dbdata:/var/lib/postgresql/data
#     healthcheck:
#       test: ["CMD-SHELL", "pg_isready -U app"]
#       interval: 2s
#       timeout: 3s
#       retries: 30
#
#   api:
#     image: example/api:latest
#     depends_on:
#       db:
#         condition: service_healthy
#     ports:
#       - "127.0.0.1:8080:8080"
#     environment:
#       API_TOKEN: \${API_TOKEN}
#
# volumes:
#   dbdata:
`,
  },
} satisfies MessageDict;

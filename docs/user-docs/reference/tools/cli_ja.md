# CLI リファレンス(fleetest のサブコマンド)

[in English](cli.md)

`fleetest` のサブコマンドを用途別に並べた一覧です。各コマンドの引数の全体は `--help` で確かめられます。
このページは「どんなコマンドがあって、どれを見ればよいか」を引くための地図です。

## 呼び方

このドキュメントの `fleetest` は、作業フォルダの隣に foundation-tester をクローンした既定の構成では
`../foundation-tester/.build/debug/fleetest` です([クイックスタート](../../quick-start_ja.md)参照)。
foundation-tester のクローン内で作業している場合は `swift run fleetest` でも同じです。

```bash
../foundation-tester/.build/debug/fleetest --help                  # サブコマンドの一覧
../foundation-tester/.build/debug/fleetest help run                # サブコマンドの詳しいヘルプ
../foundation-tester/.build/debug/fleetest help bridge up          # 子コマンドの詳しいヘルプ
../foundation-tester/.build/debug/fleetest bridge --help           # 子コマンドの一覧
```

`fleetest help <サブコマンド>` で、そのサブコマンドの全オプションと既定値が出ます。
`bridge`・`project`・`profile`・`devices`・`results`・`remote`・`services`・`hooks`・`monitor`・`vision`・`api` は
子コマンドを持ちます。`fleetest --version` で版を確かめられます。

## 準備と診断

| コマンド | 説明 | 主なオプション | 詳細 |
|---|---|---|---|
| `init` | あなたのパッケージ(SPM で fleetest に依存する `Package.swift` と最初のテストプロジェクト)を作る | `--no-project`・`--name` | [クイックスタート](../../quick-start_ja.md) |
| `doctor` | Foundation Models・Xcode・Simulator の事前チェック。ブリッジのうち確実に古いものは止める | `--fm-only`・`--roots-only`・`--bundle <パス>` | [トラブルシューティング](../../in_action/troubleshooting_ja.md) |

`doctor --bundle <パス>` は、問題を報告するときに添付する診断ログの zip を書き出します(どこにも送信しません)。

## プロジェクトとプロファイル

| コマンド | 説明 | 主なオプション | 詳細 |
|---|---|---|---|
| `project create <名前>` | テストプロジェクトの雛形を作り、`Package.swift` に登録する | — | [テストプロジェクトの作成](../project/creating_project_ja.md) |
| `project list` | テストプロジェクトと、`Package.swift` への登録状況を一覧する | — | 同上 |
| `project sync` | `TestProjects/` の走査から `Package.swift` のマーカー部分を作り直す(手でコピーした後や git pull の後の再同期) | — | 同上 |
| `project lint-selectors` | シナリオの `#id` セレクタと契約(`ui-contract.md`)のずれを検査する(`#id` のみ) | `--project`・`--contract` | 同上 |
| `project copy <元> <新>` | テストプロジェクトを別名で複製する(reports / results / `.fleetest` の状態は除く) | — | 同上 |
| `project rename <旧> <新>` | テストプロジェクトの名前を変え、`Package.swift` を更新する | — | 同上 |
| `project delete <名前>` | テストプロジェクトをゴミ箱へ移し、`Package.swift` から外す | `--yes`(必須。無いと何もしない) | 同上 |
| `profile setup` | アプリプロファイルと実行プロファイルを整合させて作る(冪等) | `--platform`・`--app-id`・`--auto-device`・`--count`・`--app-path` | [プロファイル](../project/profiles_ja.md) |
| `profile list` | 実行プロファイルと構成要素を一覧し、この Mac での解決結果を表示する | `--project` | 同上 |

実行プロファイルの設定項目は[実行プロファイルの設定項目](../project/run_profile_ja.md)にあります。

## 実行と結果

| コマンド | 説明 | 主なオプション | 詳細 |
|---|---|---|---|
| `run` | Swift DSL のシナリオを実行する | `--profile`・`--scenario`・`--folder`・`--failed`・`--dry-run`・`--set`・`--junit`・`--runner`・`--fleet` | [シナリオの実行](../running/running_scenarios_ja.md) |
| `run-file <ファイル>` | 登録していない `.swift` のシナリオをそのまま実行する(プロファイルは既存のプロジェクトから借りる) | `--project`・`--profile`・`--scenario` | [シナリオの実行](../running/running_scenarios_ja.md) |
| `draft-scenario` | テストベース(`docs/testbases/*.md`)からシナリオの下書きを作る | `--testbase`・`--name`・`--no-fm`・`--dry-run` | [テストベースとシナリオの下書き](../running/testbases_ja.md) |
| `results list` | run を新しい順に一覧する | `--since`・`--limit`・`--json` | [結果の分析](../running/results_analysis_ja.md) |
| `results summary` | シナリオごとの実行回数・成功率・所要時間を集計する(成功率の低い順) | `--scenario`・`--since`・`--json` | 同上 |
| `results flaky` | 成功も失敗もしたシナリオを、ぶれの大きい順に一覧する | `--min-runs`・`--since` | 同上 |
| `results trend` | 1本のシナリオの実行履歴を時系列で表示する | `--scenario`(必須)・`--since` | 同上 |
| `results devices` | ワーカー(デバイス)ごと・プラットフォームごとの実行回数と成功率を集計する | `--since`・`--json` | 同上 |
| `results slow` | 平均所要時間の長い順にシナリオを一覧する | `--limit`・`--since` | 同上 |
| `results response` | レスポンス計測の run の応答時間(最初のフレームまで・操作可能まで)をステップごとに集計し、同じマシン・同じ端末の前回との差を出す | `--since`・`--json` | [レスポンス計測](../running/response_measurement_ja.md) |
| `results insights` | 注意すべき兆候(退行・連続失敗・アサーション以外の失敗・古くなったセレクタ)を検出する | `--since`・`--json` | [結果の分析](../running/results_analysis_ja.md) |
| `results log <runID>` | run のシナリオごとの実行ログ(`events/*.ndjson`)を表示する。runID に `latest` も使える | `--scenario`・`--raw` | 同上 |
| `clean` | 古い録画・実行ログ・レポート・ログ・Simulator の添付・xcresult を削除する。上限の 90% を超えたカテゴリを 90% まで掃除する | `--dry-run`・`--recordings`・`--event-logs`・`--reports`・`--logs` | [長く使うためのメンテナンス](../../in_action/maintenance_ja.md) |

## デバイスとブリッジ

| コマンド | 説明 | 主なオプション | 詳細 |
|---|---|---|---|
| `devices up` | 実行プロファイルのデバイスを起動する(同時に 2 台まで。起動済みは飛ばす) | `--profile`・`--no-bridge`・`--device-machine` | [シナリオの実行](../running/running_scenarios_ja.md) |
| `devices down` | ブリッジを止め、Simulator / Emulator を停止する(実機は停止せずブリッジだけ止める)。`--profile` を付けるとそのプロファイルのデバイスだけ | `--profile`・`--device-machine`・`--force` | [並列実行](../running/parallel_execution_ja.md) |
| `bridge up` | ブリッジを起動して常駐させる(iOS: Simulator のランナー / Android: デバイス上のサーバー) | `--device`・`--port`・`--physical`・`--platform` | [並列実行](../running/parallel_execution_ja.md) |
| `bridge down` | ブリッジを止める | `--port`・`--all`・`--platform`・`--force` | [並列実行](../running/parallel_execution_ja.md)・[実機を追加する](../../fleet/adding_physical_devices_ja.md) |
| `bridge status` | ブリッジの状態を表示する | `--platform`・`--port`・`--serial` | [トラブルシューティング](../../in_action/troubleshooting_ja.md) |
| `install <パッケージ>` | パッケージからアプリを入れる(iOS: `.app` / Android: `.apk` か `.apks`) | `--platform`・`--port`・`--serial` | 下の「デバイスを手で操作する」 |
| `launch <bundle-id>` | テスト対象のアプリを起動する | 同上 | 同上 |
| `terminate` | テスト対象のアプリを終了する | 同上 | 同上 |
| `monitor pause` | この Mac のデバイスモニター(観測と配信)を止める | `--for <分>` | [レスポンス計測](../running/response_measurement_ja.md) |
| `monitor resume` | 止めたモニターを再開する(冪等) | — | 同上 |
| `monitor status` | モニターを止めているかどうかを表示する | — | 同上 |

`monitor pause` は、性能を測る実行(`run --performance`)の前などに、モニターの定期取得を止めて VSCode 拡張に配信用ヘルパーを閉じさせます
(プロセスは kill しません。kill しても拡張がすぐ起動し直します)。`--for` の時間が過ぎると自動で解除されます。

## デバイスを手で操作する

MCP の `ft_*` ツール([MCP サーバー](./mcp_server_ja.md))と同じ操作の CLI 版です。ブリッジが起動している端末へ、
画面の読み取りと基本の操作を直接送ります。シナリオを書く前の画面の観察や、動作の切り分けに使えます。
宛先は共通のオプション `--platform`(ios / android。既定 ios)・`--port`(iOS のブリッジのポート。既定 8123)・
`--serial`(Android の端末。接続が 1 台だけなら省略可)で指定します。

| コマンド | 説明 | 主なオプション |
|---|---|---|
| `snapshot` | 今の画面のアクセシビリティの木を(圧縮して)表示する | `--json`(生の JSON) |
| `tap` | 要素か座標をタップする | `--ref`(snapshot の参照番号)・`--x`・`--y` |
| `type <テキスト>` | テキストを入力する(`--ref` を付けると先にその要素をタップする) | `--ref` |
| `swipe <方向>` | スワイプする(方向は up / down / left / right) | — |
| `press` | 要素を長押しする | `--ref`(必須)・`--hold-seconds` |
| `screenshot` | スクリーンショットを保存する | `-o` / `--output`(既定 `screenshot.png`) |

`install`・`launch`・`terminate` も同じ宛先オプションを取ります。`--ref` は直前の `snapshot` に出た参照番号です。

## サービスと hooks

| コマンド | 説明 | 主なオプション | 詳細 |
|---|---|---|---|
| `services up` | `scripts/compose.yaml` が宣言するサービスを起動し、`services down` まで常駐させる(探索・ライブ操作・シナリオ作成用。run は引き取って起動し直す) | `--profile`・`--physical`・`--serial` | [アプリが依存するサービス](../writing/services_ja.md) |
| `services down` | `services up` で起動したサービスを止める(run が持っているサービスは run に任せる) | `--profile` | 同上 |
| `services status` | このワークスペースのサービスの貸出・ロック・ランタイム資源を表示する | `--profile` | 同上 |
| `services pull` | `compose.yaml` が宣言するイメージを run の前に取得する(初回は中継用イメージもビルドする) | `--refresh` | 同上 |
| `services load` | レジストリへ届かない Mac のために、tar アーカイブからイメージをコンテナランタイムへ読み込む | — | 同上 |
| `services reset` | このワークスペースのサービスのコンテナ・ネットワーク・ボリューム、貸出とロックを消す | — | 同上 |
| `hooks reap` | 後始末の前に死んだ run が残した teardown スクリプトを実行する | `--quiet` | 同上 |

## フリート

| コマンド | 説明 | 主なオプション | 詳細 |
|---|---|---|---|
| `remote setup <マシン>` | リモートの Mac を `--runner` の送り先として用意する(冪等) | `--remote-dir`・`--skip-verify` | [Mac を追加する](../../fleet/adding_mac_ja.md) |
| `remote machines` | マシンの登録(手元の別名 → SSH の宛先)を扱う。子コマンドは `list`(既定)・`add`・`remove` | `add <マシン> --host <宛先>` | [リモート実行](../../fleet/remote_runners_ja.md) |
| `remote status` | ランナー機の到達性・ログイン状態・git の版・ツールチェーン・空きディスクを表示する | `--runner`・`--fm`・`--json` | 同上 |
| `remote align` | 手元の HEAD の版をランナー機で fetch・checkout・ビルドする(`remote setup` の版合わせの段だけ) | `--remote-dir` | 同上 |
| `remote exec <マシン> -- <引数>` | ランナー機で `fleetest <引数>` を実行し、出力と終了コードを中継する | `--remote-dir`(`--` の前に書く) | 同上 |
| `remote clean` | ランナー機の残ったブリッジ・Simulator を止め、`--keep-days` より古い結果・レポート等を消す | `--runner`・`--keep-days` | 同上 |
| `remote unlock` | 死んだ dispatch が残したロックを解く(生きている run のロックは `--force` なしでは解かない) | `--runner`・`--force` | 同上 |
| `remote teardown` | ランナー機のベースディレクトリを削除する(破壊的) | `--remote-dir` | 同上 |

`run` の `--runner`(1 台のランナー機へ送る)・`--fleet`(フリート定義で複数のマシンへ送る)・`--split`・`--broadcast`・
`--wait-lock` は[リモート実行](../../fleet/remote_runners_ja.md)と[並列実行](../running/parallel_execution_ja.md)にあります。

## 画像

| コマンド | 説明 | 主なオプション | 詳細 |
|---|---|---|---|
| `vision capture` | 画面の要素をアクセシビリティの枠で切り出し、画像分類器の見本画像として保存する | `--classifier`・`--label`・`--selector`(いずれも必須)・`--name` | [画像の検証](../commands/image_assertion_ja.md) |
| `vision check` | 必要なら分類器を学習し、各分類器が見分けられない見本画像を警告として報告する(終了コードは常に 0) | `--classifier`・`--project` | 同上 |

## 外部ツール向け(api)

`api` は、VSCode 拡張や MCP サーバーのような外部ツールが使う**機械向けの口**です(出力は標準出力の JSON か NDJSON、
診断は標準エラー出力)。人が日常的に打つものではありません。代表的な子コマンドだけを挙げます。全体は
`fleetest api --help` で確かめられます。

| 子コマンド | 説明 |
|---|---|
| `api list-scenarios` | ソース位置(ファイルと行)付きのシナリオ一覧を JSON で出す |
| `api steps` | シナリオを dry-run し、ステップ表に当たるものを JSON で出す |
| `api run` | シナリオを実行し、イベントを NDJSON で流す |
| `api monitor` | 実行プロファイルのデバイスを一定間隔で観測し、状態と画面を NDJSON で流す |
| `api list-devices` | この Mac のデバイスと現在の状態を一度だけ評価して JSON で出す |
| `api validate-profile` | プロファイル(apps / runs)の JSON を検証する |
| `api results` | 結果データベースを集計する(`fleetest results` の機械向け) |
| `api retention` | 保持容量(掃除の上限)の方針を読む・更新する |

拡張の使い方は [VSCode 拡張](./vscode_extension_ja.md)、MCP は [MCP サーバー](./mcp_server_ja.md)を参照してください。

### Link
- [index](../../index_ja.md)

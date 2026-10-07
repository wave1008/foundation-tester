# シナリオの実行(fleetest run)

[in English](running_scenarios.md)

`fleetest run` は Swift DSL シナリオを決定的に実行します(通常の再生も自己修復
(ロケータの指紋照合)も FM を呼びません)。このページでは CLI オプションを説明します。`--dry-run` は
[dry_run_ja.md](./dry_run_ja.md)、`--set` による自己修復の有効化は
[self_healing_ja.md](./self_healing_ja.md) を参照してください。

## CLI の呼び方

以降の `fleetest` は、作業フォルダの隣に foundation-tester をクローンした既定の構成では
`../foundation-tester/.build/debug/fleetest` です。foundation-tester のクローン内で作業している場合は
`swift run fleetest` でも同じです。

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
```

## 主なオプション

| オプション | 説明 |
|---|---|
| `--project <project>` | テストプロジェクト名(省略時の解決順は [creating_project_ja.md](../project/creating_project_ja.md) 参照) |
| `--profile <profile>` | 実行プロファイル名(`profiles/runs/<name>.json`)。ブリッジ供給と自動インストールを含む。**`--platform`/`--port`/`--serial`/`--app-id` とは併用できない**(プロファイルがそれらを全部供給するため)——併用すると黙って無視されず、エラーになる |
| `--scenario <id>` | シナリオ ID。クラス名だけならそのクラスの全シナリオ、`Class.method` で1本を指定。複数回指定可・既定は全件。`@Deleted`/`@Draft` シナリオは完全一致のときだけ実行される |
| `--folder <folder>` | 実行するシナリオフォルダ(`scenarios/` 直下のサブフォルダ)。複数回指定可、`--scenario`/`--failed` と併用可 |
| `--failed` | 前回失敗したシナリオだけ実行する。結果は毎回 `(project, profile)` 単位で `.fleetest/last-results/` に記録される —— あるプロファイルで落ちたシナリオが、別プロファイルの緑で隠れることはなく、`--profile` を指定しない実行は専用の区分を持つ。`--failed` はこの実行に指定した(または `--profile` 無しならその区分の)プロファイルの記録だけを見る。「失敗」はそのシナリオの直近の実行が通らなかったことで、**開始できなかったシナリオ**(担当のワーカー・デバイスが無い・run が中断された・デバイスの用意に失敗した)も含む。別の OS 向けの宣言で意図的に対象外になったシナリオは含まない |
| `--set <キー>=<値>` | この実行だけ、実行プロファイルのキーを上書きする(複数回指定可・`--profile` の有無を問わず効く。例: `--set heal=true`・`--set defaultTimeout=8`)。使えるキー・値の型・`--profile` が要るキーなどの規則は[実行プロファイルの設定項目](../project/run_profile_ja.md)にまとめてあります |
| `--dry-run` | デバイスに触れずステップを検証する([dry_run_ja.md](./dry_run_ja.md)参照) |
| `--report-dir <dir>` | レポート出力先(既定: `TestProjects/<name>/reports`)。`--set reportDir=...` と同時指定できない |
| `--port <port>` | iOS ブリッジのポート(`--profile` 無しのとき)。複数回指定すると手動の並列実行になる(`--port 8123 --port 8124`。[parallel_execution_ja.md](./parallel_execution_ja.md)参照) |
| `--skip-build` | 実行前の `swift build` をスキップする |
| `--quiet` | サマリのみ出力する(CI・エージェント向け) |
| `--junit <path>` | JUnit XML レポートをこのパスに出力する |
| `--broadcast` | 選択したシナリオを、共有配分ではなく実行プロファイルの**全デバイス**で1回ずつ実行する(warmup 等)。`--profile` が必須。結果は `worker` 欄で区別される([results_analysis_ja.md](./results_analysis_ja.md)参照) |
| `--no-lpt` | LPT 順序付け(実績時間の長い順)を無効化し、シナリオ ID 順で投入する |
| `--lpt-history-runs <n>` | LPT 順序付けに読む過去 run 数(既定 5) |
| `--runner <runner>` / `--fleet <fleet>` | SSH 経由でリモートマシン/フリートへディスパッチする([リモート実行](../../fleet/remote_runners_ja.md)参照) |
| `--platform <ios\|android>` | `--profile` 無しでの対象プラットフォーム(既定 `ios`) |
| `--app-id <bundleID>` | `@TestClass(app:)` 未指定シナリオの既定アプリ。`--profile` 無しのときだけ必要。`--set app=...` とは別物(実行プロファイルの `app` キーはアプリ**プロファイル名**を指す) |
| `--serial <s>` | Android デバイスの serial(`--profile` 無しのとき) |

最新の全一覧は `fleetest run --help` を実行してください。

## `run-file`

`fleetest run-file <path.swift>...` は `Package.swift` に**登録していない** `.swift` を1本以上
そのまま実行します(プロファイル・レポート・自己修復は `--project` で指定した既存プロジェクトから
借ります)。プロジェクトに足す前の使い捨てシナリオに便利です。`--project`・`--profile`・
`--scenario`・`--set`(例: `--set heal=true`)・`--report-dir`・`--port`・`--app-id`・
`--platform`/`--serial` を受け付けます。

## exit code と失敗セマンティクス

`fleetest run` は全て成功なら `0`、1つでも失敗すれば `1` を返します。シナリオ内では、コマンドが
失敗すると**そのシナリオの以降のステップは全て中断**されます(残る scene・ステップは全て
スキップ)。`afterEach()` だけは失敗後も実行されます。失敗モデルの詳細は
[testcode_structure_ja.md](../testclass/testcode_structure_ja.md) を参照してください。

## Android

同じコマンドに `--platform android` を付けるか、実行プロファイルに Emulator の `name` を
含めるだけで Emulator/実機を対象にできます。個別のセットアップは不要です
(端末常駐ブリッジ `AndroidRunner` が初回操作時に自動でインストール・起動します)。

```bash
fleetest run --platform android
```

## デバイス・ブリッジの管理

| コマンド | 説明 |
|---|---|
| `fleetest devices up` / `devices down` | 全実行プロファイルのデバイスの和集合を起動・停止する(`--profile` を付けるとそのプロファイルのデバイスだけ) |
| `fleetest bridge up` / `bridge down` / `bridge status` | 常駐ブリッジ(iOS: XCUITest ランナー / Android: 端末常駐サーバ)を管理する |

### Link
- [index](../../index_ja.md)

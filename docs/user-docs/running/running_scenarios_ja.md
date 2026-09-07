# シナリオの実行

`fleetest run` は Swift DSL シナリオを決定的に実行します(ステップが失敗し自己修復・トリアージが
有効なとき以外は FM を呼びません)。このページでは CLI オプションを説明します。`--dry-run` は
[dry_run_ja.md](./dry_run_ja.md)、`--set` による自己修復の有効化は
[self_healing_ja.md](./self_healing_ja.md) を参照してください。

## CLI の呼び方

```bash
# クローン構成(foundation-tester のクローン内で作業している場合)
swift run fleetest run --profile ios

# 外部パッケージ構成(TestProjects/ を持つ別の作業フォルダ)
../foundation-tester/.build/debug/fleetest run --profile ios
```

## 主なオプション

| オプション | 説明 |
|---|---|
| `--project <project>` | テストプロジェクト名(省略時の解決順は [creating_project_ja.md](../project/creating_project_ja.md) 参照) |
| `--profile <profile>` | 実行プロファイル名(`profiles/runs/<name>.json`)。ブリッジ供給と自動インストールを含む |
| `--scenario <id>` | シナリオ ID。クラス名だけならそのクラスの全シナリオ、`Class.method` で1本を指定。複数回指定可・既定は全件。`@Deleted`/`@Draft` シナリオは完全一致のときだけ実行される |
| `--folder <folder>` | 実行するシナリオフォルダ(`scenarios/` 直下のサブフォルダ)。複数回指定可、`--scenario`/`--failed` と併用可 |
| `--failed` | 前回失敗したシナリオだけ実行する(結果は毎回 `.fleetest/last-results/` に記録される) |
| `--set <キー>=<値>` | 実行プロファイル JSON のキー名そのものと、そのキーの型に合う値で、この実行だけキーを上書きする —— 真偽値キー(例: `heal`・`falsePositiveCheck`・`ocr`・`enableAnimations`・`iosFastInput`)は `true`/`false`、スカラーキーは文字列や数値(例: `--set reportDir=/tmp/out`・`--set defaultTimeout=8`)。全キーの一覧は [run_profile_ja.md](../project/run_profile_ja.md) 参照。複数回指定可・`--profile` の有無を問わず効く(ただし実行プロファイルの devices 一覧・供給工程が要るキー(`iosInappEngine`・`updateWebView`・`wipeDataOnBloat`・`recoverCpuFallbackToGpu`・`app`・`machine`・`locale`・`wipeDataThresholdGB`)だけは `--profile` が無いとキーを名指ししてエラー)。`record` は `--profile` か、`--ports` に2つ以上指定するかのどちらかが要る(単一接続には録画セッションを付けるところが無い)。`reportDir` は `--report-dir` と同時指定できない(同じ欄を二重に指定することになるため、どちらか一方を使う)。実行プロファイルのキー `app`/`machine` はアプリ/マシン**プロファイル名**を指し、このコマンド自身の `--app`/`--machine` フラグとは別物。`devices`/`remoteControl` は配列・オブジェクトなのでこの形では指定できない(実行プロファイル JSON を直接編集する)。未知のキー・型の合わない値・配列/オブジェクトのキーはエラー(対処法を示す) |
| `--dry-run` | デバイスに触れずステップを検証する([dry_run_ja.md](./dry_run_ja.md)参照) |
| `--report-dir <dir>` | レポート出力先(既定: `TestProjects/<name>/reports`)。`--set reportDir=...` と同時指定できない |
| `--ports <ports>` | 手動並列実行用のカンマ区切り iOS ブリッジポート([parallel_execution_ja.md](./parallel_execution_ja.md)参照) |
| `--skip-build` | 実行前の `swift build` をスキップする |
| `--quiet` | サマリのみ出力する(CI・エージェント向け) |
| `--junit <path>` | JUnit XML レポートをこのパスに出力する |
| `--broadcast` | 選択したシナリオを、共有配分ではなく実行プロファイルの**全デバイス**で1回ずつ実行する(warmup 等)。`--profile` が必須。結果は `worker` 欄で区別される([results_analysis_ja.md](./results_analysis_ja.md)参照) |
| `--no-lpt` | LPT 順序付け(実績時間の長い順)を無効化し、シナリオ ID 順で投入する |
| `--lpt-history-runs <n>` | LPT 順序付けに読む過去 run 数(既定 5) |
| `--host <host>` / `--fleet <fleet>` | SSH 経由でリモートマシン/フリートへディスパッチする([remote_runners_ja.md](../in_action/remote_runners_ja.md)参照) |
| `--platform <ios\|android>` | `--profile` 無しでの対象プラットフォーム(既定 `ios`) |
| `--app <bundleID>` | `@TestClass(app:)` 未指定シナリオの既定アプリ。`--profile` 無しのときだけ必要。`--set app=...` とは別物(実行プロファイルの `app` キーはアプリ**プロファイル名**を指す) |
| `--port <n>` / `--serial <s>` | `--profile` 無しでのブリッジポート(iOS)/デバイス serial(Android) |

最新の全一覧は `fleetest run --help` を実行してください。

## `run-file`

`fleetest run-file <path.swift>...` は `Package.swift` に**登録していない** `.swift` を1本以上
そのまま実行します(プロファイル・レポート・自己修復は `--project` で指定した既存プロジェクトから
借ります)。プロジェクトに足す前の使い捨てシナリオに便利です。`--profile`・`--scenario`・
`--heal`・`--ports` を受け付けます。

## exit code と失敗セマンティクス

`fleetest run` は全て成功なら `0`、1つでも失敗すれば `1` を返します。シナリオ内では、コマンドが
失敗すると**そのシナリオの以降のステップは全て中断**されます(残る scene・ステップは全て
スキップ)。`tearDown()` だけは失敗後も実行されます。失敗モデルの詳細は
[testcode_structure_ja.md](../testclass/testcode_structure_ja.md) を参照してください。

## Android

同じコマンドに `--platform android` を付けるか、実行プロファイルにエミュレータの `name` を
含めるだけでエミュレータ/実機を対象にできます。個別のセットアップは不要です
(端末常駐ブリッジ `AndroidRunner` が初回操作時に自動でインストール・起動します)。

```bash
fleetest run --platform android
```

## デバイス・ブリッジの管理

| コマンド | 説明 |
|---|---|
| `fleetest devices up` / `devices down` | マシンプロファイルの全デバイスを起動・停止する(`--profile` を付けるとそのプロファイルのデバイスだけ) |
| `fleetest bridge up` / `bridge down` / `bridge status` | 常駐ブリッジ(iOS: XCUITest ランナー / Android: 端末常駐サーバ)を管理する |

### Link
- [index](../index_ja.md)

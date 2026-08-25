# シナリオの実行

`fleetest run` は Swift DSL シナリオを決定的に実行します(ステップが失敗し自己修復・トリアージが
有効なとき以外は FM を呼びません)。このページでは CLI オプションを説明します。`--dry-run` は
[dry_run_ja.md](./dry_run_ja.md)、`--heal` は [self_healing_ja.md](./self_healing_ja.md) を
参照してください。

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
| `--heal` / `--no-heal` | 実行プロファイルの `heal` 設定を上書きし、自己修復を強制的に ON/OFF にする |
| `--dry-run` | デバイスに触れずステップを検証する([dry_run_ja.md](./dry_run_ja.md)参照) |
| `--report-dir <dir>` | レポート出力先(既定: `TestProjects/<name>/reports`) |
| `--ports <ports>` | 手動並列実行用のカンマ区切り iOS ブリッジポート([parallel_execution_ja.md](./parallel_execution_ja.md)参照) |
| `--skip-build` | 実行前の `swift build` をスキップする |
| `--quiet` | サマリのみ出力する(CI・エージェント向け) |
| `--junit <path>` | JUnit XML レポートをこのパスに出力する |
| `--broadcast` | 選択したシナリオを、共有配分ではなく実行プロファイルの**全デバイス**で1回ずつ実行する(warmup 等)。`--profile` が必須。結果は `worker` 欄で区別される([results_analysis_ja.md](./results_analysis_ja.md)参照) |
| `--enable-animations` | アプリのアニメーションを無効化せず残す |
| `--fast-input` | iOS XCUITest ブリッジの入力で quiescence 待ちを飛ばす |
| `--no-lpt` | LPT 順序付け(実績時間の長い順)を無効化し、シナリオ ID 順で投入する |
| `--lpt-history-runs <n>` | LPT 順序付けに読む過去 run 数(既定 5) |
| `--host <host>` / `--fleet <fleet>` | SSH 経由でリモートマシン/フリートへディスパッチする([remote_runners_ja.md](../in_action/remote_runners_ja.md)参照) |
| `--platform <ios\|android>` | `--profile` 無しでの対象プラットフォーム(既定 `ios`) |
| `--app <bundleID>` | `@TestClass(app:)` 未指定シナリオの既定アプリ。`--profile` 無しのときだけ必要 |
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

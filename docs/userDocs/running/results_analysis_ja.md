# 実行結果の分析

`fleetest run`(CLI・`fleetest api run` とも)は実行のたびに結果を
`TestProjects/<name>/results/` へ追記します。このページでは `fleetest results` コマンドと
失敗の読み方を説明します。JSON スキーマの唯一の定義元は
[../../results-json.md](../../results-json.md)(日本語)です。

## 構成

```
results/runs/<YYYY-MM>/<runID>/
  run.json                     ... この run 全体
  scenarios/<シナリオID>.json  ... シナリオ1回分の実行結果
  scenarios/<シナリオID>~2.json ... 同一 run 内の再実行(連番)
  host-metrics.ndjson          ... 実行中のホスト負荷(cpu/gpu/mem)
```

`results/` は追加専用で git と相性の良いレイアウトです。`runID` にマシン名+乱数を含むため、
別マシン・別ブランチの結果もコンフリクトなくマージできます。

## `fleetest results` コマンド

| コマンド | 説明 |
|---|---|
| `fleetest results list [--since <期間>] [--limit <n>]` | run を新しい順に一覧する |
| `fleetest results summary [--scenario <id>]` | シナリオ別の実行回数・成功率・所要時間を集計する(成功率が低い順) |
| `fleetest results flaky [--min-runs <n>]` | 成功も失敗もするシナリオを、不安定な順に一覧する |
| `fleetest results trend --scenario <id>` | 1シナリオの実行履歴を時系列で表示する |
| `fleetest results devices` | ワーカー(デバイス)別・プラットフォーム別の実行回数と成功率を集計する |
| `fleetest results slow [--limit <n>]` | シナリオを平均所要時間が長い順に一覧する |
| `fleetest results insights` | 実行履歴に対する10種の検査 —— [`insights` が検知するもの](#insights-が検知するもの)を参照 |

すべて `--project`、`--since <期間>`(`30d`/`12h` のような相対値、または `YYYY-MM-DD`。既定
`90d`)、単一行 JSON で出す `--json` を受け付けます。正確なフラグは
`fleetest results <サブコマンド> --help` で確認してください。

## `insights` が検知するもの

`insights` は記録された同じ事実を読み、**複数の run にまたがってはじめて見える傾向**を報告します。
検査は10種あり、それぞれ severity 付きの1行として出ます。

| kind | severity | 出る条件 |
|---|---|---|
| `newFailure` | critical | 連続して通っていたシナリオが落ちた(退行の疑い) |
| `consecutiveFailures` | critical | シナリオが複数 run 連続で落ちている |
| `infraFailures` | warn | アサーション以外の**署名**を持つ失敗が繰り返している —— 下の注記を参照 |
| `selectorDecay` | warn | そのシナリオの自己修復・フォールバック依存が増えている |
| `healReliance` | warn | 1つのセレクタが自己修復・キャッシュ経由でしか通っていない(提案されたセレクタを適用する) |
| `unsettledSteps` | warn | 画面がまだ動いている間にステップが進んだ(flake の先行指標) |
| `deviceBias` | warn | 失敗が特定のワーカー/デバイスに偏っている |
| `durationRegression` | warn | シナリオの所要時間が自身の過去実績に対して伸びた |
| `unfinishedRuns` | info | 完了しなかった run がある(クラッシュ・強制終了の可能性) |
| `retiredScenarios` | info | 結果は残っているが既に実行されていないシナリオ(上の検査からは除外される) |

> **`infraFailures` と「原因」について。** この行は**環境に何が起きていたかを主張しません**。
> 記録された署名 —— run がタイムアウトした、あるいは1ステップも到達しないまま `errorLogs` で
> 終わった —— で失敗を数え、アサーション失敗の件数と対比するだけです。失敗の大半がその形の
> シナリオは、アサーションで落ちているシナリオとは**別の観点で**見る価値がある、というのが
> この行の言っていることの全てです。アプリが重かったのかマシンが混んでいたのかの判断は、
> 引き続きツールの外の材料からあなたが行います。

## 失敗した run の読み方

ツールは観測できる事実だけを記録します —— 失敗が「環境要因」だったかは判定しません(アプリが
重いのかマシンが混んでいるのかは外から区別できないためです)。

| 知りたいこと | 見る欄 |
|---|---|
| どのフェーズで落ちたか | `failedSteps[].section` = `condition` / `action` / `expectation` / `setUp` / `tearDown` |
| 何のコマンドで落ちたか | `failedSteps[].command` |
| どの経路で落ちたか | `failedSteps[].failureKind`(下記) |
| そのステップで何が起きていたか | `failedSteps[].notes`(`interruption-dismissed` 等) |
| ステップに到達すらしなかったか | `failedSteps` が空 —— `errorLogs` / `skipKind` を見る |
| run 中にデバイスが飛んだか | `run.json` の `workerAnomalies` |

`failureKind` の値: `selector-syntax`(デバイスに触れる前の検証で落とした)、`not-found`
(スクロール探索を含めてロケータが解決できなかった)、`assertion`(値・状態が期待と違った)、
`driver-unreachable`(ブリッジへ到達できなかった)、`driver-error`(ブリッジがエラー応答を返した)、
`timeout`、`app-not-installed`、`system-ui-covered`(`iosAlertHandler` 登録中に OS のシステム UI
(権限アラート等)がアプリを覆っていた)。`failureKind` が無いのは**ツールが判断できなかった**
ことを意味し、推測で埋めることはしません。

```bash
# 失敗したシナリオを「フェーズ × failureKind × コマンド」で数える
jq -r 'select(.passed==false) | .failedSteps[0]
       | "\(.section // "-")\t\(.failureKind // "-")\t\(.command // "-")\t\(.description)"' \
  results/runs/2026-08/*/scenarios/*.json | sort | uniq -c
```

## VSCode で見る

コマンドパレットの **「fleetest: 結果ダッシュボードを開く」** で、直近の実行一覧・シナリオ別の
成功率と所要時間・不安定(flaky)シナリオ・デバイス/ワーカー別集計・日次推移・注意喚起を表示する
パネルが開きます(データは `fleetest results` と同じ集計を使います)。詳細は
[vscode-fleetest/README.md](../../../vscode-fleetest/README.md)の「結果ダッシュボード」を
参照してください。

## CI

`fleetest run --junit <path>` は JSON の結果に加えて JUnit XML レポートを出力します
(CI のテストレポート向け)。詳細は [ci_ja.md](../in_action/ci_ja.md) を参照してください。

### Link
- [index](../index_ja.md)

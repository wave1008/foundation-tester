# 実行結果の分析

`ftester run`(CLI・`ftester api run` とも)は実行のたびに結果を
`TestProjects/<name>/results/` へ追記します。このページでは `ftester results` コマンドと
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

## `ftester results` コマンド

| コマンド | 説明 |
|---|---|
| `ftester results list [--since <期間>] [--limit <n>]` | run を新しい順に一覧する |
| `ftester results summary [--scenario <id>]` | シナリオ別の実行回数・成功率・所要時間を集計する(成功率が低い順) |
| `ftester results flaky [--min-runs <n>]` | 成功も失敗もするシナリオを、不安定な順に一覧する |
| `ftester results trend --scenario <id>` | 1シナリオの実行履歴を時系列で表示する |
| `ftester results devices` | ワーカー(デバイス)別・プラットフォーム別の実行回数と成功率を集計する |
| `ftester results slow [--limit <n>]` | シナリオを平均所要時間が長い順に一覧する |
| `ftester results insights` | 退行・連続失敗・インフラ起因の失敗・古いセレクタなど注意が必要な事項を検知する |

すべて `--project`、`--since <期間>`(`30d`/`12h` のような相対値、または `YYYY-MM-DD`。既定
`90d`)、単一行 JSON で出す `--json` を受け付けます。正確なフラグは
`ftester results <サブコマンド> --help` で確認してください。

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

コマンドパレットの **「ftester: 結果ダッシュボードを開く」** で、直近の実行一覧・シナリオ別の
成功率と所要時間・不安定(flaky)シナリオ・デバイス/ワーカー別集計・日次推移・注意喚起を表示する
パネルが開きます(データは `ftester results` と同じ集計を使います)。詳細は
[vscode-ftester/README.md](../../../vscode-ftester/README.md)の「結果ダッシュボード」を
参照してください。

## CI

`ftester run --junit <path>` は JSON の結果に加えて JUnit XML レポートを出力します
(CI のテストレポート向け)。詳細は [ci_ja.md](../in_action/ci_ja.md) を参照してください。

### Link
- [index](../index_ja.md)

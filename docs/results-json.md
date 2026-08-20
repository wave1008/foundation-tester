# 実行結果の JSON(results/)

`ftester run` / `ftester api run` は結果を `<project>/results/` に貯める。
**このページがスキーマの唯一の定義元**(DTO は `Sources/FTCore/RunRecord.swift`)。

```
results/runs/<YYYY-MM>/<runID>/
  run.json                   ... この run 全体(RunMetaRecord)
  scenarios/<シナリオID>.json  ... シナリオ 1 回分(ScenarioRunRecord)
  scenarios/<シナリオID>~2.json ... 同一 run 内の再実行(連番)
  host-metrics.ndjson        ... 実行中のホスト負荷(cpu/gpu/mem)
```

`runID` = `<yyyyMMdd-HHmmss(UTC)>Z-<マシン名>-<乱数4hex>`(固定幅なので**辞書順 = 時系列順**)。

**後方互換の契約**: 欄はすべて後発追加が Optional。**古い run も読み続けられる**ように、
新しい欄が無い = キーごと省略される(空配列・false は書かない)。rawValue(`failureKind` /
`notes` の文字列)は永続化されるので**一度出したものは変えない**。

---

## 落ちた run の仕分け(このページの主目的)

**ツールは「環境要因の失敗」を判定しない**。アプリが重いのかマシンが混んでいるのかは
区別できず、推測を混ぜると誤った緑・誤った赤を作る。出すのは**事実**だけ:

| 知りたいこと | 見る欄 |
|---|---|
| どのフェーズで落ちたか | `failedSteps[].section` = `condition` / `action` / `expectation` / `setUp` / `tearDown` |
| 何のコマンドで落ちたか | `failedSteps[].command`(`tap` / `exist` …) |
| どの経路で落ちたか | `failedSteps[].failureKind`(下表) |
| そのステップに何が起きていたか | `failedSteps[].notes`(`interruption-dismissed` 等) |
| ステップに到達すらしなかったか | `failedSteps` が空 + `errorLogs` / `skipKind` |
| デバイスが飛んだ run か | `run.json` の `workerAnomalies`(構造化)/ `degradedWorkers`・`freezeRetries`(表示用) |

```bash
# 割り込みを閉じたステップで落ちた = 操作が吸われた可能性がある
jq -r 'select(.passed==false) | .failedSteps[]
       | select((.notes // []) | index("interruption-dismissed"))
       | "\(.section)\t\(.command)\t\(.description)"' \
  results/runs/2026-08/*/scenarios/*.json

# 落ちたシナリオを「フェーズ × 素性」で数える
jq -r 'select(.passed==false) | .failedSteps[0]
       | "\(.section // "-")\t\(.failureKind // "-")\t\(.command // "-")\t\(.description)"' \
  results/runs/2026-08/*/scenarios/*.json | sort | uniq -c

# ワーカーが飛んだ run を除外する
jq -r 'select(.workerAnomalies == null) | .runID' results/runs/2026-08/*/run.json
```

### failureKind(`StepFailureKind`)

| 値 | 意味 |
|---|---|
| `selector-syntax` | 実行前の構文検証で落とした。**デバイスには1度も触っていない** |
| `not-found` | ロケータが解決できなかった(スクロール探索を含めて木に居ない) |
| `assertion` | 要素は掴めたが期待した値・状態と違った |
| `driver-unreachable` | ブリッジへ到達できなかった(接続拒否・応答なし・アプリのプロセス死) |
| `driver-error` | ドライバは応答したがエラーを返した(HTTP エラー応答) |
| `timeout` | ステップが制限時間内に返らなかった |
| `app-not-installed` | 対象アプリがデバイスに入っていなかった(起動前の検査で確定) |
| (欄が無い) | **言えない** —— 推測で埋めない |

`not-found` は「画面が違う」と「セレクタが古い」を区別しない(どちらもこの経路)。
そこの判断は読み手が持つ情報(直前のステップ・注記・host-metrics)と合わせて行う。

---

## run.json(`RunMetaRecord`)

| フィールド | 型 | 意味 |
|---|---|---|
| schemaVersion | Int | レコードのスキーマ版(これより新しい版は読み手がスキップする) |
| runID | String | この run の ID |
| project | String | プロジェクト名 |
| profile | String? | 実行プロファイル名 |
| machine | String | 実行マシン名(sanitize 済み) |
| trigger | String | `"api"`(拡張)/ `"cli"` |
| startedAt / finishedAt | String / String? | ISO8601。**finishedAt が無い = 未完了**(クラッシュ検出) |
| total / passed / failed | Int? | 実行完了まで nil |
| workerAnomalies | [WorkerAnomalyRecord]? | ワーカー異常の構造化記録(下記)。**機械的な除外はここを見る** |
| degradedWorkers | [String]? | 劣化・離脱したワーカー(「label: 理由」)。表示用 |
| freezeRetries | [String]? | 結果取り消し+振り直しの監査記録。表示用 |
| blankRepairs / blankExclusions | [String]? | run 前の blank 判定で修復した / 除外したワーカー |
| measurementInvalid | Bool? | `--performance` の run でレーン数が変わり所要時間が計測に使えない |
| measurementInvalidReasons | [String]? | 同上の理由(英語) |
| issuer | String? | ディスパッチ発行者の自己申告(認証ではない) |

### WorkerAnomalyRecord

| フィールド | 型 | 意味 |
|---|---|---|
| kind | String | `degraded`(劣化・離脱)/ `requeued`(振り直し)/ `retryLimit`(上限到達で失敗記録) |
| worker | String? | `"<platform>:<デバイス論理名>"`。**`scenarios/*.json` の `worker` と同じ規則 = join できる** |
| label | String | 表示用の識別子(`degradedWorkers` の1行と同一) |
| scenarioID | String? | `requeued` / `retryLimit` の対象 |
| reason | String | 英語・人間可読 |

**`degradedWorkers` と `workerAnomalies` は同じ事象**(前者が人向けの1行、後者が機械可読)。
片方だけ増えることはない。

---

## scenarios/\*.json(`ScenarioRunRecord`)

| フィールド | 型 | 意味 |
|---|---|---|
| schemaVersion / runID / scenarioID | | シナリオ ID = クラス名.メソッド名 |
| title | String? | `@Test` のタイトル |
| platform | String | `ios` / `android` |
| worker | String? | `"<platform>:<デバイス論理名>"`(並列実行時) |
| machine / profile | String / String? | |
| passed | Bool | シナリオ全体の成否 |
| timedOut | Bool? | タイムアウトで強制終了したか |
| startedAt / durationMs | String / Int | |
| scenes | [SceneResultRecord] | シーン単位の合否・所要 |
| steps | StepCountsRecord | 状態別のステップ数(`total` / `passed` / `failed` / `skipped` / `healed` / `passedViaFallback` / `inconclusive` / `viaHeldValue`) |
| failedSteps | [FailedStepRecord]? | **失敗時のみ**。下記 |
| fixSuggestions | [FixSuggestionRecord]? | セレクタの修正提案(**成否によらず**残る) |
| errorLogs | [String]? | ❌/⚠️/⏱ で始まるログの末尾5件。**失敗時のみ** |
| fm | FMUsageRecord? | FM 呼び出しの実測(成否によらず) |
| timeline | [TimelineStepRecord]? | 全ステップ(到着順)。`notes` を含む |
| skipKind | String? | `notApplicable`(対象プラットフォーム外 = 意図された未実行)/ `noWorker`(ワーカー不在等の事故) |
| reportPath | String? | Markdown レポート(リポジトリルート相対。**gitignore なので他マシンからは開けない**) |

**ステップに到達しないまま落ちた run** では `failedSteps` が空になる(ブリッジ未接続・
デバイス消失など)。そのときの一次情報は `errorLogs` と `skipKind`、および run.json の
`workerAnomalies`。

### FailedStepRecord

| フィールド | 型 | 意味 |
|---|---|---|
| index | Int | シナリオ内の通し番号 |
| scene / sceneTitle | Int? / String? | 所属シーン |
| section | String? | `condition` / `action` / `expectation` / `setUp` / `tearDown`。ブロック外は無し |
| description | String | 人間可読なステップ説明(group の前置・注記の括弧書きを含む) |
| command | String? | DSL のコマンド名。**`description` を割って作らないこと** |
| failureKind | String? | 上表 |
| notes | [String]? | `StepNote` の rawValue(`interruption-dismissed` / `settle-capped` 等) |
| detail | String? | 失敗理由(英語・人間可読) |
| file / line | String? / Int? | ソース位置 |
| durationMs | Int? | 所要 |
| at | String? | 失敗確定時刻(録画の再生位置に使う) |

### TimelineStepRecord

全ステップを到着順に持つ(録画再生 UI のステップツリー用)。
`scene` / `sceneTitle` / `index` / `description` / `status` / `at` / `durationMs` / `notes`。
**run 横断で注記を数えるときは `description` の文言一致ではなく `notes` を見る**
(文言を変えた瞬間に集計が 0 件になる)。

---

## git での扱い

**1 run = 1 ディレクトリ・1 シナリオ実行 = 1 ファイルの追加専用レイアウト**なので、
複数マシン・複数ブランチの結果はコミット・マージで合流する(runID にマシン名+乱数を含むため
同じパスに二人が書くことがない。2ブランチ同時実行→マージでコンフリクト0を確認済み)。

- **上書きされるのは `run.json` の1回だけ**(実行完了時に `finishedAt` と集計を追記)。
  `scenarios/*.json` は追加専用 —— 同一 run 内の再実行は `~2` 連番で足す
- **コミット単位**はコード変更と混ぜず `results/` だけの独立コミットにする(レビュー不要・revert しやすい)
- **間引き**は月ディレクトリごと(`git rm -r '<project>/results/runs/2026-07'`)。月単位以外の部分削除はしない
- `reportPath` が指す Markdown レポート・PNG は **gitignore のまま**なので他マシンからは開けない。
  失敗調査の一次情報は `failedSteps` / `errorLogs`(このページの欄)にする

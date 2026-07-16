# results/ — 実行結果のファイルベース DB

`ftester run` / `ftester api run` の実行結果を git マージ安全な形で永続化する。
1 run(1 回の実行呼び出し)= 1 ディレクトリ、1 シナリオ実行 = 1 ファイルにすることで、
並列実行や複数マシンでの実行が同じファイルを同時に書き換えることを構造的に排除している。

## 運用規約

- **追加専用**: 一度書かれた `scenarios/*.json` は書き換えない。同一シナリオを再実行したら
  別ファイル(`~2` サフィックス)として追加する。`run.json` のみ、実行完了時に
  `finishedAt`・集計フィールドを追記するため 1 回だけ上書きされる。
- 生成・読み取りは `Sources/FTCore/RunRecorder.swift` / `RunResultsStore.swift` を経由すること。
  ディレクトリ構造やファイル名を直接前提にしたコードを書かない。

## ディレクトリ構造

```
results/
  runs/
    <YYYY-MM>/                  ... startedAt の UTC 年月
      <runID>/
        run.json                ... RunMetaRecord(この run 全体のメタ情報)
        scenarios/
          <シナリオID>.json      ... ScenarioRunRecord(シナリオ 1 回分)
          <シナリオID>~2.json    ... 同一シナリオを同一 run 内で再実行した場合の連番
```

## runID 規約

```
<yyyyMMdd-HHmmss>Z-<マシン名(sanitized)>-<乱数4hex>
```

- 時刻は UTC。固定幅なので **辞書順 = 時系列順** になる。
- マシン名は `[A-Za-z0-9_-]` 以外を `_` に置換したもの。
- 末尾 4 桁の乱数 hex は同一秒内の runID 衝突回避用。
- 月ディレクトリ(`<YYYY-MM>`)は runID 先頭の `yyyyMMdd` から導出する(startedAt と同じ UTC 日時)。

## スキーマ

`schemaVersion` は `run.json` と各 `scenarios/*.json` の両方に付与する。
読み取り側(`RunResultsStore.scanRuns`/`scanRecords`)は
`schemaVersion` が実装の対応バージョンより大きいファイルをスキップする
(古い実装が新しいレコードを誤読しないようにするため)。破損ファイルも同様にスキップする。

### run.json(RunMetaRecord)

| フィールド | 型 | 意味 |
| --- | --- | --- |
| schemaVersion | Int | このファイルのスキーマバージョン |
| runID | String | この run の ID |
| project | String | プロジェクト名(`Projects/<name>`) |
| profile | String? | 実行プロファイル名(未指定時は nil) |
| machine | String | 実行マシン名(sanitize 済み) |
| trigger | String | `"api"` \| `"cli"` |
| startedAt | String | 開始時刻(ISO8601) |
| finishedAt | String? | 終了時刻(ISO8601)。実行完了まで nil |
| total | Int? | 実行対象シナリオ総数。実行完了まで nil |
| passed | Int? | 成功シナリオ数。実行完了まで nil |
| failed | Int? | 失敗シナリオ数。実行完了まで nil |

### scenarios/\*.json(ScenarioRunRecord)

| フィールド | 型 | 意味 |
| --- | --- | --- |
| schemaVersion | Int | このファイルのスキーマバージョン |
| runID | String | 所属する run の ID |
| scenarioID | String | シナリオ ID(クラス名.メソッド名) |
| title | String? | シナリオのタイトル(`@Test` の引数) |
| platform | String | `ios` \| `android` など |
| worker | String? | `"<platform>:<デバイス論理名>"`。並列実行時のみ設定 |
| machine | String | 実行マシン名 |
| profile | String? | 実行プロファイル名 |
| passed | Bool | シナリオ全体の成否 |
| timedOut | Bool? | タイムアウトによる強制終了か |
| startedAt | String | 開始時刻(ISO8601) |
| durationMs | Int | 所要時間(ミリ秒) |
| scenes | [SceneResultRecord] | シーン単位の結果 |
| steps | StepCountsRecord | ステップの状態別カウント |
| reportPath | String? | レポートファイルへのパス(リポジトリルート相対) |
| failedSteps | [FailedStepRecord]? | 失敗ステップの詳細。**失敗時のみ**設定(成功時は常に nil) |
| fixSuggestions | [FixSuggestionRecord]? | 自己修復の提案。**失敗時のみ**設定(成功時は常に nil) |
| errorLogs | [String]? | ❌/⚠️/⏱ で始まるエラーログの末尾 5 件。**失敗時のみ**設定。ステップ到達前のインフラ失敗(ブリッジ未接続等)では failedSteps が空になるため、失敗原因の切り分けはここを見る |

#### SceneResultRecord

| フィールド | 型 | 意味 |
| --- | --- | --- |
| scene | Int | シーン番号 |
| title | String | シーンタイトル |
| passed | Bool | シーンの成否 |
| durationMs | Int? | 所要時間(ミリ秒)。取得できない場合は nil |

#### StepCountsRecord

| フィールド | 型 | 意味 |
| --- | --- | --- |
| total | Int | ステップ総数 |
| passed | Int | 成功 |
| failed | Int | 失敗 |
| skipped | Int | スキップ |
| healed | Int | 自己修復で成功 |
| passedViaFallback | Int | フォールバックセレクタで成功 |

#### FailedStepRecord

| フィールド | 型 | 意味 |
| --- | --- | --- |
| index | Int | シナリオ内のステップ通し番号 |
| scene | Int? | 所属シーン番号 |
| sceneTitle | String? | 所属シーンタイトル |
| section | String? | condition / action / expectation |
| description | String | 人間可読なステップ説明 |
| detail | String? | 失敗理由 |
| file | String? | ソースファイル(修正提案用) |
| line | Int? | ソース行 |
| durationMs | Int? | 所要時間(ミリ秒) |

#### FixSuggestionRecord

| フィールド | 型 | 意味 |
| --- | --- | --- |
| scene | Int? | 対象シーン番号 |
| file | String? | ソースファイル |
| line | Int? | ソース行 |
| oldSelector | String? | 旧セレクタ |
| newSelector | String? | 新セレクタ(修復候補) |

## バージョン履歴

- **v1**(2026-07): 初版。`RunMetaRecord` / `ScenarioRunRecord` を導入。

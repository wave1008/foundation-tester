# 実行結果の JSON(results/)

`fleetest run` / `fleetest api run` は結果を `<project>/results/` に貯める。
**このページがスキーマの唯一の定義元**(DTO は `Sources/FTCore/RunRecord.swift`)。

```
results/runs/<YYYY-MM>/<runID>/
  run.json                   ... この run 全体(RunMetaRecord)
  scenarios/<シナリオID>.json  ... シナリオ 1 回分(ScenarioRunRecord)
  scenarios/<シナリオID>~2.json ... 同一 run 内の再実行(連番)
  host-metrics.ndjson        ... 実行中のホスト負荷(cpu/gpu/mem)と FM(回数・死活)
```

`runID` = `<yyyyMMdd-HHmmss(UTC)>Z-<乱数8hex>`(固定幅なので**辞書順 = 時系列順**)。
2026-09-01 より前は `<yyyyMMdd-HHmmss(UTC)>Z-<マシン名>-<乱数4hex>`(ホスト名が表示へ漏れるため
マシン名を撤去し、複数マシンの衝突回避は乱数の拡幅で担保。旧形式もそのまま読める ——
どの機械の run かは `host` 欄が持つ)。

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
| `system-ui-covered` | **OS のシステム UI(権限アラート等)がアプリを覆っていた**。XCUITest ランナーの `GET /systemalert` の申告で、**`iosAlertHandler` の登録が残っている間だけ**出る |
| (欄が無い) | **言えない** —— 推測で埋めない |

`not-found` は「画面が違う」と「セレクタが古い」を区別しない(どちらもこの経路)。
そこの判断は読み手が持つ情報(直前のステップ・注記・host-metrics)と合わせて行う。

---

## フレークの推移を見る(run 横断)

上の節は**落ちた run 1つ**の仕分け。**複数の run を並べて「フレークは良くなったか」を言うときは、
先に分母を揃える**。揃えないと結論が逆に出る —— このリポジトリ自身の 2026-07〜08 の記録で、
素の失敗率は 1.13% → 2.06% → 2.14%(**悪化**)、下の4つを揃えると 0.89% → 1.11% → 0.80%
(**改善**)になった。

| 揃えるもの | なぜ | どうする |
|---|---|---|
| **run の本数** | デバッグ用の小さな run は**コードが半分直った状態**で回すので失敗率が桁違い(実測: 1〜2本の run は 18〜27%、30本+ の run は 0.5〜1.1%)。期間ごとに小さな run の比率が変わると、それだけで推移が動く | 30本+ の run だけを見る(下のレシピ) |
| **シナリオの集合** | 追加・削除が多い(2026-07〜08 の E2E は `(project, platform, scenarioID)` 601 通りのうち、3期間すべてに登場するのは 80)。**新しい witness は開発中なので落ちて当たり前** | 比べる全期間に登場するものだけに絞る(名前で外す判断は docs/verification.md §フレークの集計は「調査由来の失敗」を除いてから読む) |
| **標本数** | 1% のフレークは 40 回の実行では半分の確率で1度も現れない。**「フレークを示したシナリオ数」は実行回数が減るだけで下がる** | 期間ごとの最小回数へ間引いて再標本化する |
| **デバイス構成** | `worker` の顔ぶれは黙って変わる。**小画面・旧 API の台が1台入っただけで「Android が悪化した」に見える**(実例: `tap` が画面外の台でだけ落ちた) | `worker` 別に割り、片方の期間にしか居ない台は落とす |

```bash
# 30本+ の run(= フルスイート相当)のシナリオ実行だけを取り出す
find results/runs/2026-0[78] -mindepth 1 -maxdepth 1 -type d \
  -exec sh -c '[ "$(ls "$1"/scenarios 2>/dev/null | wc -l)" -ge 30 ] && ls "$1"/scenarios/*.json' _ {} \; \
  > /tmp/suite.txt

# シナリオ × 合否(分母と分子が同時に出る)
tr '\n' '\0' < /tmp/suite.txt | xargs -0 \
  jq -r '"\(.platform)\t\(.scenarioID)\t\(.passed)"' | sort | uniq -c

# 失敗をデバイス別に割る(台に固有か、シナリオに固有かの判別)
tr '\n' '\0' < /tmp/suite.txt | xargs -0 \
  jq -r 'select(.passed==false) | "\(.worker // "-")\t\(.scenarioID)"' | sort | uniq -c | sort -rn
```

**長い期間を跨ぐときは欄の欠落を先に確かめる**。後発追加はすべて Optional なので古い run には
無い —— このリポジトリ自身の記録では `failureKind` と `workerAnomalies` はどちらも
**2026-08-20 が初出**で、それ以前の失敗 1,205 件は経路が空。**「`not-found` が減った」と
読める推移は、欄が無かっただけのことがある。**

---

## run.json(`RunMetaRecord`)

| フィールド | 型 | 意味 |
|---|---|---|
| schemaVersion | Int | レコードのスキーマ版(これより新しい版は読み手がスキップする) |
| runID | String | この run の ID |
| project | String | プロジェクト名 |
| profile | String? | 実行プロファイル名 |
| host | String | **実行マシンのホスト名**(`FT_MACHINE` > hostname を sanitize したもの)。**LPT の同一マシン判定はこれ**。**マシン名(設定タブで付けたローカルエイリアス)は記録しない** —— エイリアスは頻繁に変わりうるので記録の鍵にしない(2026-08-26 ユーザー決定。用語は docs/remote-runner.md §0)。**旧キー `machine` の記録も読める** |
| trigger | String | `"api"`(拡張)/ `"cli"` |
| startedAt / finishedAt | String / String? | ISO8601。**finishedAt が無い = 未完了**(クラッシュ検出) |
| total / passed / failed | Int? | 実行完了まで nil |
| workerAnomalies | [WorkerAnomalyRecord]? | ワーカー異常の構造化記録(下記)。**機械的な除外はここを見る** |
| degradedWorkers | [String]? | 劣化・離脱したワーカー(「label: 理由」)。表示用 |
| freezeRetries | [String]? | 結果取り消し+振り直しの監査記録。表示用 |
| blankRepairs / blankExclusions | [String]? | run 前の blank 判定で修復した / 除外したワーカー |
| measurementInvalid | Bool? | `--performance` の run でレーン数が変わり所要時間が計測に使えない |
| measurementInvalidReasons | [String]? | 同上の理由(英語) |
| performanceMode | Bool? | `--performance` の run だけ true(false は書かない)。有効な計測 run = これが true かつ measurementInvalid が無い run。2026-09-01 より前の記録には無い |
| issuer | String? | ディスパッチ発行者の自己申告(認証ではない) |
| fmDead | [String]? | **run を閉じた時点**でこの機械の FM が死んでいた経路(`"text"` / `"vision"`。`FTCore.FMLiveness`)。生きていた・不明なら欄ごと省略 —— **欄が無いことを「生きていた」と読まない**。**run 全体の状態ではない**(途中で死んで戻った run はここに出ない。そちらは `scenarios/*.json` の `fm.failures` / `fm.firstError`)。**緑の run を仕分けるための欄** —— FM が死んだ run の緑は occlusion-guard・自己修復・screenLooksLike が素通りしただけかもしれない。2026-09-03 より前の記録には無い |
| fmDeadReason | String? | `fmDead` の理由(`text: … / vision: …`)。`fmDead` が無ければ省略 |
| runGroup | String? | **同じ実行から分かれた run を束ねる鍵**。デバイスが複数の機械にまたがるプロファイルは機械ごとに別 run(別 runID・別 machine・リモートは向こうの時計)になるので、`profile` と開始時刻では同じ実行かどうか決められない。ファンアウトの親が1回だけ発行し、手元の子にもリモートの子にも同じ値が入る。**単機の run と 2026-08-26 より前の記録では欠落**(束ねる相手が居ない) |

### host-metrics.ndjson の FM 欄

1行 = 1サンプル(既定 1Hz)。**回数と死活は別の軸**で、混ぜて読まないこと。

| フィールド | 型 | 意味 |
|---|---|---|
| fmCalls / fmFailures / fmTotalMs | Int? | そのサンプリング間隔で完了した FM 呼び出し(この機械の全プロセス合計。供給元は `FMUsageLedger`)。**null = 控えを読めなかった(不明)/ 0 = 呼び出しが無かった**。混ぜない |
| fmTextState / fmVisionState | String? | `"alive"` / `"dead"` / **null = 不明**(観測が無い・`FMLiveness.freshSeconds` より古い)。**呼び出しが0件でも埋まる**のが回数欄との決定的な違い —— 誰も FM を使っていない間、回数だけでは「使われていない」と「死んでいる」が同じ絵になる |
| fmDeadReason | String? | 死んでいる経路と理由(`text: … / vision: …`)。**1Hz で流れる行なので 200 文字で切る**(全文は `fleetest doctor --fm-only` と `scenarios/*.json` の `fm.firstError`) |
| fmCheckedAt | Double? | 上の死活を観測した epoch 秒(新しいほうの経路)。**いつの観測かを必ず見る** —— 最大 120 秒古くなりうる |

死活の供給元は2つ: **①実仕事の FM 呼び出しの成否**(連続 `FMBreaker.threshold` 回の失敗で死。
経路ごとに数える)と **②死活プローブ**(`api host-metrics --fm-probe`。拡張のモニターだけが渡す。
**台帳が古く、かつ誰も FM を使っていないときだけ**1回撃つ)。プローブは `FMUsageLedger` に
書かないので、回数欄は「実仕事」だけを表し続ける。

### WorkerAnomalyRecord

| フィールド | 型 | 意味 |
|---|---|---|
| kind | String | `degraded`(劣化・離脱)/ `requeued`(振り直し)/ `retryLimit`(上限到達で失敗記録)/ `circuitHeld`(連続失敗が閾値に達したが、その間に他のレーンが1本も通っていないので離脱させなかった。streak ごとに1件) |
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
| worker | String? | `"<platform>:<デバイス論理名>"`(並列実行時)。**`fleetest run --broadcast`(ブロードキャスト)では同じ `scenarioID` が台数ぶん並ぶ**(ファイルは `~N` 連番)ので、台ごとの合否はこの欄で引く |
| host / profile | String / String? | host = 実行マシンのホスト名(run.json と同じ。旧キー `machine` も読む) |
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

**`fm` の `gateWaitTotalMs` / `gateWaitP50Ms` / `gateWaitMaxMs`** は FM 呼び出しコスト
(`totalMs` 等)とは別軸で、`FMGate.enter()` が `FMLock`(ホスト単位の許可枠。既定5)で実際に
待たされた時間。枠を絞る/広げる判断材料 —— 待ちがほぼ0なら広げても解放されるものが無い。

**`fm` の `skipped`** は `FMGate` で止められ FM を呼ばずに諦めた回数(ブレーカ作動中 or 枠の
待ちが timeout 超過)。`calls`/`failures`(呼んで失敗)とは別物 —— occlusion-guard・heal・
screenLooksLike がこの回数ぶん静かに素通りしたことを事後に確認する材料。

### FailedStepRecord

| フィールド | 型 | 意味 |
|---|---|---|
| index | Int | シナリオ内の通し番号 |
| scene / sceneTitle | Int? / String? | 所属シーン |
| section | String? | `condition` / `action` / `expectation` / `setUp` / `tearDown`。ブロック外は無し |
| description | String | 人間可読なステップ説明(group の前置・注記の括弧書きを含む) |
| command | String? | DSL のコマンド名。**`description` を割って作らないこと** |
| failureKind | String? | 上表 |
| notes | [String]? | `StepNote` の rawValue(`interruption-dismissed` / `settle-capped` / `visibility-guard-skipped` / `system-alert-present` 等。全部の定義は `Sources/FTCore/StepNote.swift`) |
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

## `fleetest api results` の出力キャッシュ

ダッシュボード(VSCode 拡張)が叩く `fleetest api results` は、集計の入力が変わっていなければ
前回の出力を返す(`<project>/.fleetest/results-cache/api-results.json` と
`api-results-trend-index.json`。E2E-iOS 90 日分 1,092 run・2 万記録で 4.1s → 0.04s。2026-09-01 実測)。
定義元は `Sources/FTCore/ResultsOutputCache.swift`(有効判定・合成)と
`RunResultsStore.scanFingerprint`(入力の指紋)。

- **鍵**: 引数(project / `--since` の文字列 / limit / min-runs / matrix-runs)+ 実行ファイルの
  mtime・size(建て直せば必ず外れる = 集計や契約を変えたときにキャッシュの版を手で上げる規律に
  頼らない)+ 入力の指紋(走査する run ごとに `run.json` と `scenarios/` ディレクトリの
  stat 2回。記録の追加・削除・finish の上書き・rsync 回収はどれもエントリの作成/rename/削除なので
  必ず動く)。**捕まえないのは rename 無しの in-place 書き換えだけ**(記録の規律の外)
- **`--since 90d` は呼ぶたびに動く**ので鍵に入れず、「前回含めた最古の記録より手前に境界がある」
  条件で厳密に判定する(何も窓から落ちていない = 出力は同一)。落ちていれば計算し直す
- **`--scenario`(trend)は鍵に入れない**。scenarioID → 記録ファイルの索引を別ファイルに持ち、
  ヒット時はそのシナリオのファイルだけ読む(索引は同じ指紋の間だけ有効)
- 保存は1組だけ(引数が変わるたびに書き直す)。`fleetest results …`(人向け CLI)は使わない
- **`--no-cache`** = 読まずに計算する(書き直しは常に行う)。同じ入力で `--no-cache` の出力と
  一致すること(`generatedAt` 以外)が正しさの確認手段
- 書けない環境では毎回計算するだけ(失敗にしない)

## git での扱い

**1 run = 1 ディレクトリ・1 シナリオ実行 = 1 ファイルの追加専用レイアウト**なので、
複数マシン・複数ブランチの結果はコミット・マージで合流する(runID の乱数 8hex(2^32)で
同じパスに二人が書くことがない。旧形式はマシン名+乱数 4hex で同じ性質。
2ブランチ同時実行→マージでコンフリクト0を確認済み)。

- **上書きされるのは `run.json` の1回だけ**(実行完了時に `finishedAt` と集計を追記)。
  `scenarios/*.json` は追加専用 —— 同一 run 内の再実行は `~2` 連番で足す(振り直しで消した
  番号は**欠番のまま**。`--broadcast` では別の台が同じ ID を同時に書くので、詰めると次の
  書き込みが残っている番号を上書きする)
- **コミット単位**はコード変更と混ぜず `results/` だけの独立コミットにする(レビュー不要・revert しやすい)
- **間引き**は月ディレクトリごと(`git rm -r '<project>/results/runs/2026-07'`)。月単位以外の部分削除はしない
- `reportPath` が指す Markdown レポート・PNG は **gitignore のまま**なので他マシンからは開けない。
  失敗調査の一次情報は `failedSteps` / `errorLogs`(このページの欄)にする

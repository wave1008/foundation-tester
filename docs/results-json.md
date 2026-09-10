# 実行結果の JSON(results/)

`fleetest run` / `fleetest api run` は結果を `<project>/results/` に貯める。
**このページがスキーマの唯一の定義元**(DTO は `Sources/FTCore/RunRecord.swift`)。

```
results/runs/<YYYY-MM>/<runID>/
  run.json                   ... この run 全体(RunMetaRecord)
  scenarios/<シナリオID>.json  ... シナリオ 1 回分(ScenarioRunRecord)
  scenarios/<シナリオID>~2.json ... 同一 run 内の再実行(連番)
  host-metrics.ndjson        ... 実行中のホスト負荷(cpu/gpu/mem)と FM(回数・死活)/OCR(回数)
```

`runID` = `<yyyyMMdd-HHmmss(UTC)>Z-<乱数8hex>`(固定幅なので**辞書順 = 時系列順**)。
2026-09-01 より前は `<yyyyMMdd-HHmmss(UTC)>Z-<マシン名>-<乱数4hex>`(ホスト名が表示へ漏れるため
マシン名を撤去し、複数マシンの衝突回避は乱数の拡幅で担保。旧形式もそのまま読める ——
どの機械の run かは `host` 欄が持つ)。

## 保持容量(何がいつ消えるか)

run の完了時に保持容量の掃除が走る(既定 ON。切るのは `sweepAfterRun`)。**上限はカテゴリごとの
合計バイト数**で、新しい順に積んで上限を超えたところから古いセッションを**丸ごと**落とす
(半端に残るセッションを作らない)。判定は `FTCore.RetentionSweep.plan`(純粋関数)が唯一の定義元。

| カテゴリ | 対象 | 削除の単位 | 既定 |
|---|---|---|---|
| `deviceCaptures` | シミュレータ内の XCUITest 添付(録画・スクショ) | ブリッジのセッション | 20 GiB |
| `recordings` | `results/runs/<月>/<runID>/recordings/` | run 1件 | 100 GiB |
| `reports` | `<project>/reports/` の `.md` と `.png` | 日 1件 | 1000 MiB |
| `logs` | `<repoRoot>/.fleetest/*.log` | ファイル1本 | 500 MiB |

**結果 JSON は消えない**。`recordings/` を落としても `run.json` と `scenarios/*.json` は残るので、
フレークの推移も LPT の実績も過去に遡れる。**消えるのは録画とレポートだけ** —— 古い run の
`reportPath` が指す `.md` は消えている場合があり、読み手は不在に耐えること(拡張の2経路は
存在を確かめてから開く)。

**消さないもの(guarded)**: 進行中の run(`run.json` に完了時刻が無い)/ たった今終わった run /
今日のレポート / 生きているブリッジのログ / 稼働中ブリッジが開始した後の添付。
guarded だけで上限を超えていても**消せるものは全部消す**(上限に届かないことを理由に手を止めない)。

設定は `fleetest api retention`(マシン設定 `~/.config/fleetest/config.json`。VSCode 設定ではない
= 端末から直接打った run にも効く)。拡張はモニターの設定タブ「クリーンアップ」から同じ口を叩く。
手で回すのは `fleetest clean [--dry-run]`。**`--dry-run` は1バイトも消さずに一覧だけ出す**。

---

**後方互換の契約**: 欄はすべて後発追加が Optional。**古い run も読み続けられる**ように、
新しい欄が無い = キーごと省略される(空配列・false は書かない)。rawValue(`failureKind` /
`notes` の文字列)は永続化されるので**一度出したものは変えない**。

---

## `--since` / `--until` の文法

`fleetest results *` / `fleetest api results` の `--since`、`fleetest api host-metrics-summary` の
`--since` / `--until` が共有する唯一の実装は `Sources/FTCore/TimeBoundParse.swift`。
受理するのは3形だけ:

| 形 | 例 | 意味 |
|---|---|---|
| `<数>[smhd]` | `90s` / `30m` / `2h` / `30d` | 相対期間(小数可・0以下は拒否)。now から遡る |
| `YYYY-MM-DD` | `2026-09-01` | UTC 0時 |
| `@<epoch>` | `@1757280000` | unix epoch 秒(**`@` 接頭辞が必須**。小数可)。GNU `date -d @<epoch>` と同じ慣用 |

**裸の数値は拒否する** —— epoch として読むと `30d` の打ち間違いの `30` が epoch 30(≈1970年 =
実質全期間)として黙って通ってしまうため。どれにも一致しなければエラー(呼び出し側は
`TimeBoundParse.rejection(option:raw:)` の文言を返す)。時刻境界を取るオプションを新設するときは
必ずこの1箇所を通す。

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
| fmDead | [String]? | **run を閉じた時点**でこの機械の FM が死んでいた経路(`"text"` / `"vision"`。`FTCore.FMLiveness`)。生きていた・不明なら欄ごと省略 —— **欄が無いことを「生きていた」と読まない**。**run 全体の状態ではない**(途中で死んで戻った run はここに出ない。そちらは `scenarios/*.json` の `fm.failures` / `fm.firstError`)。**緑の run を仕分けるための欄** —— FM が死んだ run の緑は occlusion-guard・自己修復・screenLooksLike が素通りしただけかもしれない。2026-09-03 より前の記録には無い。**台帳(FMLiveness)の観測が古い/無い経路は、`FMBreaker.isOpen`(サーキットブレーカが開いている = 直前に連続失敗した既知の事実)が真なら dead として補う**(観測済みの経路は上書きしない。ブレーカは呼ばずに死と言える唯一の根拠 —— run 全体がブレーカ開の間に終わり、台帳が一度も更新されないまま run が閉じるケースを拾う。2026-09-09 より前の記録は台帳の観測だけで、この補いを持たない) |
| fmDeadReason | String? | `fmDead` の理由(`text: … / vision: …`)。**ブレーカ由来の補いは `"circuit breaker open"` になる**(実呼び出しの失敗理由が無いため)。`fmDead` が無ければ省略 |
| guarded | Int? | **occlusion-guard(誤った緑の検査)が run 全体で `occlusionFlip` の `visibilityGuardActive` 判定を通ったステップ数**(run 横断合計)。**分母は occlusionFlip に実際に入った回数であって、`visibilityGuardActive` が true になった回数(検査対象の候補数)ではない** —— tap 等のアクションは `occlusionFlip` を通らないのでこの欄には数えない。足切り(型・ラベル・インク)で FM を呼ばずに素通りした回も、`occlusionFlip` の入口ガードは通っているのでここに数える。1度もガードに入らなかった run では省略(0 は書かない) |
| guardSkipped | Int? | `guarded` のうち、FM が判定を返せず(死活・ブレーカ・直列化待ち)素通りした回(`visibility-guard-skipped`)。**`guarded` が1件以上ある run では、0件でも必ず書く**(欄が無い=観測なし、0=観測したが起きなかった、を混ぜない)。`guarded` が省略された run では同じく省略 |
| guardStaleFrame | Int? | `guarded` のうち、絵が古いまま撮り直しても stale で素通りした回(`stale-screenshot`)。`guardSkipped` と同じ 0/nil の規律 |
| runGroup | String? | **同じ実行から分かれた run を束ねる鍵**。デバイスが複数の機械にまたがるプロファイルは機械ごとに別 run(別 runID・別 machine・リモートは向こうの時計)になるので、`profile` と開始時刻では同じ実行かどうか決められない。ファンアウトの親が1回だけ発行し、手元の子にもリモートの子にも同じ値が入る。**単機の run と 2026-08-26 より前の記録では欠落**(束ねる相手が居ない) |
| fmSettings | FMSettingsRecord? | **その run で実際に効いていた FM 設定**(プロファイルの値そのものではなく、`--set heal=…`/`--set falsePositiveCheck=…` 等の CLI 上書きを反映した後の実効値)。下記の7フィールドを常に持つ。**欄が無い = この版より前の記録**であって、FM が無効だった意味ではない(fmDead 等と同じく「無い」と「false」を混ぜない) |

### fmSettings(`FMSettingsRecord`)

**7つのフィールドは常に明示的に書く**(true/false のどちらも省略しない)。`ocr`/`ocrFalsePositiveCheck` は `FMConfig` の外(実行プロファイルの独立した兄弟キー)だが、記録上はここへまとめてある。

| フィールド | 型 | 意味 |
|---|---|---|
| fm | Bool | FM 機能全体の親スイッチの実効値 |
| heal | Bool | FM によるロケータ自己修復の実効値 |
| falsePositiveCheck | Bool | occlusion-guard(偽陽性検証)の実効値 |
| screenLooksLike | Bool | `screenLooksLike` の実効値 |
| triage | Bool | 失敗時トリアージの実効値 |
| ocr | Bool | OCR 機能全体の親スイッチの実効値 |
| ocrFalsePositiveCheck | Bool | OCR を使ったテキストの偽陽性検証の実効値(`ocr` を掛けた後の値) |

### host-metrics.ndjson の FM/OCR 欄

1行 = 1サンプル(既定 1Hz)。**回数と死活は別の軸**で、混ぜて読まないこと。

| フィールド | 型 | 意味 |
|---|---|---|
| fmCalls / fmFailures / fmTotalMs | Int? | そのサンプリング間隔で完了した FM 呼び出し(この機械の全プロセス合計。供給元は `FMUsageLedger`)。**null = 控えを読めなかった(不明)/ 0 = 呼び出しが無かった**。混ぜない |
| ocrCalls / ocrFailures / ocrTotalMs | Int? | そのサンプリング間隔で完了した OCR(Vision の文字認識。occlusion-guard Tier-2 の `RegionText`)呼び出し(この機械の全プロセス合計。供給元は `OCRUsageLedger`)。**1件 = `recognize` 1回**(`RegionText.resolve` の拡大はしごは読めるまで最大3段まで撃つので、1回のガードで最大3件になりうる)。**null = 控えを読めなかった(不明)/ 0 = 呼び出しが無かった**。混ぜない |
| fmTextState / fmVisionState | String? | `"alive"` / `"dead"` / **null = 不明**(観測が無い・`FMLiveness.freshSeconds` より古い)。**呼び出しが0件でも埋まる**のが回数欄との決定的な違い —— 誰も FM を使っていない間、回数だけでは「使われていない」と「死んでいる」が同じ絵になる |
| fmDeadReason | String? | 死んでいる経路と理由(`text: … / vision: …`)。**1Hz で流れる行なので 200 文字で切る**(全文は `fleetest doctor --fm-only` と `scenarios/*.json` の `fm.firstError`) |
| fmCheckedAt | Double? | 上の死活を観測した epoch 秒(新しいほうの経路)。**いつの観測かを必ず見る** —— 最大 120 秒古くなりうる |

死活の供給元は2つ: **①実仕事の FM 呼び出しの成否**(連続 `FMBreaker.threshold` 回の失敗で死。
経路ごとに数える)と **②死活プローブ**(`api host-metrics --fm-probe`。拡張のモニターだけが渡す。
**台帳が古く、かつ誰も FM を使っていないときだけ**1回撃つ)。プローブは `FMUsageLedger` に
書かないので、回数欄は「実仕事」だけを表し続ける。**OCR に死活・プローブは無い**(回数欄だけ)。

### WorkerAnomalyRecord

| フィールド | 型 | 意味 |
|---|---|---|
| kind | String | `degraded`(劣化・離脱)/ `requeued`(振り直し。その回の `scenarios/*.json` は消える)/ `retryLimit`(上限到達。**最後の失敗記録はそのまま残る** —— `failedSteps` / `errorLogs` / `timeline` を持つ実物で、合成の skipped 記録には置き換えない)/ `circuitHeld`(連続失敗が閾値に達したが、その間に他のレーンが1本も通っていないので離脱させなかった。streak ごとに1件) |
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
| steps | StepCountsRecord | 状態別のステップ数(`total` / `passed` / `failed` / `skipped` / `healed` / `passedViaFallback` / `inconclusive` / `viaHeldValue` / `guarded` / `guardSkipped` / `guardStaleFrame`。最後の3つは下記) |
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

**`steps.guarded` / `guardSkipped` / `guardStaleFrame`(occlusion-guard がどれだけ効いたか)**:
「緑の run」がどれだけ強い緑かを言うための欄。**分母は `guarded`(occlusionFlip に実際に入った
ステップ数)であって、FM の判定を得た数ではない** —— `visibilityGuardActive` が true でも tap 等の
アクションは `occlusionFlip` を通らないので数えない一方、足切り(型・ラベル・インク)で FM を
呼ばずに通過した回は `occlusionFlip` の入口ガードを通っているので `guarded` に含む。
`guardSkipped`(FM が判定を返せず素通り)と `guardStaleFrame`(絵が古く素通り)は、その中で
「ガードに入ったのに判定を得られなかった」回。**差(`guarded - guardSkipped - guardStaleFrame`)を
「可視性を判定できた回数」と読んではいけない** —— 足切りで FM を呼ばずに通過した回も同じ差に
入っており、この記録から両者は分けられない。差が言えるのは「素通りとして数えなかった回」まで。
言えるのは**下限**(`guardSkipped + guardStaleFrame` は確実に判定を得ていない)であって、
上限ではない。**この2つは `guarded` が1件以上あれば0件でも必ず書く**
(欄が無い=一度もガードに入っていない、0=入ったが素通りは起きなかった、を混ぜない)。

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

`durationMs` の内訳として `snapshotMs` / `actionMs` / `waitMs`(Int?)も持つ。StepExecutor が
計測できたステップ(tap/exist 等)だけ非nil で、performCustom 経由(wait/procedure 等)は
durationMs のみ、skip・dry-run 等は3欄とも省略。**欄が無い=未計測であって0ではない**
(guarded 系と同じ規律)。2026-09-09 より前の記録には無い。

**締め切りの妥当性を測る2欄**(2026-09-10 以降): `scheduleDelayMs` = その async タスクを作ってから
**最初の1命令が走るまで**の順番待ち(協調スレッドプールの空き待ち)/ `cpuMs` = その間に
**プロセスが実際に貰えた CPU 時間**(user+sys の増分)。上限は壁時計なので、ホストが飽和していると
「仕事をしていないのに打ち切られた」が起こりうる —— この2欄があると
**「相手が固まっていた」「順番待ちだった」「飽和で進めなかった」**を記録だけで仕分けられる。
**`cpuMs` 単独でハングは判定できない**(ブリッジの応答待ちも CPU 0)。
発端は 2026-09-10 のフル E2E で、20 秒超のステップ 38 件の **99.7%** が
snapshot/action/wait のどれにも計上されない時間だった実測。

**その 99.7% の正体は occlusion-guard の OCR 段だった**(同日に決着)。切り分けに使った欄は4つ:

| 欄 | 意味 | 実測(120 秒で打ち切られたステップ) |
|---|---|---|
| `scheduleDelayMs` | 協調スレッドプールの順番待ち | 全件 0 = 入口は詰まっていない |
| `ioBlockedMs` | stdout/stderr の書き込みでブロックされた時間(プロセス全体) | 全件 0 = 出力経路ではない |
| `stallMs` | 専用 OS スレッドの心拍が遅れたぶん = **プロセス/機械ごと止まっていた時間** | 0 = 機械は止まっていない |
| `poolStallMs` | 協調スレッドプール上の心拍が遅れたぶん | 0 = プールは詰まっていない |
| `guardMs` | occlusion-guard の **Vision OCR 段と FM 照合段**(スクショは actionMs 側) | **所要の 99.7〜99.9%** |
| `ocrMs` | `guardMs` の内訳のうち **OCR 段だけ**(残りが FM 段)。注記 `ocr-budget-exhausted` と併せて読む | 修正後 p50 121 / p90 153 / max 456ms |

`guardMs > 0` のステップを1プロセス内で並べると、**最初にガードへ入った1ステップだけが
36〜108 秒を払い、以降は 100〜300ms** になる —— 仕事量ではなく**プロセスにつき 1 回の初期化**である
(正体は下の「36〜108 秒の正体」)。入っている対策は ①暖機は executor を作った時点で始め、
**別の暖機(`warm-ocr`)が走っていればその完了を待ってから読む** ②**モデルが載って実際に読めるまで
近道(OCR)は撃たない**(撃つとステップごとに予算を捨てるだけで、判定は結局 FM が下す)③**諦めた読みが
走っている間は積み増さない** ④載った後の劣化に備え OCR 段に予算
(`RegionText.occlusionBudget` = 1.3 秒 = 置き換える相手である FM 照合の実測下限)を持たせ、
超えたら FM へ落として注記 `ocr-budget-exhausted` を残す(設計は docs/design.md §Tier-2 の続き)。
**`ocr-budget-exhausted` の率が上がったら Vision が劣化している**(モデルが載っていない・OS 側の不調)。

**36〜108 秒の正体(同日に確定)**: Vision の認識器の実体(Espresso)のコンパイルキャッシュは
**プロセス名とバイナリの素性ごと**(`~/Library/Caches/<プロセス名>/com.apple.e5rt.e5bundlecache`。再ビルドでコールドに戻る)で、コンパイル
(コールド 20〜45 秒 × 言語集合 2)が**そのプロセスの生存中に終わったときだけ**コミットされる。
シナリオ実行プロセス(1シナリオ=1プロセス)はほぼ終わる前に死んで `.tmp` を残すだけ
(E2E-CMP で完了 1 / 放置 53)なので、**全プロセスが毎回ゼロから払っていた**。対策は
`fleetest-scenarios-<project> warm-ocr` —— run の開始時に**同じプロセス名の待てる子**を背景で 1 本
起こしてコミットさせる(`ScenarioHost.listForRun`。dry-run / MCP では起こさない。親の死を生き延びる
= コミット前に殺さない。機械で同時に 1 本 = `OCRWarmupLock`)。実測: シナリオ側の暖機
22,980ms → 216ms、実 crop の初回読み 21,830ms → 98〜122ms。

**コマンド上限(`FTSync.commandTimeout` = 120 秒)で打ち切られたステップも `durationMs` と `at` を
持つ**(2026-09-09 以降)。打ち切られた側は計時ごと失われるのでホストが測った実測値で、
**内訳の3欄は nil のまま**(外から測れないものを 0 で埋めない)。それ以前の記録では
**いちばん高いステップだけが時間ゼロ**で載り、`scenes[].durationMs` もその分を落としている ——
冷えた1周目の遅さを run 横断で比べるときは、この日を境に扱いが変わることに注意する。

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

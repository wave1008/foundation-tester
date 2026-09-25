---
paths:
  - "Sources/FTBridgeClient/BridgeLauncher.swift"
  - "Sources/FTCore/LPT*.swift"
  - "Sources/FTCore/Retention*.swift"
  - "Sources/FTCore/RetentionPolicy.swift"
  - "Sources/FTCore/RetentionSweep.swift"
  - "Sources/FTCore/RetentionSweepLock.swift"
  - "Sources/FTCore/RunOrchestrator.swift"
  - "Sources/FTCore/RunProgressLedger.swift"
  - "Sources/FTCore/RunRecord*.swift"
  - "Sources/FTCore/RunResults*.swift"
  - "Sources/FTCore/TimeBoundParse.swift"
  - "Sources/fleetest/ApiRunCommand.swift"
  - "Sources/fleetest/Fleetest.swift"
  - "Sources/fleetest/LPTOrdering.swift"
  - "Sources/fleetest/Results*.swift"
  - "Sources/fleetest/Retention*.swift"
  - "Sources/fleetest/RetentionSweeper.swift"
  - "Sources/fleetest/RunCompletionSweep.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherCaptureSettingsTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherNotRunningMessageTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherPidReuseTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherRebuildTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherStopTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherTokenInjectionTests.swift"
  - "Tests/FTCoreTests/RetentionPolicyTests.swift"
  - "Tests/FTCoreTests/RetentionSweepLockTests.swift"
  - "Tests/FTCoreTests/RetentionSweepTests.swift"
  - "Tests/FTCoreTests/RunProgressLedgerTests.swift"
  - "Tests/FTCoreTests/TimeBoundParseTests.swift"
  - "Tests/FleetestTests/LPTOrderingTests.swift"
  - "Tests/FleetestTests/RetentionSweeperRootsTests.swift"
  - "Tests/FleetestTests/RetentionSweeperXcresultTests.swift"
  - "Tests/FleetestTests/RunCompletionSweepWiringTests.swift"
  - "Tests/FleetestTests/RunProgressLedgerWiringTests.swift"
  - "docs/results-json.md"
---

# 結果 JSON・run ボード・保持容量の掃除・LPT の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **モニターの run ボード**(フリート横断の実行状況。**誰の run でも**「何本中何本」を出す。
  拡張が起こした run しか見えない `runEvent` の穴を塞ぐ): 契約は **docs/design.md §18 が唯一の定義元**。
  供給は機械グローバルの台帳 `~/.fleetest/runs/<pid>.json`(`FTCore.RunProgressLedger`。
  **プロジェクトの `.fleetest/` に置かない** = ランナー機では発行者ごとに work が分かれ他人の run が
  見えなくなる)→ `api monitor` が `monitorRuns` で配る → リモートは fan-out が machine を埋める。
  守る規律5つ: **①記帳は `RunOrchestrator` の1箇所・注入は run / api run の2経路**
  (`RunProgressLedgerWiringTests` が走査で固定。片方だけだとその経路の run が緑のまま映らない)/
  **②生存判定は pid と `startedAt` の開始時刻照合**(mtime を見ない。pid の再利用は `ProcessLiveness.isAliveAndNotStartedAfter` が弾く)/ **③死んだ控えは書き手が run 開始時に掃く**
  (読み手は毎周期読むので掃除を置かない)/ **④経過は読み手(同じ機械の monitor)が秒に直して運ぶ**
  (向こうの時計を手元で解釈しない)/ **⑤レーンごとの残り本数は持たない**(shared キューでは
  同じ数字が並ぶだけで誤読を招く)
- **結果 JSON のスキーマ**(run.json / scenarios/*.json の全欄・落ちた run の仕分けレシピ・
  **フレークの推移を run 横断で見るときに先に揃える4つ**(run の本数 / シナリオの集合 / 標本数 /
  デバイス構成)。揃えないと同じデータが改善にも悪化にも読める):
  docs/results-json.md(**唯一の定義元**。`results/` は .gitignore なので中に README を置いても
  受け手に届かない)。**`api results` の出力キャッシュ**(`<project>/.fleetest/results-cache/`。
  鍵は引数 + 実行ファイル + run ごとの stat 2回・`--since` は「窓から落ちた記録が無い」条件で厳密判定・
  確認は `--no-cache` との一致)も同ページ
- **`--since` / `--until` の文法は `FTCore.TimeBoundParse` が唯一の定義元**(docs/results-json.md
  §`--since`/`--until` の文法)。時刻境界を取るオプションを新設するときは必ずここを通す
- **保持容量の掃除は run の完了後に背景の別プロセスで**(`RunCompletionSweep.spawn` →
  `fleetest clean --background`。**テストの実行時間に含めない** = ユーザー決定。開始時に置く・
  run の中で同期に走らせる形へ戻さない)。起こすのは**結果を書く3経路**(`Fleetest.swift` の
  プロファイル経路・プロファイル無し経路・`ApiRunCommand`)で、`RunCompletionSweepWiringTests` が
  本数・順序(結果の後)・「記録開始の直後に無いこと」を固定する。**子の標準入出力は3本とも
  /dev/null**(継がせると拡張は NDJSON の EOF を、ssh は channel の閉鎖を掃除の終わりまで待つ)・
  **`FT_PARENT_PID` を抜く**(渡すと親の終了と同時に殺される)。**消す処理は機械で同時に1本**
  (`FTCore.RetentionSweepLock` = flock。背景は先客がいれば黙って抜け、手動は名指しして断る。
  dry-run は取らない)。**発動は上限の 90% 超・目標も 90%**(`RetentionPolicy.sweepTriggerPercent`)。
  判定は `FTCore.RetentionSweep.plan`(純粋関数)の1箇所・採取と削除は
  `Sources/fleetest/RetentionSweeper.swift`。**削除の一覧と通知は口を分ける**(`log` / `notice`)。
  既定値は `FTCore.RetentionPolicy` の1箇所だけ・拡張は `api retention` の実効値を表示する。
  **`api retention` の使用量は `--usage` を付けたときだけ測る**。**レポートの単位は run ではなく日**・
  **セッション内のパスを `URL.path` で並べ替えない**(日本語名の正規化で採取の 98% を食った)。
  **XCUITest ランナーの自動記録は起動時に止める**(`BridgeLauncher.captureSettings` = 静止画・常に捨てる。
  ビルド既定の「動画・成功時に捨てる」は終わらないテストでは永久に捨てられず 870 GB 溜まった。
  `BridgeLauncherCaptureSettingsTests` がリテラルで固定。**旧形式の xctestrun(トップレベルに対象)も通す**
  —— 実際のビルドが書くのは旧形式)。**ブリッジの `xcodebuild` には `-resultBundlePath` と
  `-derivedDataPath` を必ず渡す**(渡さないと既定の DerivedData に起動ごとのフォルダを積む)。
  **生きたランナーの居ないポートの束は供給の入口で消す**(`BridgeLauncher.sweepOrphanResultBundles`。
  起動時の掃除は同じポートで起動し直したときしか消さず、復活でポートが変わると残った = 4.1GB)。
  **掃除が見る場所は2つ**(`RetentionSweeper.Roots` = パッケージ / ツール。1つの値で兼ねない ——
  受け手の外部構成では別の場所で、兼ねると受け手の録画・レポートを1度も掃除しなかった。
  **保守者のクローン構成では一致するので手元の実データでは出ない** = テストは必ず別の一時フォルダで)
  → docs/results-json.md §保持容量
- **LPT の実績 run 数の既定値は3箇所(`LPTOrdering.defaultHistoryRuns` / `package.json` の
  `fleetest.lptHistoryRuns.default` / `monitorPanel.ts` が webview へ送る default)で一致必須**
  (`lptDefaultSync.test.mjs` が検出)

---
paths:
  - "Scripts/heal-verify.sh"
  - "Sources/FTCore/DuplicateRegion*.swift"
  - "Sources/FTCore/DuplicateRegion.swift"
  - "Sources/FTCore/FTSelector*.swift"
  - "Sources/FTCore/FTSelector.swift"
  - "Sources/FTCore/Flow.swift"
  - "Sources/FTCore/HealFixApplier.swift"
  - "Sources/FTCore/LocatorFingerprint*.swift"
  - "Sources/FTCore/LocatorFingerprint.swift"
  - "Sources/FTCore/ScenarioCodeGen.swift"
  - "Sources/FTCore/SelectorNaming*.swift"
  - "Sources/FTCore/SelectorNaming.swift"
  - "Sources/FTCore/SnapshotRendering*.swift"
  - "Sources/FTCore/StepNote.swift"
  - "Sources/FTCore/TapTargetGeometry.swift"
  - "Sources/FTCore/TreeCoverage*.swift"
  - "Sources/FTCore/TreeCoverage.swift"
  - "Sources/FTDSL/Commands.swift"
  - "Tests/FTCoreTests/DuplicateRegionTests.swift"
  - "Tests/FTCoreTests/LocatorFingerprintClampedResolutionTests.swift"
  - "Tests/FTCoreTests/LocatorFingerprintResolutionTests.swift"
  - "Tests/FTCoreTests/LocatorFingerprintTests.swift"
  - "Tests/FTCoreTests/ScenarioCodeGenClassNameTests.swift"
  - "Tests/FTCoreTests/SelectorNamingTrailingWildcardEscapeTests.swift"
  - "Tests/FTCoreTests/StepNoteTests.swift"
  - "Tests/FTCoreTests/TapTargetGeometryIsPointOnScreenTests.swift"
  - "Tests/FTCoreTests/TreeCoverageTests.swift"
  - "Tests/FTDSLTests/FTSelectorTests.swift"
  - "Tests/FTDSLTests/LocatorFingerprintExpiryTests.swift"
  - "Tests/FTDSLTests/LocatorFingerprintRecordingTests.swift"
  - "Tests/FTDSLTests/ScenarioCodeGenPlacementTests.swift"
  - "Tests/FTDSLTests/ScenarioCodeGenTests.swift"
  - "Tests/FleetestMCPTests/DuplicateRegionNoteTests.swift"
---

# セレクタ・スナップショット・自己修復(指紋照合) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **「木が画面を代表していない」判定は `FTCore.TreeCoverage` の1箇所**(webView の内側に大きな
  空白帯が残る形と、アドレス欄はあるのにページ本体が1要素も無い形)。**失敗の型は打ち切りと同じ**
  (不完全な木で否定アサーションが誤って成功する)ので、DSL の notExists/count も
  `StepNote.treeUnderreported` を運ぶ。**判定は変えず注記だけ** —— 幾何からの疑いであって
  申告された事実ではないので、断定すると空のページに対する正当な `notExist` が書けなくなる。
  同型で `FTCore.DuplicateRegion`(横スクロールで前後のコピーが両方 木に残る形。DSL の tap は
  `StepNote.staleDuplicateRegion`)—— こちらは `hasClampedCoordinates` では**発火し得ない**ので
  独立に持つ。どちらも固定コーパスで**発火する画面の集合を等号で固定**する
  (`TreeCoverageTests` / `DuplicateRegionTests`)
- **要素上限の撮り直しは肯定側にも要る**。`retakenAtElementLimitCeiling` は notExists/count
  (誤った成功)だけを塞いでいたが、操作側は**実在する要素で赤くなる**。操作側は**ドライバ切替と
  指紋照合より前**に置く —— 切り詰められた木で指紋を照合すると、実在する本命が候補に無いまま
  同じ型+ラベルの別要素が「ちょうど1件」になり、修正提案が `fleetest api apply-heal` で利用者の
  .swift へ書き戻される
- **「書けるセレクタ」の規則は `FTCore.SelectorNaming` の1箇所**(一意性(`picksOnlyOne`)・
  祖先スコープ・記法のエスケープ・耐久性の格付け)。**自己修復(指紋照合)の書き戻しもここを通す**。
  (→ maintainer-notes §8)。書けるセレクタが無いときは**操作は続けて修復だけ成立させない**(`StepNote.healUnwritable`)——
  掴んだ要素は手元にあるので叩くのは正しく、書き戻せないという理由で緑の run を赤にしない
- **ロケータの指紋(`FTCore.LocatorFingerprint`)の規律4つ**(詳細は docs/design.md §10
  「ロケータの指紋」): **①効くのは失敗経路だけ**(プライマリ・フォールバックが
  どちらも外れたとき。今緑のステップの挙動は変えられないので、リスクがこの1箇所に閉じる)/
  **②ちょうど1件一致のときだけ採用**(スコアも距離も作らない。複数件を「もっとも近い」で
  選ぶと別要素へ静かに解決し誤った緑を作る)/ **③記録するのはプライマリ/フォールバックで
  解決した回だけ**(指紋で解決した回を記録すると誤った解決が固定化され再生産される)/
  **④修復結果を永続化しない**(指紋は毎回再導出できるので得られるのは速度だけ。一方で
  誤りが永続化して注記が消える)。
  **控えるのは `type` + `label` だけ** —— `id` はドリフトで変わる当のもの、`value` は毎回変わる。
  **型だけの指紋(label も placeholder も無い)は記録も照合もしない**(`isIdentifying`)。
  **失効はシナリオ単位の置き換え**(時間の定数を使わない): 通った run で、その `scenarioID` の
  鍵のうち触れなかったものを刈る。**「触れた」= lookup または record**(record だけだと指紋で
  直った行の鍵が刈られ、次の run で赤に戻る)・**触れた0件の run では刈らない**・
  **接頭辞で自分のシナリオ・自分の OS のぶんだけ**(部分実行で他を巻き込まない・
  鍵に OS が入る = 型名が OS で違うので、混ぜると交互に上書きし合って直らない)。
  **`heal=false` は指紋照合(= 自己修復)を止める**(門は `StepExecutor.execute` の入口1箇所)。
  **FM のトグル(`fmTextOcclusionCheck` / `screenLooksLike`)では止めない**(FM を使わないので。ユーザー決定 2026-09-15)。
  **緑の run では1度も実行されない**ので、自己修復を触ったらデバイスの陽性対照
  `Scripts/heal-verify.sh`(v1 で採取 → v2 で2周 → `heal=false` で赤。1台に固定)を回す
- **セレクタ文法(`FTSelector`)・コマンド索引(`CommandIndex`)・コード生成(`ScenarioCodeGen`)は
  FTCore に居る**(写像先の `FlowLocator` が FTCore の型で、DSL ランタイムには依存しない)。
  利用者からの見え方は `Descriptors.swift` の `@_exported import FTCore` が保っている。
  **ただし FTCore の名指し(`TapTargetGeometry.describe` 等)は「どれの話か」を短く言うためのもので、
  セレクタとして貼れる保証はしない** —— 貼れる形が要るなら `SelectorNaming` を通す

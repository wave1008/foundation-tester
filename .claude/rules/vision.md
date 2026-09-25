---
paths:
  - "InAppBridge/Sources/InAppSettle.swift"
  - "Sources/FTCore/CheckState*.swift"
  - "Sources/FTCore/CheckState.swift"
  - "Sources/FTCore/FindImage*.swift"
  - "Sources/FTCore/FindImage.swift"
  - "Sources/FTCore/Flow.swift"
  - "Sources/FTCore/TemplatePrint*.swift"
  - "Sources/FTCore/TemplatePrintStore.swift"
  - "Sources/FTCore/VisionClassifier*.swift"
  - "Sources/FTCore/VisionClassifier.swift"
  - "Sources/FTDSL/CommandsVerify.swift"
  - "Tests/FTCoreTests/CheckStateClassifierTests.swift"
  - "Tests/FTCoreTests/FindImageTests.swift"
  - "Tests/FTCoreTests/TemplatePrintStoreTests.swift"
  - "Tests/FTDSLTests/AuthoringGuardTests.swift"
  - "Tests/FTDSLTests/CheckStatePreferDSLTests.swift"
  - "Tests/FTDSLTests/ExistImageDSLTests.swift"
  - "Tests/FTDSLTests/FTElementChainTests.swift"
  - "docs/user-docs/testclass/custom_commands.md"
  - "docs/user-docs/testclass/custom_commands_ja.md"
---

# 画像(findImage / checkIsON / 画像分類) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **チェック状態は `FTCore.CheckStateReading`(a11y の4値)と `FTCore.CheckStateClassifier`(見本画像の
  画像分類。Shirates Vision の移植)の2つだけが読む**。画像分類の学習・推論は `FTCore.VisionClassifier` の
  1箇所で、`imageIs`(DefaultClassifier)と共有する。value は型で絞って読む(バッジの "1" を読まない)。
  分類器は `vision/classifiers/CheckStateClassifier/[ON]`・`[OFF]` に見本があるときだけ使い、優先は
  実行プロファイルの `preferCheckStateClassifier`(既定 true)と、それを1コマンドだけ上書きする DSL の
  `checkIsON(prefer:)` / `checkIsOFF(prefer:)`(`CheckStateSource`。決めるのは `executeAssertChecked` の1箇所 =
  ステップ指定 > プロファイル)。**DSL の写像は `CheckStatePreferDSLTests` が通しで縛る** —— FTCore の単体は
  FlowStep を直接作り、E2E の 21 は合否しか見ないので、写像の反転・渡し忘れはどちらも緑のまま通る。
  **見本は推論と同じ a11y の枠で切る**(docs/design.md の checkIsON の節)。
  **分類器の答えは推論のたびに対照(ラベルの違う見本2枚)で確かめ、外れたら使わない**(`VisionClassifier.Model.classify`。
  壊れた Vision / Core ML はエラーを返さず全部に同じラベルを確信度 1.00 で答える = checkIsOFF の誤った緑。
  findImage の縮退の門は特徴量の経路だけで Core ML の経路には効かない)。
  **見本は 5 SUT 全部に ON / OFF の両方を置く**(片側だけだと分類器が片方の状態しか知らず、findImage も
  その状態の部品を探せない)。見本を置いた SUT では引数なしの `checkIsON()` が分類器の判定に切り替わるので、
  a11y の読みを E2E で守るのは各 SUT の `21_チェック状態の判定元.swift` の `prefer: .accessibility`
- **画像で要素を探す判定は `FTCore.FindImage` の1箇所**(findImage / findImages / existImage。Shirates Vision の移植)。
  **existImage は探索を2つ目に持たない** —— `executeFindImage` を同じ action 経路で通り、見つからなかったときだけ
  失敗にする(証跡のスクリーンショットを添える)。action として走るので、アサーションの計数は `FlowStep.isVerification` が
  拾う(`assert != nil` だけで数えると existImage しか無い expectation を「検証0本」と誤る。`AuthoringGuardTests`)。
  DSL の写像(timeout 省略 = defaultTimeout・`scroll:` の向きと `.noScroll`・失敗で中断)は `ExistImageDSLTests`。
  候補は a11y の枠(見えている部分)・アスペクト比の許容幅に入るものだけ・同じ枠は1つに畳む(**id を持つ
  外側を残す。ラベルで選ばない** = XCUITest の木は飾りの Image を SF Symbol 名の id とラベル付きで同じ枠に
  載せる)。守る規律4つ: **①分類器のラベル一致だけで採らない**(分類器は見本のどれかのラベルを必ず答える。
  Shirates の `classifyFull` と同じく確信度か見本との距離で確かめる = `classificationConfirmed`)/
  **②Vision の縮退を黙って通さない**(`isDegenerate`。異なる画像に同一の特徴量が返ると全候補が距離 0 になり、
  最初の候補を「発見」して別の要素を叩く。Vision の失敗としては記録されない。**半端な異常も止める** = 見本を取り直し、
  控えと一致しなければ断る(`isConsistent`。健全なら 4 機 1,200 回とも距離 0)。取り直すのは**走査の最初の見本(= 今の機械の状態)と、
  プロセスで初めて計算した見本(= その控えの正しさ)だけ**・永続控えから読んだ見本は門を通ったもの = 確かめ済み・
  白紙も走査で1回(機械の異常は見本を選ばない))/ **③見つからないことは失敗に
  しない**(select と同じ。失敗は設定の誤りと Vision が答えを出せない状態だけ。**existImage だけが見つからないことを失敗にする**)/
  **④findImage の `waitSeconds` の既定は 0**(`FindImage.defaultWaitSeconds`。待つのは existImage の側 = 既定は実行プロファイルの defaultTimeout)。**文字だけが違う同じ形の部品は距離
  0.08〜0.15 に並ぶ**ので、既定の閾値のまま行を探す書き方を E2E に置かない → maintainer-notes §37。
  **findImages もラベルの見本を全部使う**(Shirates は1枚 = shirates-parity.md の差分)。特徴量は計算の回数だけが
  費用(大きさ・並列で変わらない)なので、候補の特徴量は走査の中で使い回し(`FindImage.CandidatePrints`)、
  見本の特徴量は `TemplatePrintStore`(`<project>/.fleetest/vision/template-prints.json`)に永続化する ——
  **中身の sha256 と OS の版で差分更新・書くのは門を通った特徴量だけ・門で落ちたら消す**(docs/performance-tuning.md §3.30)。
  **掴めなかったときの「飾りの名前」(`<image "…": not found>`)は利用者が書いたセレクタではないので
  構文検証に掛けない**(`FTElement.placeholderSelector` の `structured: true`)—— 掛けると連鎖した
  アサーションが `invalid selector syntax` で落ち、**書いた本人のセレクタを誤って名指し**する。
  dry-run は画像を探せないので必ずこの形になり、**画像で探す手を含むプロジェクトは dry-run が丸ごと赤**
  になっていた(実地 2026-09-23 → maintainer-notes §46.6)
- **in-app のスクリーンショットは、自前描画(`isSelfRendered`)で木が絵より先に進んでいる間は撮らない**
  (`InAppRenderCatchUp`・v117)。操作を起こす2経路(`tapByRef` / `performSettlingIfMoved`)が直前に画素と木の
  指紋を控え、`/screenshot` は**木が変わったのに画素が控えのままの間だけ**待つ。**遷移の完了は待たない**
  (ユーザー決定。ループするアニメーションで毎回上限まで待つ形を作らない)。**木の指紋は枠だけで取らない**
  (スイッチのオン/オフは枠を変えない = 型・id・ラベル・value・checked・enabled も畳む)。**門は層の型でなく
  フレームワークの自己申告**(Compose の `CMPMetalLayer` は `CAMetalLayer` の子孫ではない)→ maintainer-notes §37

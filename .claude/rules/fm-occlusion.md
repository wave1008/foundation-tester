---
paths:
  - ""TestProjects/E2E-Android/scenarios/15_OCR\343\201\247\350\252\255\343\202\201\343\202\213\350\226\204\343\201\204\343\203\206\343\202\255\343\202\271\343\203\210.swift""
  - ""TestProjects/E2E-Flutter/scenarios/15_OCR\343\201\247\350\252\255\343\202\201\343\202\213\350\226\204\343\201\204\343\203\206\343\202\255\343\202\271\343\203\210.swift""
  - ""TestProjects/E2E-RN/scenarios/15_OCR\343\201\247\350\252\255\343\202\201\343\202\213\350\226\204\343\201\204\343\203\206\343\202\255\343\202\271\343\203\210.swift""
  - ""TestProjects/E2E-iOS/scenarios/19_OCR\343\201\247\350\252\255\343\202\201\343\202\213\350\226\204\343\201\204\343\203\206\343\202\255\343\202\271\343\203\210.swift""
  - "Scripts/fm-flap-monitor.swift"
  - "Sources/FTCore/*Occlusion*.swift"
  - "Sources/FTCore/DeadlineExclusion.swift"
  - "Sources/FTCore/FM*.swift"
  - "Sources/FTCore/FMGate.swift"
  - "Sources/FTCore/FMHealth.swift"
  - "Sources/FTCore/FMLiveness.swift"
  - "Sources/FTCore/FMUsageLedger.swift"
  - "Sources/FTCore/OcclusionCrop.swift"
  - "Sources/FTCore/OverlayWindowOcclusion.swift"
  - "Sources/FTCore/RegionText*.swift"
  - "Sources/FTCore/RegionText.swift"
  - "Sources/FTCore/ScenarioHost.swift"
  - "Sources/FTCore/StepExecutor+Assert.swift"
  - "Sources/FTCore/TapTargetGeometry.swift"
  - "Sources/FTCore/TranscriptMatch.swift"
  - "Sources/FTCore/VisibilityVerdictMemo.swift"
  - "Sources/FTFoundationModels/**"
  - "Sources/FTFoundationModels/FMLivenessProbe.swift"
  - "Sources/fleetest/ProfileRunner.swift"
  - "Tests/**/*Occlusion*.swift"
  - "Tests/**/FM*.swift"
  - "Tests/FTCoreTests/DeadlineExclusionTests.swift"
  - "Tests/FTCoreTests/FMBreakerTests.swift"
  - "Tests/FTCoreTests/FMHealthDescribeTests.swift"
  - "Tests/FTCoreTests/FMHealthTests.swift"
  - "Tests/FTCoreTests/FMLivenessTests.swift"
  - "Tests/FTCoreTests/FMUsageLedgerTests.swift"
  - "Tests/FTCoreTests/OCRShortcutSkipNoteTests.swift"
  - "Tests/FTCoreTests/OCRShortcutWiringTests.swift"
  - "Tests/FTCoreTests/OCRToggleWiringTests.swift"
  - "Tests/FTCoreTests/OCRWarmupWaitGateTests.swift"
  - "Tests/FTCoreTests/OCRWarmupWiringTests.swift"
  - "Tests/FTCoreTests/OCRWitnessBandExploration.swift"
  - "Tests/FTCoreTests/OcclusionCropRectTests.swift"
  - "Tests/FTCoreTests/OverlayWindowOcclusionTests.swift"
  - "Tests/FTCoreTests/RegionTextCorpusTests.swift"
  - "Tests/FTCoreTests/RegionTextTests.swift"
  - "Tests/FTCoreTests/ScenarioHostChildEnvironmentTests.swift"
  - "Tests/FTCoreTests/ScenarioHostDeadlineExclusionTests.swift"
  - "Tests/FTCoreTests/ScenarioHostDebugTests.swift"
  - "Tests/FTCoreTests/ScenarioHostDryRunDetailTests.swift"
  - "Tests/FTCoreTests/ScenarioHostInstallArgumentsTests.swift"
  - "Tests/FTCoreTests/ScenarioHostPackageRootTests.swift"
  - "Tests/FTCoreTests/ScenarioHostRegisterChildProcessTests.swift"
  - "Tests/FTCoreTests/ScenarioHostRunnerUnavailableTests.swift"
  - "Tests/FTCoreTests/ScenarioHostSkipBuildStaleTests.swift"
  - "Tests/FTCoreTests/ScenarioHostWatchdogDurationTests.swift"
  - "Tests/FTCoreTests/ScenarioHostWatchdogExitedChildTests.swift"
  - "Tests/FTCoreTests/TaskBudgetTests.swift"
  - "Tests/FTCoreTests/TranscriptMatchTests.swift"
  - "Tests/FTFoundationModelsTests/FMLivenessProbeInUseTests.swift"
  - "Tests/FTFoundationModelsTests/FMLivenessProbeThresholdTests.swift"
  - "Tests/FTFoundationModelsTests/OcclusionTranscriptTests.swift"
  - "Tests/FleetestMCPTests/KeyboardOcclusionWiringTests.swift"
  - "Tests/FleetestMCPTests/OverlayWindowOcclusionWiringTests.swift"
  - "Tests/FleetestTests/ProfileRunnerFMSettingsTests.swift"
---

# FM・テキストの視覚検証(occlusion-guard / OCR) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **FM の「死活」は回数とは別の軸**(`FTCore.FMLiveness` が唯一の定義元。
  `~/.fleetest/fm-liveness.json`)。回数は「使われたか」しか言えないので、**誰も呼んでいない間は
  死んでいても 0 件と同じ絵**になる。守る規律5つ: **①生 / 死 / 不明の3値**(記録が無い・
  `freshSeconds`(120秒)より古いは不明。死と混ぜない)/ **②経路は text と vision で別に持つ**
  (**独立に死ぬ・戻る**実測。畳むと text だけ生きた機械で occlusion-guard の全滅を見落とす)/
  **③availability を書き手にしない**(`.available` のまま全滅する。`unavailable` の向きだけは
  信じてよい)/ **④単発の失敗で死と言わない**(連続 `FMBreaker.threshold` 回。閾値は増やさず
  ブレーカのものを共有する。**ただし数えるのは経路ごと** —— ブレーカのカウンタは経路を区別せず、
  text の成功が毎回戻すので vision の死を記録できない)/ **⑤プローブは `FMHealth` /
  `FMUsageLedger` に書かない**(書くと誰も run を回していないのに FM のレートが動く =
  測る対象を自分で消費して見せる)。
  **`api host-metrics --fm-probe` だけが「host-metrics は FM を叩かない」の例外**
  (拡張のモニターだけが渡す。既定 OFF)—— 撃つのは**台帳が古く、かつ誰も FM を使っていない**
  ときだけ(`FMLivenessProbe.refresh` の門①②③。FMLock は 1 秒で諦める = 実仕事を待たせない)。
  プローブ間隔 60 秒の根拠は `Scripts/fm-flap-monitor.swift` と同じ刻み。
  読み手は4つ: モニターの FM 行(NDJSON の `fmTextState`/`fmVisionState`/`fmDeadReason`/
  `fmCheckedAt`)/ run 開始前の警告(`ProfileRunner.warnIfFMDegraded`。**run の中で FM を使うのは
  vision 経路(occlusion-guard・screenLooksLike)だけ**なので、言うのは vision の死を、その機能が有効な
  run でだけ。**text 経路はシナリオの下書き・命名だけが使う** = text の死で run が失う機能は無い)/
  run.json の `fmDead`・`fmDeadReason` / `ft_status`・`ft_doctor`・`fleetest doctor --fm-only`
  (**doctor は text と vision を両方 実呼び出しで確かめ、どちらが死んでも exit 1**)
- **occlusion-guard の FM 段には期待文字列を渡さない**(2026-09-15)。FM に訊くのは「何が描かれているか」
  (転写 1 欄・prompt は定数)だけで、可否は `FTCore.TranscriptMatch` が期待文字列と突き合わせて決める。
  期待文字列を prompt に入れて「見えるか」を訊くと、空白・別の文字の crop でも期待文字列を写して
  visible=true と答える(おうむ返し。空白 20〜23% / 別の文字 33〜56% の見逃し)。欄順を変えても直らない。
  `OcclusionTranscriptTests` がソース走査で守る → maintainer-notes §19
- **occlusion-guard の OCR 段(`FTCore.RegionText`)は「素通りの根拠」にしかしない** —— 期待テキストが
  **丸ごと**読めた回だけ FM を省く(既定 on。**利用者の口は実行プロファイルの
  `ocrTextVisualCheck`**(拡張のプロファイルタブ
  「Advanced Features(Experimental)」)。保守者の口は `FT_OCCLUSION_OCR=0` の
  殺しスイッチと `measure` のコーパス採取で、**プロファイルの false が環境変数に勝つ**)。**読めなかったことを反転の根拠にしない** —— 日本語モデルを載せた版では実測で
  29% が可視なテキストの1文字誤読(`swipe=down`→`swipe=aown`)で、反転に使うと誤った赤になる。
  反転の判定は必ず FM。**一致は語境界つきの完全含有**(素の部分一致だと `exist("OK")` が
  覆いの「Cookieの設定」に当たって素通りする)。
  **読ませる言語は期待文字列から決める**(`languages(for:)`。ASCII の期待値に日本語モデルを
  載せると所要が 2.3 倍になる)。**言語補正は日本語の集合でだけ掛ける**(`usesLanguageCorrection(for:)`。
  en ロケールの端末は「単」を中国語フォントの字形で描き、補正なしだと Vision も FM も「单」と読む。
  ASCII は切ったまま = 欠けを推測で埋めさせない)。読めなければ crop を
  拡大して読み直す(`upscaleLadder = [1,2,3]`。×4 で悪化するので上げ続けない。**1行も読めない
  crop は段を上げない** = 覆いを待つ poll 周回で毎周3回払わない)。**Vision の版は固定しない**
  (OS の既定に従う)—— 版・認識レベル・言語補正・言語規則が動いたことの検出は、実 crop の固定
  コーパス `Tests/Fixtures/OcclusionCrops/` が読みと撃つ回数を等号で固定して担う。
  crop 矩形は `FTCore.OcclusionCrop` を FM と共有する(別々に持つと同じ画面で判断が食い違う)
- **木からは原理的に判定できない遮蔽は「ブリッジの申告」+ 専用の型** —— キーボードは
  `KeyboardOcclusion`(`keyboardFrame`)、**それ以外の別ウィンドウは
  `FTCore.OverlayWindowOcclusion`(`overlayWindowFrames`)**。Android の木の根は
  `getRootInActiveWindow()` = **アクティブウィンドウ1枚だけ**なので、手前に居る非フォーカスの
  ポップアップ(ツールチップ・テキスト選択のフローティングツールバー)は `elements` に1要素も
  載らず、覆われた要素を無警告で撃っていた。**申告由来の2つは木由来の警告より先に言う**
  (確度が最も高い)。**この2つの引数に既定値を置かない** —— 新しい呼び出し元の呼び忘れを
  コンパイルで止めるため(`OverlayWindowOcclusionWiringTests` が配線を、変異チェックが
  検知の生死を落とす)。**この検知は「出れば正しい」であって「出なければ覆いが無い」ではない**
- **occlusion-guard の反転は、1 回目のガード評価が締切を跨いだ回だけ 1 度延長して撮り直す**
  (`guard-retaken`。FM 待ちはアプリの応答ではないので待ち予算から引かない。同じ絵は
  `VisibilityVerdictMemo` が同じ verdict を返すので、テストでは撮り直しごとに違う絵を渡す)
- **occlusion-guard の OCR 近道は、暖機が終わっていなければ終わるまで待ってから撃つ**(ユーザー決定
  2026-09-15。**run の開始時には待たない**。経緯は maintainer-notes §18・§20): 認識器(Espresso)の
  コンパイルキャッシュは**プロセス名とバイナリの素性ごと・コンパイルがプロセスの生存中に終わったときだけ
  コミット**。**シナリオを実際に走らせる経路は `ScenarioHost.listForRun`**(run / api run / 機械分担の
  3 箇所。`OCRWarmupWiringTests` が等号で固定)で同じプロセス名の待てる子 `warm-ocr` を背景で起こす。
  一覧だけの経路(dry-run / MCP / codegen)は `list`。**プロセス内の暖機(探り)は DSL ではシナリオ開始時に
  FTRuntime が始める**(executor の既定ガードは off でステップごとに効かせるので、`StepExecutor.init` の
  条件だけに頼ると最初のガードの中で初めて始まり、全シナリオの最初のガードが近道を逃していた)。
  近道の直前で `RegionText.awaitPrewarm(cap:)` を待ち(上限 `prewarmWaitCap` 120 秒 = 正当な暖機の
  実測最大 108 秒 + 1 割。超えたら ANE のハングと見て FM へ・注記 `ocr-warmup-capped`)、
  **待った時間はステップ(FTSync 120 秒)とシナリオ(scenarioTimeout)の締め切りから差し引く**
  (`DeadlineExclusion`。子→親の `deadlineExclusion` イベントはホストが横取りし api の NDJSON には出さない)。
  暖機の待ちはアプリの応答ではないので待ち予算に数えない(9/10 の「初期化をステップの予算で払って
  締め切りに当たる」事故を、待たないことではなく差し引くことで防ぐ)。
  近道を撃つのは **warm(探りが 1 行以上読めた)かつ 詰まった読みが無い**ときだけ(`shouldTakeShortcut`。
  純粋関数・配線は走査で固定)、予算 1.3 秒 = 置き換える相手の実測下限、**諦めても読みは止めない**。
  認識器は ANE を避ける(定常の所要は同じ・装置で読みが変わる分はコーパスに固定)。
  **締め切り・予算のテストは戻り値でなく所要を直接測る**(`TaskBudgetTests`)

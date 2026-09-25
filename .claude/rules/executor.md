---
paths:
  - ""TestProjects/E2E-Android/scenarios/15_OCR\343\201\247\350\252\255\343\202\201\343\202\213\350\226\204\343\201\204\343\203\206\343\202\255\343\202\271\343\203\210.swift""
  - ""TestProjects/E2E-Flutter/scenarios/15_OCR\343\201\247\350\252\255\343\202\201\343\202\213\350\226\204\343\201\204\343\203\206\343\202\255\343\202\271\343\203\210.swift""
  - ""TestProjects/E2E-RN/scenarios/15_OCR\343\201\247\350\252\255\343\202\201\343\202\213\350\226\204\343\201\204\343\203\206\343\202\255\343\202\271\343\203\210.swift""
  - ""TestProjects/E2E-iOS/scenarios/19_OCR\343\201\247\350\252\255\343\202\201\343\202\213\350\226\204\343\201\204\343\203\206\343\202\255\343\202\271\343\203\210.swift""
  - "Sources/FTCore/AppDriver.swift"
  - "Sources/FTCore/RunOrchestrator.swift"
  - "Sources/FTCore/RunProfile.swift"
  - "Sources/FTCore/ScenarioExecutionSettings*.swift"
  - "Sources/FTCore/ScenarioExecutionSettings.swift"
  - "Sources/FTCore/ScenarioHost.swift"
  - "Sources/FTCore/StepExecutor*.swift"
  - "Sources/FTCore/SystemUIGate*.swift"
  - "Sources/FTCore/SystemUIGate.swift"
  - "Sources/FTDSL/FTRuntime.swift"
  - "Tests/FTCoreTests/AppDriverDefaultDispatchTests.swift"
  - "Tests/FTCoreTests/DriverErrorMessageTests.swift"
  - "Tests/FTCoreTests/OCRShortcutSkipNoteTests.swift"
  - "Tests/FTCoreTests/OCRShortcutWiringTests.swift"
  - "Tests/FTCoreTests/OCRToggleWiringTests.swift"
  - "Tests/FTCoreTests/OCRWarmupWaitGateTests.swift"
  - "Tests/FTCoreTests/OCRWarmupWiringTests.swift"
  - "Tests/FTCoreTests/OCRWitnessBandExploration.swift"
  - "Tests/FTCoreTests/ResolvedProfileDeviceLimitTests.swift"
  - "Tests/FTCoreTests/ScenarioExecutionSettingsTests.swift"
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
  - "Tests/FTCoreTests/SystemUIGateAssertOnAlertTests.swift"
  - "Tests/FTCoreTests/SystemUIGateTests.swift"
  - "Tests/FTDSLTests/FTRuntimeFailureKindTests.swift"
  - "Tests/FTDSLTests/FTRuntimeLifecycleTests.swift"
  - "Tests/FleetestTests/ResolvedProfileDeviceScopeTests.swift"
  - "docs/design.md"
---

# StepExecutor(実行時設定・失敗の文言・システムアラート) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **失敗の文言は構成(OS・エンジン・実機か)を知っている必要がある**(`FTCore.DriverErrorContext` を
  `DriverError` の同伴データに必須で持たせる。既定値を置かない = 新しい経路が渡し忘れたらコンパイルで止まる)。
  **detail に渡すのは一次情報だけ**(完成した説明文を渡すと固定文が二重に出る)→ maintainer-notes §27
- **type の読み返しの有無はドライバの能力**(`AppDriver.verifiesTypedText`。xcuitest ランナー/
  Android 注入器 = true・in-app = false で、false のときだけ `StepExecutor` がホスト側で読み返す)
- **実行時設定は継ぎ目で解かない**。`fm`(`FMConfig`)/ `heal` / `occlusionOCR` / `containerInference` / timeouts は
  `FTCore.ScenarioExecutionSettings` 1つに束ね、`runSequential`/`runParallel` → `RunOrchestrator` →
  `ScenarioRunner.runOne` → `ScenarioHost.run` をそのまま通す。**既定値はこの型の init 1箇所だけ**
  —— 層ごとに引数へ解くと、その層の既定が**渡し忘れを合法にする**(コンパイルでも実行でも
  見えない)→ maintainer-notes §17。プロファイル由来の値の写像元は変換 init
  (`ResolvedProfile` / `DeviceIndependentRunSettings` から)**だけ**で、欄を足して写像を忘れると
  `ScenarioExecutionSettingsTests` の `Mirror` 走査が落とす。
  **走査テストは型の効かない継ぎ目にだけ置く**(`OCRToggleWiringTests` に残すのは子プロセス境界の
  3本。型で守れる区間の走査は、リファクタのたびに走査だけが落ちる)。
  **`occlusionOCR` は OCR 全体のスイッチではない** —— プロファイルの `ocrTextVisualCheck`
  (視覚検証の OCR 段だけ)なので、**OCR の用途が増えてもこの Bool を再利用せず欄を足す**。
  **FM / OCR の親スイッチ(`fm` / `ocr`)は置かない**(ユーザー決定 2026-09-15。キーも
  チェックボックスも無い)—— FM を呼ぶかは `FMConfig.enabled = textVisualCheck || screenLooksLike`
  で導く(両方 false なら実行バイナリへ `--no-fm`)。親と子で同じ状態を2か所に持っていた
  → maintainer-notes §23
- **システムアラートの判定は2段**: 登録がある間は `SystemUIGate` が毎ステップ止める / 登録が
  無いときは **launch 直後の最初の触る操作と失敗時だけ1回聞いて** `system-alert-present` の注記と
  題名を残す(止めない・閉じない)。常時監視へ広げない。
  **失敗時の証跡の絵は hybrid なら XCUITest(`XCUIScreen`)で撮る**(`FTRuntime.handleFailure`。in-app の絵は
  アプリの window しか描かず OS のアラートが写らない)。**iOS の「飲まれたタップ」注記はアラートの可能性を
  併記する**(iOS の木はアプリのプロセスだけ = アラートを出したタップも無変化に見える)

---
paths:
  - "TestProjects/E2E-Android/scenarios/15_OCRで読める薄いテキスト.swift"
  - "TestProjects/E2E-CMP/scenarios/19_OCRで読める薄いテキスト.swift"
  - "TestProjects/E2E-Flutter/scenarios/15_OCRで読める薄いテキスト.swift"
  - "TestProjects/E2E-RN/scenarios/15_OCRで読める薄いテキスト.swift"
  - "TestProjects/E2E-iOS/scenarios/19_OCRで読める薄いテキスト.swift"
  - "Sources/FTCore/AppDriver.swift"
  - "Sources/FTCore/LocatorResolver.swift"
  - "Sources/FTCore/RunOrchestrator.swift"
  - "Sources/FTCore/RunProfile.swift"
  - "Sources/FTCore/RunTunables.swift"
  - "Sources/FTCore/ScenarioExecutionSettings*.swift"
  - "Sources/FTCore/ScenarioExecutionSettings.swift"
  - "Sources/FTCore/ScenarioHost.swift"
  - "Sources/FTCore/ScenarioHost+Sandbox.swift"
  - "Sources/FTCore/ScenarioSandbox.swift"
  - "Sources/FTCore/SandboxBroker.swift"
  - "Sources/FTCore/SandboxProxy.swift"
  - "Sources/FTServices/**"
  - "Tests/FTServicesTests/**"
  - "Sources/FTCore/StepExecutor*.swift"
  - "Sources/FTCore/SystemUIGate*.swift"
  - "Sources/FTCore/SystemUIGate.swift"
  - "Sources/FTDSL/FTRuntime.swift"
  - "Tests/FTCoreTests/AppDriverDefaultDispatchTests.swift"
  - "Tests/FTCoreTests/DriverErrorMessageTests.swift"
  - "Tests/FTCoreTests/OCRShortcutSkipNoteTests.swift"
  - "Tests/FTCoreTests/OCRShortcutWiringTests.swift"
  - "Tests/FTCoreTests/OCRToggleWiringTests.swift"
  - "Tests/FTCoreTests/OCRModelCompileWaitGateTests.swift"
  - "Tests/FTCoreTests/OCRModelCompileWiringTests.swift"
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
  - "Tests/FTCoreTests/ScenarioSandboxTests.swift"
  - "Tests/FTCoreTests/ScenarioSandboxPlanTests.swift"
  - "Tests/FTCoreTests/ScenarioSandboxWiringTests.swift"
  - "Tests/FTCoreTests/SandboxBrokerTests.swift"
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
  **`occlusionOCR` は OCR 全体のスイッチではない** —— プロファイルの `ocrTextVisibilityCheck`
  (可視性検証の OCR 段だけ)なので、**OCR の用途が増えてもこの Bool を再利用せず欄を足す**。
  **FM / OCR の親スイッチ(`fm` / `ocr`)は置かない**(ユーザー決定 2026-09-15。キーも
  チェックボックスも無い)—— FM を呼ぶかは `FMConfig.enabled = fmTextVisibilityCheck || screenLooksLike`
  で導く(両方 false なら実行バイナリへ `--no-fm`)。親と子で同じ状態を2か所に持っていた
  → maintainer-notes §23
- **受け手の環境で正解が変わる既定(待ち・締切・操作の所要)は `FTCore.RunTunables` に置く**
  (`ScenarioExecutionSettings.tunables` で運び、子へは `--tunables` の JSON 1つ)。欄名は将来の
  プロファイルのキー名。開放は `RunProfileDocument` に欄を足して変換 init で写すだけ。判定の閾値・
  安全網の上限は入れない。読むのは `StepExecutor` / `FTDriveCore` の `tunables` で、
  `?? FlowStep.defaultXxx` の固定値へ落とさない(`RunTunablesWiringTests`)。**MCP とコード生成は
  プロファイルを持たないので `FlowStep` の定数のまま**
- **システムアラートの判定は2段**: 登録がある間は `SystemUIGate` が毎ステップ止める / 登録が
  無いときは **launch 直後の最初の触る操作と失敗時だけ1回聞いて** `system-alert-present` の注記と
  題名を残す(止めない・閉じない)。常時監視へ広げない。
  **失敗時の証跡の絵は hybrid なら XCUITest(`XCUIScreen`)で撮る**(`FTRuntime.handleFailure`。in-app の絵は
  アプリの window しか描かず OS のアラートが写らない)。**iOS の「飲まれたタップ」注記はアラートの可能性を
  併記する**(iOS の木はアプリのプロセスだけ = アラートを出したタップも無変化に見える)
- **シナリオのサンドボックス(Seatbelt・常に有効)**: 全拒否が土台の Seatbelt でシナリオ実行バイナリを包む
  (`FTCore.ScenarioSandbox`。入口は `ScenarioHost.sandboxedLaunch` = 実行・dry-run・`list`・`compile-ocr` の全部。
  `ScenarioSandboxWiringTests`)。外せるのはマシン側の `sandbox.disabled` だけ。守る規律5つ:
  **①シナリオ実行バイナリを起こす経路を足したら入口を通す**(起こし方に関わらず利用者のコードが動きうる)/
  **②子が書く場所を足したら `writablePaths` にも足す**(親が決める場所は `Scope.extraWritable`)・
  **`simctl` / `devicectl` / `adb` の呼び出しを足したら `SimctlPolicy` / `DevicectlPolicy` / `AdbPolicy` にも足す**
  (子は CoreSimulator / CoreDevice / adb サーバに繋げず、親の `SandboxBroker` が代行する。adb は
  `AdbPolicyBuilderSyncTests` が組み立てとドライバの定数の呼び出しを表に当てる)/
  **③緩める口をプロジェクトと環境変数に置かない**(設定はマシン側の固定パスだけ・`HOME` / `TMPDIR` /
  `XDG_CONFIG_HOME` / `FT_*_DIR` から書ける場所や読ませない場所を広げない)/
  **④開けるものは名指しで足す**(全許可へ戻さない。全許可の枠からは `simctl spawn` と `open -a` で外へ出られた)/
  **⑤拒否は先に起こした `log stream` で拾う**。規則の形・書式の罠・壁の外に残るものは docs/design.md §11.7
- **サービスの宣言(compose.yaml)の解釈・検査・計画は `Sources/FTServices`**(docs/remote-runner.md §17。利用側は fleetest CLI と
  fleetest-mcp だけ = 受け手のシナリオ実行バイナリには Yams ごとリンクしない。`PackageLinkageTests` が Package.swift の推移的な
  リンク依存を走査で固定)。**FTCore から FTServices を参照しない**(broker へ方針を差し込む口だけ FTCore に置く)。守る規律4つ:
  **①経路は1本** —— 読む(`ComposeReader`)→ 展開(`ComposeTreeExpander` = 正規化の前・秘密は `environment` の値だけ)→
  正規化(`ComposeNormalizer`)→ 検査(`ComposePolicy`)→ 計画(`ServicePlanner`)。正規化後の型に展開をかける経路を足さない /
  **②全部純粋関数** —— ファイルの実体・symlink・空きポート・乱数・時刻は呼び手が入力で渡す(`PathFact`・`PlanOptions`)/
  **③拒否は `ComposeRefusal` の case で表し全部集めて返す**(文言は英語の `message`。拒否を文字列の一致で判定しない)/
  **④許可は全階層の許可表**(知らないキー・型は断る。`version` と `x-*` だけ無視して1行言う)。
  dockerfile の実体パスの鍵は `ComposePolicy.dockerfileKey` の1箇所(検査と計画が別々に組むと片方だけ引けない)
- **スクリプト(run-setup.sh / run-teardown.sh)の枠は用途 `.script`**(`ScenarioSandbox.Scope.purpose`。入口は `FTCore.ScriptSandbox.launch`・
  呼ぶのは `RunHookRunner.runScript` の1箇所 = `RunHookRunnerSandboxWiringTests`)。**用途で変わる集合は `ScenarioSandbox` の中の分岐に
  置き、呼び手の値の工夫で絞らない**(`writablePaths` / `profile`)。スクリプトが書ける場所を足すなら `hooks.writablePaths` の検め
  (`HooksSettings.validate` の protected = `ScriptSandbox.protectedLocations`)に重なる場所が無いかを先に見る。
  **中継 `fleetest-services` に動詞を足す → `ServicePolicy`(FTServices・純粋)と `ServicePolicyTests` に足す**(ランタイムのオプションは
  利用者に書かせない・サービスの集合は宣言だけが決める)。gateway のワイヤ(`ServiceGatewayWire`)を変えたら `fleetest-services` も同じ
  コミットで(同じ FTCore を使うので版は持たない = 必ず一緒にビルドされる)
- **`fleetest services up` は常駐の所有者(`api services-owner`)を起こし、控えは `kind = owner`**(run の控えと同じ置き場・同じ生存判定 =
  `ServicesOwnerLaunch` / `ApiServicesOwnerCommand`)。run は `ServicesSession.takeOverOwners` で所有者へ SIGTERM を送り**排他の外で**
  終了を待ってから作る(所有者も同じ排他で片付ける = 握ったまま待つと待ち合う)。待ちの上限は控えの `stopGraceSeconds` から
  (`ServicesTeardown.teardownBudgetSeconds`。新しい数字を置かない)。**控え(`ServicesLease`)の欄を足したら `currentSchemaVersion` を +1**
  (読み替えは置かない)。Android 実機の `adb reverse` は親が張り、控えの `adbReverse` で外す(`ServicesAdbReverse`。資源ではないので
  解除の失敗で控えを残さない)。**張る前に `--list` で宛先を見る** —— 同じ宛先なら触らず、別の宛先なら起動の失敗(届く・届かないを
  推定で言わない)。`services reset --force` は**生きている持ち主の控えを消さない**(所有者には合図して排他の外で待ち、待ち切れなければ
  何も消さない・run は止めない・読めない控えもその pid が生きていれば消さない。判定は `Reset.forceDecision` の純粋関数)。
  **排他は押し切らない**(`ServicesLock` に強制解除の経路を足さない。取れなければ消さずに止める)。**排他の実体は固定ファイルの flock**
  (mkdir + 「死んだ持ち主を照合して削除」に戻さない = 照合と削除の間の窓で他者のロックを消す)。親だけが書く場所(`services.lock/`・
  `services/`・`mcp-ask-offered.json` 等)を足したら `ScenarioSandbox.writeDeniedPaths` にも足す(flock は inode に付く = 消されると排他が崩れる)。`services up` の引数(`--physical` / `--serial`)と run の実機のレーンは `ServicesUpOptions` の1箇所で
  `ServicesSession.up` へ入る(呼び手ごとに別の経路を作らない)

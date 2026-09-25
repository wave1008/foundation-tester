---
paths:
  - "Sources/FTBridgeClient/BridgeDiscovery.swift"
  - "Sources/FTBridgeClient/IOSPhysicalRunningApps.swift"
  - "Sources/fleetest/LiveBridge*.swift"
  - "Sources/fleetest-devicepoll/main.swift"
  - "Sources/fleetest/ApiLive*.swift"
  - "Sources/fleetest/BridgeCommand.swift"
  - "Sources/fleetest/LiveBridgeAutoStarter.swift"
  - "Sources/fleetest/LiveSessionFollower.swift"
  - "Tests/FTAndroidTests/BridgeCodePathVerdictTests.swift"
  - "Tests/FTAndroidTests/BridgeRouterGuardsJavaSyncTests.swift"
  - "Tests/FTBridgeClientTests/BridgeClientPhysicalTokenTests.swift"
  - "Tests/FTBridgeClientTests/BridgeClientTimeoutTests.swift"
  - "Tests/FTBridgeClientTests/BridgeClientTokenReloadTests.swift"
  - "Tests/FTBridgeClientTests/BridgeClientURLTests.swift"
  - "Tests/FTBridgeClientTests/BridgeDiscoveryTests.swift"
  - "Tests/FTBridgeClientTests/BridgeEndpointCorruptFileTests.swift"
  - "Tests/FTBridgeClientTests/BridgeEndpointTokenTests.swift"
  - "Tests/FTBridgeClientTests/BridgeHostPlumbingTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherCaptureSettingsTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherNotRunningMessageTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherPidReuseTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherRebuildTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherStopTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherTokenInjectionTests.swift"
  - "Tests/FTBridgeClientTests/BridgeMainThreadBudgetTests.swift"
  - "Tests/FTBridgeClientTests/BridgeProvisionerFailureLogTests.swift"
  - "Tests/FTBridgeClientTests/BridgeReadyLedgerTests.swift"
  - "Tests/FTBridgeClientTests/BridgeResultBundleSweepTests.swift"
  - "Tests/FTBridgeClientTests/BridgeStartupWaitTests.swift"
  - "Tests/FTBridgeClientTests/BridgeToolchainLedgerTests.swift"
  - "Tests/FTBridgeClientTests/BridgeToolchainLedgerWiringTests.swift"
  - "Tests/FTBridgeClientTests/IOSPhysicalRunningAppsTests.swift"
  - "Tests/FTCoreTests/BridgeContractTests.swift"
  - "Tests/FTCoreTests/BridgeCoordinateTapTargetTests.swift"
  - "Tests/FTCoreTests/BridgeDocRouteSyncTests.swift"
  - "Tests/FTCoreTests/BridgeIdentityCheckTests.swift"
  - "Tests/FTCoreTests/BridgeLivenessTests.swift"
  - "Tests/FTCoreTests/BridgeRouterStatusContractTests.swift"
  - "Tests/FTCoreTests/BridgeSnapshotThinningTests.swift"
  - "Tests/FTCoreTests/BridgeTTLTests.swift"
  - "Tests/FTCoreTests/BridgeTokenTests.swift"
  - "Tests/FTCoreTests/BridgeTokenWiringTests.swift"
  - "Tests/FleetestMCPTests/BridgeBusyHintEngineResolutionTests.swift"
  - "Tests/FleetestMCPTests/BridgeRecoveryDecisionTests.swift"
  - "Tests/FleetestMCPTests/BridgeRecoveryWiringTests.swift"
  - "Tests/FleetestMCPTests/BridgeWedgedTransportTests.swift"
  - "Tests/FleetestTests/BridgeDownLeaseGateTests.swift"
  - "Tests/FleetestTests/BridgeStatusReportTests.swift"
  - "Tests/FleetestTests/BridgeTargetResolutionTests.swift"
  - "Tests/FleetestTests/BridgeUpDeviceResolutionTests.swift"
  - "Tests/FleetestTests/BridgeUpNoDuplicateBuildTests.swift"
  - "Tests/FleetestTests/BridgeUpPortMismatchMessageTests.swift"
  - "Tests/FleetestTests/BridgeUpPortRangeValidationTests.swift"
  - "Tests/FleetestTests/LiveBridgeAutoStarterPortHolderTests.swift"
  - "vscode-fleetest/src/*Live*.ts"
  - "vscode-fleetest/src/*live*.ts"
  - "vscode-fleetest/src/webview/**/live*"
---

# ライブ操作 の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **ライブ操作は他の機械の台も開ける**(ユーザー決定 2026-09-24「その機械で動かす」): serve を
  `fleetest remote exec <machine> -- api live serve` で**向こうに**起こす(同じ実機が Wi-Fi 越しにこの Mac から
  見えても、USB で握っている機械のランナーと2本にしない)。右クリックの `openLiveForDevice` が machine・udid を
  運び、一覧は取り直しても足し戻す(`remoteOptions`)。配信は張らず serve の frame で取る。
  **stdin で命令を受ける子を `remote exec` で起こすとき、到達確認の ssh は `-n`**(読むと最初の命令を捨てる)。
  **ブリッジ未起動(booted)の台へ切り替えたら観測を1回撃つ**(`requestOpenObservation`。自動のフレーム取得は
  自動起動を撃たない)。**前面追従の候補はシミュレータ = `launchctl list` / 実機 = devicectl の
  processes × apps(`IOSPhysicalRunningApps`)** —— 片方だけ変えない。**本人確認へ渡す `/status` は
  `BridgeDiscovery.statusForIdentityCheck` で udid を補う**(実機のランナーは名乗らない = 補わないと
  既定ポートの別の実機を「自分」と読む)→ maintainer-notes §47。
  **1コマンドの中で撃つ外部呼び出しの timeout は command watchdog(30 秒)より十分短く**し、失敗は控えて
  毎コマンド撃ち直さない(`DevicectlBackoff`)—— watchdog が serve を殺すたびに自動起動が走る。
  **実機に2本目のランナーを立てない**(ライブ操作の自動起動 `LiveBridgeAutoStarter.launchBridge` が、同じ実機を
  宛先に持つ別ポートの xcodebuild を見たら断る。起動途中のランナーは走査に載らない。bridge up / 供給は起動途中の台を
  待って引き取るので門は置かない)→ maintainer-notes §49.4

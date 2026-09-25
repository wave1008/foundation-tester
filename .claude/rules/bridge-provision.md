---
paths:
  - "AndroidRunner/**"
  - "AndroidRunner/build.sh"
  - "AndroidRunner/prebuilt/ftbridge.apk"
  - "InAppBridge/**"
  - "Runner/**"
  - "Runner/project.yml"
  - "Sources/FTAndroid/ProfileWorkerFactory.swift"
  - "Sources/FTBridgeClient/**"
  - "Sources/FTBridgeClient/BridgeDiscovery.swift"
  - "Sources/FTBridgeClient/BridgeLauncher.swift"
  - "Sources/FTBridgeClient/BridgeProvisioner.swift"
  - "Sources/FTBridgeClient/InAppLauncher.swift"
  - "Sources/FTBridgeClient/PortHolder.swift"
  - "Sources/FTBridgeClient/RunnerDestination.swift"
  - "Sources/FTBridgeClient/StaleBridgeStop.swift"
  - "Sources/FTCore/BlankWorkerTriage.swift"
  - "Sources/FTCore/BridgeDTO.swift"
  - "Sources/FTCore/BridgeIdentityCheck.swift"
  - "Sources/FTCore/BridgeSourceSet.swift"
  - "Sources/FTCore/HostRecordingProbe.swift"
  - "Sources/FTCore/RunOrchestrator.swift"
  - "Sources/FTCore/WorkerCircuitBreaker.swift"
  - "Sources/FTCore/WorkspaceAppStaging.swift"
  - "Sources/fleetest/LiveBridgeAutoStarter.swift"
  - "Tests/FTAndroidTests/AndroidBridgeVersionSyncTests.swift"
  - "Tests/FTAndroidTests/InstallIfNeededTryOptionalSourceScanTests.swift"
  - "Tests/FTAndroidTests/ProfileWorkerFactoryBlankRebootTests.swift"
  - "Tests/FTBridgeClientTests/**"
  - "Tests/FTBridgeClientTests/BridgeDiscoveryTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherCaptureSettingsTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherNotRunningMessageTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherPidReuseTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherRebuildTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherStopTests.swift"
  - "Tests/FTBridgeClientTests/BridgeLauncherTokenInjectionTests.swift"
  - "Tests/FTBridgeClientTests/BridgeProvisionerFailureLogTests.swift"
  - "Tests/FTBridgeClientTests/InAppLauncherBuildTests.swift"
  - "Tests/FTBridgeClientTests/PortHolderClassifyTests.swift"
  - "Tests/FTBridgeClientTests/PortHolderListenerIdentityTests.swift"
  - "Tests/FTBridgeClientTests/RunnerDestinationTests.swift"
  - "Tests/FTBridgeClientTests/StaleBridgeStopTests.swift"
  - "Tests/FTCoreTests/BlankWorkerTriageTests.swift"
  - "Tests/FTCoreTests/BridgeContractTests.swift"
  - "Tests/FTCoreTests/BridgeIdentityCheckTests.swift"
  - "Tests/FTCoreTests/BridgeRouterStatusContractTests.swift"
  - "Tests/FTCoreTests/HostRecordingProbeTests.swift"
  - "Tests/FTCoreTests/WorkerCircuitBreakerTests.swift"
  - "Tests/FTCoreTests/WorkspaceAppStagingTests.swift"
  - "Tests/FleetestTests/LiveBridgeAutoStarterPortHolderTests.swift"
---

# ブリッジ(版・ポート・供給) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **ブリッジの挙動・エンドポイントを変えたら版を上げる** → maintainer-notes §4.4。
  iOS = `Sources/FTCore/BridgeDTO.swift` の `bridgeProtocolVersion`(in-app dylib と XCUITest
  ランナーの共通定数)/ Android = `AndroidRunner/build.sh` の `VERSION_CODE` と
  `AndroidBridge.swift` の `expectedBridgeVersionCode` を**同時に**
  (`AndroidBridgeVersionSyncTests` が定数間の不一致と、**コミット済み `prebuilt/ftbridge.apk` が
  定数と別版のまま = APK 作り直し忘れ**を検出)。**実装ソースを変えたら `BridgeContractTests` が
  落ちる**ので、そこで版を上げてから期待値を貼り替える(貼り付け用のリテラルは失敗メッセージが
  出す)。検出は2段: ルート表(エンドポイントの増減)+ ソース指紋(**ルートが同じで
  ハンドラだけ変えた場合も落ちる**)。**版を上げること自体は強制できない**ので最後は人間の規律。
  **試行的な変更ほどブリッジに入れない**。
  **ブリッジの入力ファイル一覧は `Sources/FTCore/BridgeSourceSet.swift` が唯一の定義元**
  (`InAppLauncher` の dylib 再ビルド判定と、XCUITest ランナーの作り直し判定 `BridgeLauncher.newestRunnerSourceTimestamp`
  も同じ一覧を使う。片方だけ変えない。ランナーが取り込む共有 FTCore ファイルは `Runner/project.yml` と
  この一覧の等号を `BridgeLauncherRebuildTests` が固定する)
- **「応答しない」を busy と死で分けるのは所要時間**(`BridgeDiscovery.probeStatus` の4値)。
  健全 = HTTP 応答が返る(**ステータスコードで判定しない** —— 実機はトークン不一致の 401 を返す)/
  **固まった転送**(ブリッジが消えて iproxy だけ残る)= connect は通るのに応答無しで即切れる /
  本当に busy = 上限まで保持 / 不在 = connect が即 拒否。**固まりには `bridge up` を勧める**
  (「2本目を起動させる」懸念は生きたブリッジがある前提なので成立しない)。
  **in-app/hybrid には固まりの文言を出さない**(あちらは前面から外れただけのことが多い)。
  **`.pid` の生死では捕まらない** —— xcodebuild は生きたまま待ち続ける → maintainer-notes §44.1。
  **所要時間だけで「消えた」と言わない** —— 塞がったシミュレータのランナーも backlog が溢れて即切れる
  (シミュレータに転送役は居ない)。ループバックで待受の実体が iproxy でなければ busy(`resolveTransportFailure`)
  → maintainer-notes §49.2
- **エラーの status はホストの分岐契約**(表は docs/design.md §4.3)。とくに
  **XCUITest ランナーの 409 は `requireApp()` の1箇所だけ** —— ホストはこの経路の 409 を無条件に
  「セッション消失」と読んで activate を撃つ。「セッションはあるが今は無理」は **422** を使う
  (`BridgeRouterStatusContractTests` が 409/503/501 の本数を数えて守る)。in-app ブリッジは逆に
  409 を一時的競合へ広く使ってよい(あちらは包まれない)
- **同じ Mac で実機とシミュレータの run が同居する前提でポートを扱う**(2026-09-15 の負荷テスト。
  経緯は maintainer-notes §20): ①採番は `.pid` に加えて**生きた `iproxy-<port>.pid`** を除外する
  ②`PortHolder.stopIfOwnedBridge` が iproxy を止めるのは台帳 `.device` の UDID が供給中の台と
  一致するときだけ(`ownerUDID:` を必ず渡す。渡さなければ `.foreign`)③**接続先の同一性は
  `FTCore.BridgeIdentityCheck` で確かめる**(シナリオ実行プロセスの事前確認と、ホストの
  `bridgeUnreachable` 再プローブ = `BridgeProbeOutcome.hijacked`、**ライブ操作(`api live serve`)の
  宛先決定と `LiveBridgeAutoStarter.checkAndRestartIfStale`**。bundle ID が同じ別の台は
  /status の udid / engine でしか見分けられない)。**ライブ操作は `--udid` の明示/既定で扱いを分ける** ——
  `--port` を明示されたら不一致は断る / **既定ポートへのフォールバックなら断らずにその udid の
  ポートを探し、無ければ空きポートへ向けて自動起動に委ねる**(拡張は port が分かるときだけ
  `--port` を渡すので、**ブリッジのまだ無い台を開く場面**で既定 8123 に居る別の台を掴んでいた。
  ここで断ると、自動起動が想定しているその場面でライブ操作が開けなくなる → maintainer-notes §42.6)④ワークスペースのステージ先は
  `WorkspaceAppStaging.installPath(declared:)` = 宣言文字列の名前空間(絶対パスから導かない)
- **録画ありの run は供給段階で「端末側に残った録画セッション」を解く**(`HostRecordingProbe` →
  `ProfileWorkerFactory.recoverStaleRecordingIOSWorkers`。凍結の回復と同じ再起動・台は外さない・不明は撃たない)。
  **iOS の供給口3つ全部で凍結トリアージの直後に通す**(`HostRecordingProbeTests` が固定)。
  **検査も録画も recordVideo は SIGINT でしか止めない**(SIGKILL/SIGTERM がこの状態を作る)。
  切り出しのエンコーダはソフトウェア固定(実測は docs/verification.md §録画)
- **iOS 供給の `installIfNeeded` を `try?` で戻さない**(全員失敗の throw を飲むと失敗前の一覧に
  戻り、古いアプリのまま走る。`InstallIfNeededTryOptionalSourceScanTests`)
- **1台の失敗で全体を落とさない**。供給は部分失敗を許容し全滅のときだけ throw する
  (`BridgeProvisioner.resolveOutcomes` = 純粋関数)。**逆向きも守る —— 全レーンが同時に落ちて
  いるときにレーンを離脱させない**(`FTCore.WorkerCircuitBreaker`。連続失敗での離脱は
  「その streak の間に別のレーンが通った」証拠があるときだけ。無ければ残して走り続け
  `circuitHeld` を記録する。condition 除外案・閾値ノブだけの案は却下)→ maintainer-notes §6
- **ブリッジを起動する前に「そのポートを今 LISTEN している実体」を確かめる**。`/status` 応答だけで
  数えると、背面に回った in-app ブリッジ(TCP 受付・HTTP 無応答)が掴んだポートを「空き」と
  採番して新しい注入が衝突する(全シミュレータは loopback を共有 = ポートは台を跨いで一意)。
  `PortHolder.stopIfOwnedBridge` / `describe` と `StaleBridgeStop.decide` が定義元。
  **失敗は占有者を名指しして落とす**。
  **ポートだけで「自分の残骸」と決めない** —— `FleetestRunner-<port>.xctestrun` も `.inapp` も
  ポートしか持たないので、同じポートに居る**別デバイスの生きたブリッジ**を殺す/生かす判断に化ける
  (実地 2026-09-23: 既定ポートへ倒れた実機2台が互いのランナーを殺し合い、MCP が駆動中の
  シミュレータも巻き添えになった)。**宛先のデバイスを混ぜて、肯定的に別デバイスと読めた回だけ
  手を引く**(`RunnerDestination` / `PortHolder.listenerIsAnotherSimulator` /
  `PortHolder.isHeldByAnotherDevice`)—— 「分からないから残す」に倒すと本物の残骸が永久に
  ポートを塞ぐ。**busy は正常**(駆動中の XCUITest は /status に答えない)なので、
  単に「待受している」を根拠に他人扱いしない → maintainer-notes §46
- **回復のたびに label(ポート)は変わる**。回復を注入するときは**その時点のワーカー一覧を渡す**
  (`BlankWorkerTriage` の `recover` は第2引数)。最初の一覧を捕まえたままだと2回目の試行で
  新しい label を引けず、`frozen devices have no iOS simulator udid` で必ず失敗する

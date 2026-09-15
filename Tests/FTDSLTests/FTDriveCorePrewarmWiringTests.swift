// Vision のモデルの初回ロードは**プロセスに1回・実測 25〜108 秒**。DSL の経路
// (FTDriveCore)では executor 既定の occlusionGuard が常に false なので、StepExecutor.init の
// 暖機ゲート(executor 既定でガードが効くときだけ撃つ)は実質発火しない —— ステップ指定
// (exist の requireVisible 既定 true)でガードが立つのが通常形のため。だから FTDriveCore.init が
// 実行プロファイルのマスタースイッチ(textVisualCheckEnabled)だけを見て別に暖機を頼む
// (StepExecutorPrewarmTests と対の配線テスト)。

import FTCore
import XCTest

@testable import FTDSL

final class FTDriveCorePrewarmWiringTests: XCTestCase {

    private final class SilentDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil,
                            screen: FTRect(x: 0, y: 0, width: 100, height: 100),
                            elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    func testPrewarmsAtScenarioStartWhenTheMasterSwitchIsOn() {
        let before = RegionText.prewarmRequestCount
        _ = FTDriveCore(driver: SilentDriver(), platform: "ios", app: "com.example.app",
                        scenarioID: "T.S0010", scenarioTitle: "t",
                        delegate: nil, healingEnabled: false,
                        textVisualCheckEnabled: true, emit: { _ in })
        XCTAssertEqual(RegionText.prewarmRequestCount, before + 1,
                       "DSL のシナリオ開始時に暖機を始めていない")
    }

    /// マスタースイッチ(実行プロファイルの textVisualCheck)が off の run では撃たない
    /// (occlusionGuardEnabled が false = どのステップでもガードは走らないので Vision は要らない)
    func testDoesNotPrewarmWhenTheMasterSwitchIsOff() {
        let before = RegionText.prewarmRequestCount
        _ = FTDriveCore(driver: SilentDriver(), platform: "ios", app: "com.example.app",
                        scenarioID: "T.S0010", scenarioTitle: "t",
                        delegate: nil, healingEnabled: false,
                        textVisualCheckEnabled: false, emit: { _ in })
        XCTAssertEqual(RegionText.prewarmRequestCount, before)
    }

    /// OCR の殺しスイッチ(occlusionOCREnabled: false)が効いていれば Vision に触らない
    func testDoesNotPrewarmWhenOCRIsOff() {
        let before = RegionText.prewarmRequestCount
        _ = FTDriveCore(driver: SilentDriver(), platform: "ios", app: "com.example.app",
                        scenarioID: "T.S0010", scenarioTitle: "t",
                        delegate: nil, healingEnabled: false,
                        textVisualCheckEnabled: true, occlusionOCREnabled: false, emit: { _ in })
        XCTAssertEqual(RegionText.prewarmRequestCount, before)
    }
}

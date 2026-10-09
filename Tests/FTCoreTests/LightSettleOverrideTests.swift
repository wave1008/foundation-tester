// コマンドの `lightSettle:` 上書きが StepExecutor.execute → ドライバの TaskLocal まで届くことの固定。
// BridgeClient 側の判定は Tests/FTBridgeClientTests/SkipQuiescenceDecisionTests.swift。

import XCTest
@testable import FTCore

final class LightSettleOverrideTests: XCTestCase {

    private final class RecordingDriver: AppDriver, @unchecked Sendable {
        private(set) var seenInSwipe: [Bool?] = []
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil,
                             screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {
            seenInSwipe.append(LightSettleOverride.current)
        }
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func seen(_ lightSettle: Bool?) async -> [Bool?] {
        let driver = RecordingDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "swipe", direction: "up", lightSettle: lightSettle))
        return driver.seenInSwipe
    }

    func testTrueReachesTheDriver() async {
        let result = await seen(true)
        XCTAssertEqual(result, [true])
    }

    func testFalseReachesTheDriver() async {
        let result = await seen(false)
        XCTAssertEqual(result, [false])
    }

    func testNilLeavesNoOverride() async {
        let result = await seen(nil)
        XCTAssertEqual(result, [nil])
    }

    /// 外側の値を持ち越さない(nil のステップは上書きなし)
    func testNilStepDoesNotInheritTheOuterOverride() async {
        let driver = RecordingDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        await LightSettleOverride.$current.withValue(true) {
            _ = await executor.execute(FlowStep(action: "swipe", direction: "up"))
        }
        XCTAssertEqual(driver.seenInSwipe, [nil])
    }

    func testFlowStepRoundTripsLightSettleThroughCodable() throws {
        let step = FlowStep(action: "swipe", direction: "up", lightSettle: true)
        let decoded = try JSONDecoder().decode(FlowStep.self, from: JSONEncoder().encode(step))
        XCTAssertEqual(decoded.lightSettle, true)
    }
}

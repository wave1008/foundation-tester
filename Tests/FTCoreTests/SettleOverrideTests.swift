// `settle: false` が StepExecutor.execute → ドライバの TaskLocal(SettleOverride.skip)まで届くこと、
// ホスト側の操作後の整定(木のポーリング)を飛ばすこと、type / hideKeyboard が待ちを次のステップへ
// 持ち越さないことの固定。ブリッジ側の判定は Tests/FTBridgeClientTests。

import XCTest
@testable import FTCore

final class SettleOverrideTests: XCTestCase {

    private final class RecordingDriver: AppDriver, @unchecked Sendable {
        private(set) var seenInSwipe: [Bool] = []
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
            seenInSwipe.append(SettleOverride.skip)
        }
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func seen(_ settle: Bool?) async -> [Bool] {
        let driver = RecordingDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "swipe", direction: "up", settle: settle))
        return driver.seenInSwipe
    }

    func testSettleFalseReachesTheDriverAsSkip() async {
        let result = await seen(false)
        XCTAssertEqual(result, [true])
    }

    func testSettleNilLeavesNoOverride() async {
        let result = await seen(nil)
        XCTAssertEqual(result, [false])
    }

    func testSettleTrueLeavesNoOverride() async {
        let result = await seen(true)
        XCTAssertEqual(result, [false])
    }

    /// 外側の値を持ち越さない(settle を指定しないステップは整定する)
    func testNilStepDoesNotInheritTheOuterOverride() async {
        let driver = RecordingDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        await SettleOverride.$skip.withValue(true) {
            _ = await executor.execute(FlowStep(action: "swipe", direction: "up"))
        }
        XCTAssertEqual(driver.seenInSwipe, [false])
    }

    func testFlowStepRoundTripsSettleThroughCodable() throws {
        let step = FlowStep(action: "swipe", direction: "up", settle: false)
        let decoded = try JSONDecoder().decode(FlowStep.self, from: JSONEncoder().encode(step))
        XCTAssertEqual(decoded.settle, false)
        XCTAssertTrue(decoded.skipsSettle)
        XCTAssertFalse(FlowStep(action: "swipe", settle: true).skipsSettle)
        XCTAssertFalse(FlowStep(action: "swipe").skipsSettle)
    }

    // MARK: - ホスト側の整定

    private func list() -> ElementInfo {
        ElementInfo(ref: 1, type: "scrollView", identifier: "list_rows", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 100, width: 300, height: 600), depth: 1)
    }

    /// 静止した木では settledSignature は2枚で返る。操作前の整定(2枚)は残り、操作後の整定(2枚)だけが消える
    private func snapshots(_ step: FlowStep) async -> (count: Int, bypass: Bool) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[list()]])
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        let outcome = await executor.execute(step)
        if case .passed = outcome.status {} else { XCTFail("\(outcome.status)") }
        return (driver.snapshotCallCount, executor.nextResolveBypassesCache)
    }

    func testSwipeSkipsOnlyThePostActionSettle() async {
        let settled = await snapshots(FlowStep(action: "swipe", direction: "up"))
        let skipped = await snapshots(FlowStep(action: "swipe", direction: "up", settle: false))
        XCTAssertEqual(settled.count - skipped.count, 2)
        XCTAssertGreaterThan(skipped.count, 0, "操作前の整定は残る")
        XCTAssertTrue(skipped.bypass, "飛ばしても次の解決はキャッシュを迂回する")
    }

    func testScrollSkipsOnlyTheFinalSettle() async {
        let settled = await snapshots(FlowStep(action: "scroll", direction: "up", maxSwipes: 1))
        let skipped = await snapshots(FlowStep(action: "scroll", direction: "up", maxSwipes: 1, settle: false))
        XCTAssertEqual(settled.count - skipped.count, 2)
    }

    /// repeat の本の間の静止待ちは内側の整定なので残る(最後の1本の後だけ消える)
    func testRepeatedScrollKeepsTheSettleBetweenSwipes() async {
        let settled = await snapshots(FlowStep(action: "scroll", direction: "up", maxSwipes: 2))
        let skipped = await snapshots(FlowStep(action: "scroll", direction: "up", maxSwipes: 2, settle: false))
        XCTAssertEqual(settled.count - skipped.count, 2)
    }

    func testFlickSkipsTheFinalSettle() async throws {
        try XCTSkipUnless(StepExecutor.coordinateScrollEnabled, "FT_SCROLL_TARGET=legacy では枠を使わない")
        func flick(_ settle: Bool?) -> FlowStep {
            var step = FlowStep(action: "flick", direction: "bottomToTop", maxSwipes: 1, settle: settle)
            step.scrollFrame = FlowLocator(id: "list_rows")
            return step
        }
        let settled = await snapshots(flick(nil))
        let skipped = await snapshots(flick(false))
        XCTAssertEqual(settled.count - skipped.count, 2)
    }

    // MARK: - 持ち越す待ち

    private func field() -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: "wv_input", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 20, y: 300, width: 200, height: 40), depth: 1)
    }

    func testTypeWithSettleFalseLeavesNoPendingKeyboardCheck() async {
        func armed(_ settle: Bool?) async -> Bool {
            let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[field()]])
            driver.verifiesTypedText = true
            let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            _ = await executor.execute(
                FlowStep(action: "type", locator: FlowLocator(id: "wv_input"), text: "hello", settle: settle))
            return executor.pendingTypeKeyboardCheck
        }
        let withDefault = await armed(nil)
        let withSkip = await armed(false)
        XCTAssertTrue(withDefault, "陽性対照: 既定では次の解決で比べる印が立つ")
        XCTAssertFalse(withSkip)
    }

    /// 焦点救済(tap の直後に焦点が立っていなかった type)の経路も同じ
    func testFocusRescueTypeWithSettleFalseLeavesNoPendingKeyboardCheck() async {
        func armed(_ settle: Bool?) async -> Bool {
            let container = ElementInfo(ref: 8, type: "other", identifier: "wrapper", label: nil, value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 20, y: 300, width: 300, height: 60), depth: 1)
            let inner = ElementInfo(ref: 9, type: "textField", identifier: "inner_edit", label: nil, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 20, y: 300, width: 300, height: 60), depth: 2)
            let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[container, inner]])
            let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "wrapper"), timeout: 1))
            _ = await executor.execute(FlowStep(action: "type", text: "hello", settle: settle))
            return executor.pendingTypeKeyboardCheck
        }
        let withDefault = await armed(nil)
        let withSkip = await armed(false)
        XCTAssertTrue(withDefault, "陽性対照: 既定では救済した type も印を立てる")
        XCTAssertFalse(withSkip)
    }

    func testHideKeyboardWithSettleFalseLeavesNoPendingWait() async {
        func pending(_ settle: Bool?) async -> Double? {
            let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[field()]])
            let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            _ = await executor.execute(FlowStep(action: "hideKeyboard", settle: settle))
            return executor.pendingHideKeyboardWait
        }
        let withDefault = await pending(nil)
        let withSkip = await pending(false)
        XCTAssertNotNil(withDefault, "陽性対照: 既定では待ちの印が立つ")
        XCTAssertNil(withSkip)
    }
}

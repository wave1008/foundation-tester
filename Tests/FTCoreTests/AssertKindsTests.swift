import XCTest
@testable import FTCore

/// notExists / enabled / disabled / count の実行セマンティクス(StepExecutor.executeAssert)。
/// snapshot はスクリプト可能で、ポーリングによる状態変化の追従も検証する。
final class AssertKindsTests: XCTestCase {

    /// snapshot() 呼び出し回数ごとに要素列を差し替えるドライバ(列を使い切ったら最後を繰り返す)
    private final class ScriptedDriver: AppDriver {
        var frames: [[ElementInfo]]
        private(set) var snapshotCallCount = 0
        init(frames: [[ElementInfo]]) { self.frames = frames }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            snapshotCallCount += 1
            let index = min(snapshotCallCount - 1, max(0, frames.count - 1))
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: frames.isEmpty ? [] : frames[index],
                                    truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func node(_ ref: Int, type: String = "Button", id: String? = nil,
                      label: String? = nil, enabled: Bool = true, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: depth)
    }

    private func isPassed(_ status: StepResult.Status) -> Bool {
        if case .passed = status { return true }
        if case .passedViaFallback = status { return true }
        return false
    }

    private func failureReason(_ status: StepResult.Status) -> String? {
        if case .failed(let reason) = status { return reason }
        return nil
    }

    // MARK: - notExists

    func testNotExistPassesImmediatelyWhenAbsent() async {
        let driver = ScriptedDriver(frames: [[node(1, id: "other")]])
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"), timeout: 5)
        let outcome = await executor.execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        // 不在なら初回の 1 回で確定する(タイムアウトまで待たない)
        XCTAssertEqual(driver.snapshotCallCount, 1)
    }

    func testNotExistWaitsUntilElementDisappears() async {
        let driver = ScriptedDriver(frames: [
            [node(1, id: "dialog")],
            [node(1, id: "dialog")],
            [node(2, id: "other")],
        ])
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"), timeout: 5)
        let outcome = await executor.execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.snapshotCallCount, 3)
    }

    func testNotExistFailsWhileStillPresent() async {
        let driver = ScriptedDriver(frames: [[node(1, id: "dialog")]])
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"), timeout: 0)
        let outcome = await executor.execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("まだ存在します"), true)
    }

    func testNotExistConfirmsAbsenceWithFallbackDriver() async {
        // primary(アプリ内)には無いがシステム UI 側に居る = まだ閉じていない
        let primary = ScriptedDriver(frames: [[node(1, id: "other")]])
        let fallback = ScriptedDriver(frames: [[node(9, label: "許可")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(label: "許可"), timeout: 0)
        let outcome = await executor.execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("システム UI"), true)
    }

    // MARK: - enabled / disabled

    func testEnabledPassesAndDisabledFailsForEnabledElement() async {
        let frames = [[node(1, id: "send", enabled: true)]]
        let enabledOutcome = await StepExecutor(driver: ScriptedDriver(frames: frames))
            .execute(FlowStep(assert: "enabled", locator: FlowLocator(id: "send"), timeout: 0))
        XCTAssertTrue(isPassed(enabledOutcome.status))

        let disabledOutcome = await StepExecutor(driver: ScriptedDriver(frames: frames))
            .execute(FlowStep(assert: "disabled", locator: FlowLocator(id: "send"), timeout: 0))
        XCTAssertEqual(failureReason(disabledOutcome.status)?.contains("要素は有効です"), true)
    }

    func testEnabledWaitsForStateChange() async {
        let driver = ScriptedDriver(frames: [
            [node(1, id: "send", enabled: false)],
            [node(1, id: "send", enabled: true)],
        ])
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(assert: "enabled", locator: FlowLocator(id: "send"), timeout: 5))
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.snapshotCallCount, 2)
    }

    func testEnabledFailsWithNotFoundWhenMissing() async {
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[]]))
            .execute(FlowStep(assert: "enabled", locator: FlowLocator(id: "send"), timeout: 0))
        XCTAssertEqual(failureReason(outcome.status)?.contains("要素が見つかりません"), true)
    }

    // MARK: - count

    func testCountMatchesWithinScope() async {
        let elements = [
            node(0, type: "Other", depth: 0),
            node(1, type: "Other", id: "list", depth: 1),
            node(2, type: "Cell", depth: 2),
            node(3, type: "Cell", depth: 2),
            node(4, type: "Cell", depth: 1),   // list の外
        ]
        let scoped = FlowLocator(type: "Cell", scope: [FlowLocator(id: "list")])
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements]))
            .execute(FlowStep(assert: "count", locator: scoped, timeout: 0, expectedCount: 2))
        XCTAssertTrue(isPassed(outcome.status))
    }

    func testCountFailureReportsActual() async {
        let elements = [node(1, type: "Cell"), node(2, type: "Cell")]
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements]))
            .execute(FlowStep(assert: "count", locator: FlowLocator(type: "Cell"),
                              timeout: 0, expectedCount: 3))
        let reason = failureReason(outcome.status)
        XCTAssertEqual(reason?.contains("期待 3"), true)
        XCTAssertEqual(reason?.contains("実際 2"), true)
    }

    func testCountWaitsForListToFill() async {
        let driver = ScriptedDriver(frames: [
            [node(1, type: "Cell")],
            [node(1, type: "Cell"), node(2, type: "Cell")],
        ])
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(assert: "count", locator: FlowLocator(type: "Cell"),
                              timeout: 5, expectedCount: 2))
        XCTAssertTrue(isPassed(outcome.status))
    }

    func testCountWithoutExpectedCountIsSkipped() async {
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[]]))
            .execute(FlowStep(assert: "count", locator: FlowLocator(type: "Cell"), timeout: 0))
        if case .skipped = outcome.status {} else { XCTFail("skipped を期待: \(outcome.status)") }
    }
    func testCountUsesFirstResolvingClauseNotUnion() async {
        // `||` は他コマンドと同じ「解決できる方」= 候補が見つかった最初の節だけを数える
        let elements = [node(1, type: "Cell", id: "row"), node(2, type: "Row"), node(3, type: "Row")]
        let step = FlowStep(assert: "count", locator: FlowLocator(type: "Cell"),
                            fallbacks: [FlowLocator(type: "Row")], timeout: 0, expectedCount: 1)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "先に見つかった .Cell の 1 件で判定する(合計 3 ではない)")
    }

    func testCountFallsBackToNextClauseWhenPrimaryHasNoCandidate() async {
        let elements = [node(1, type: "Row"), node(2, type: "Row")]
        let step = FlowStep(assert: "count", locator: FlowLocator(type: "Cell"),
                            fallbacks: [FlowLocator(type: "Row")], timeout: 0, expectedCount: 2)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
    }

}

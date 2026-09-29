// hold { }(holdStart/holdEnd の2アクション)の実行時の配線を、実際の StepExecutor +
// FakeAppDriver(StepExecutorTestSupport.swift)で検証する。DSL 側(block の実行/スキップ)は
// Tests/FTDSLTests/HoldDSLTests.swift が別に見る。

import XCTest
@testable import FTCore

final class HoldStepTests: XCTestCase {

    private let targetFrame = FTRect(x: 100, y: 200, width: 50, height: 40)

    private func makeElement() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "btn_tooltip_anchor", label: "?",
                   value: nil, placeholder: nil, enabled: true, frame: targetFrame, depth: 1)
    }

    /// (a) holdStart は要素の中心へちょうど1回だけ hold を送り、tap/press は一切送らない
    func testHoldStartSendsExactlyOneHoldAtTheElementsCentre() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[makeElement()]])
        let executor = StepExecutor(driver: driver, isAndroid: false)

        let outcome = await executor.execute(FlowStep(
            action: "holdStart", locator: FlowLocator(id: "btn_tooltip_anchor"), duration: 3))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.holdCallCount, 1)
        XCTAssertEqual(driver.lastHold?.x, targetFrame.centerX)
        XCTAssertEqual(driver.lastHold?.y, targetFrame.centerY)
        XCTAssertEqual(driver.lastHold?.duration, 3)
        XCTAssertTrue(log.entries.allSatisfy { !$0.contains(".tap(") && !$0.contains(".press(") },
                      "tap/press を送ってはいけない: \(log.entries)")
    }

    /// (b) holdEnd はブリッジが指を離す時刻(duration + margin)まで実際に待ってから返る
    func testHoldEndWaitsUntilTheLiftTime() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[makeElement()]])
        let executor = StepExecutor(driver: driver, isAndroid: false)

        let start = await executor.execute(FlowStep(
            action: "holdStart", locator: FlowLocator(id: "btn_tooltip_anchor"), duration: 0.5))
        guard case .passed = start.status else { return XCTFail("\(start.status)") }

        let clock = ContinuousClock()
        let began = clock.now
        let end = await executor.execute(FlowStep(action: "holdEnd"))
        let elapsed = clock.now - began

        guard case .passed = end.status else { return XCTFail("\(end.status)") }
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(1200),
                                    "duration ぶんは必ず待つはず(実測 \(elapsed))")
        XCTAssertLessThan(elapsed, .seconds(3), "margin を大きく超えて待ってはいけない")
    }

    /// (c) ブロックが duration + margin より長く掛かっていたら、holdEnd は撮り直しの分だけ
    /// 待たず(既に離れている)、注記 hold-ended-before-block を残す
    func testHoldEndDoesNotSleepAgainWhenTheBlockAlreadyOutlastedTheHold() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[makeElement()]])
        let executor = StepExecutor(driver: driver, isAndroid: false)

        let start = await executor.execute(FlowStep(
            action: "holdStart", locator: FlowLocator(id: "btn_tooltip_anchor"), duration: 0.2))
        guard case .passed = start.status else { return XCTFail("\(start.status)") }

        // duration(0.2) + 余裕(0.8) = 1.0s を追い越すまで、ブロックの代わりに素朴に待つ
        try await Task.sleep(for: .milliseconds(1200))

        let clock = ContinuousClock()
        let began = clock.now
        let end = await executor.execute(FlowStep(action: "holdEnd"))
        let elapsed = clock.now - began

        guard case .passed = end.status else { return XCTFail("\(end.status)") }
        XCTAssertTrue(end.notes.contains(.holdEndedBeforeBlock),
                      "hold-ended-before-block が立つはず: \(end.notes)")
        XCTAssertLessThan(elapsed, .seconds(1),
                         "既に離れているので duration ぶん撮り直し待ちしてはいけない(実測 \(elapsed))")
    }

    /// (c2) ブロックの中の失敗が、指が上がった後に確定したなら、その失敗に注記が立つ
    /// (中断で holdEnd は実行されないので、失敗したステップ自身が持つ)
    func testAFailureAfterTheFingerLiftedCarriesTheNote() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[makeElement()]])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        let start = await executor.execute(FlowStep(
            action: "holdStart", locator: FlowLocator(id: "btn_tooltip_anchor"), duration: 0.2))
        guard case .passed = start.status else { return XCTFail("\(start.status)") }

        // 居ない要素を 0.5 秒待つ = 失敗が確定するのは指が上がった(0.2 秒)後
        let failed = await executor.execute(FlowStep(
            assert: "exists", locator: FlowLocator(id: "txt_never_shown"), timeout: 0.5))
        guard case .failed = failed.status else { return XCTFail("\(failed.status)") }
        XCTAssertTrue(failed.notes.contains(.holdEndedBeforeBlock), "\(failed.notes)")
    }

    /// (c3) 逆向き: 指が下がっている間に確定した失敗には立てない
    func testAFailureWhileTheFingerIsDownCarriesNoNote() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[makeElement()]])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        let start = await executor.execute(FlowStep(
            action: "holdStart", locator: FlowLocator(id: "btn_tooltip_anchor"), duration: 8))
        guard case .passed = start.status else { return XCTFail("\(start.status)") }

        let failed = await executor.execute(FlowStep(
            assert: "exists", locator: FlowLocator(id: "txt_never_shown"), timeout: 0.2))
        guard case .failed = failed.status else { return XCTFail("\(failed.status)") }
        XCTAssertFalse(failed.notes.contains(.holdEndedBeforeBlock), "\(failed.notes)")
    }

    /// (d) 前の hold が離れる前に次の holdStart を送ると失敗する(入れ子禁止)
    func testASecondHoldWhileOneIsInFlightFails() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[makeElement()]])
        let executor = StepExecutor(driver: driver, isAndroid: false)

        let first = await executor.execute(FlowStep(
            action: "holdStart", locator: FlowLocator(id: "btn_tooltip_anchor"), duration: 3))
        guard case .passed = first.status else { return XCTFail("\(first.status)") }

        let second = await executor.execute(FlowStep(
            action: "holdStart", locator: FlowLocator(id: "btn_tooltip_anchor"), duration: 3))
        guard case .failed(let message) = second.status else {
            return XCTFail("入れ子の hold は失敗するはず: \(second.status)")
        }
        XCTAssertTrue(message.lowercased().contains("nest"), message)
    }

    /// (e) ドライバが既定の未対応エラー(501)を投げたら、holdStart は無言で pass せず失敗する
    func testHoldStartFailsWhenTheDriverDoesNotSupportHold() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "d", log: log, snapshotElements: [[makeElement()]])
        driver.holdError = DriverError.badResponse(status: 501, body: "This driver does not support hold")
        // typeDriver を渡さない: gestureWithFallback に回す先が無いので、501 がそのまま素通りする
        let executor = StepExecutor(driver: driver, isAndroid: false)

        let outcome = await executor.execute(FlowStep(
            action: "holdStart", locator: FlowLocator(id: "btn_tooltip_anchor"), duration: 1))

        guard case .failed(let message) = outcome.status else {
            return XCTFail("501 のまま黙って pass してはいけない: \(outcome.status)")
        }
        XCTAssertFalse(message.isEmpty)
    }
}

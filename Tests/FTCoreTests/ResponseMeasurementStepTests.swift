// 応答時間計測: StepExecutor が画面を動かす操作の前後で prepare / collect を呼び、結果を StepOutcome に載せ、
// TimelineStepRecord まで運ぶこと

import XCTest
@testable import FTCore

final class ResponseMeasurementStepTests: XCTestCase {

    private func okButton() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: nil, label: "OK", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 10, y: 100, width: 100, height: 40), depth: 1)
    }

    private func makeExecutor(measuring: Bool, driver: FakeAppDriver,
                              tunables: RunTunables = RunTunables()) -> StepExecutor {
        StepExecutor(driver: driver, isAndroid: true, tunables: tunables, responseMeasurement: measuring)
    }

    private func makeDriver(_ log: CallLog) -> FakeAppDriver {
        FakeAppDriver(name: "d", log: log, snapshotElements: [[okButton()]])
    }

    private let tap = FlowStep(action: "tap", locator: FlowLocator(label: "OK"))

    func testPrepareBeforeActionAndCollectAfterWithTunables() async {
        let log = CallLog()
        let driver = makeDriver(log)
        var tunables = RunTunables()
        tunables.responseQuietMs = 321
        tunables.responseQuietTimeoutMs = 4321
        let outcome = await makeExecutor(measuring: true, driver: driver, tunables: tunables).execute(tap)

        let prepareAt = log.entries.firstIndex(of: "d.responsePrepare")
        let tapAt = log.entries.firstIndex { $0.hasPrefix("d.tap") }
        let collectAt = log.entries.firstIndex(of: "d.responseCollect")
        XCTAssertNotNil(prepareAt)
        XCTAssertNotNil(tapAt)
        XCTAssertNotNil(collectAt)
        XCTAssertLessThan(prepareAt!, tapAt!)
        XCTAssertLessThan(tapAt!, collectAt!)
        XCTAssertEqual(driver.prepareArguments.first?.quietMs, 321)
        XCTAssertEqual(driver.prepareArguments.first?.timeoutMs, 4321)
        let response = outcome.response
        XCTAssertEqual(response?.busyBeforeAction, false)
        XCTAssertEqual(response?.quietWaitMs, 12)
        XCTAssertEqual(response?.firstFrameMs, 34)
        XCTAssertNil(response?.firstFrameMissing)
        XCTAssertNil(response?.reactionMs)
        XCTAssertNil(response?.readyMs)
        XCTAssertEqual(response?.readyMissing, "notMeasuredInThisVersion")
    }

    func testBusyBeforeActionWithholdsFirstFrame() async {
        let driver = makeDriver(CallLog())
        driver.prepareResult = .success(ResponsePrepareResult(quiet: false, waitedMs: 5000))
        let response = await makeExecutor(measuring: true, driver: driver).execute(tap).response
        XCTAssertEqual(response?.busyBeforeAction, true)
        XCTAssertNil(response?.firstFrameMs)
        XCTAssertEqual(response?.firstFrameMissing, .busyBeforeAction)
        XCTAssertEqual(response?.quietWaitMs, 5000)
    }

    func testCollectReasonIsCarried() async {
        let driver = makeDriver(CallLog())
        driver.collectResult = .success(ResponseCollectResult(downTimeMs: nil, firstFrameDelayMs: nil,
                                                               reason: "noInjectedInput"))
        let response = await makeExecutor(measuring: true, driver: driver).execute(tap).response
        XCTAssertNil(response?.firstFrameMs)
        XCTAssertEqual(response?.firstFrameMissing, .noInjectedInput)
    }

    func testCollectFailureDoesNotChangeTheStep() async {
        let driver = makeDriver(CallLog())
        driver.collectResult = .failure(DriverError.badResponse(status: 500, body: "x"))
        let outcome = await makeExecutor(measuring: true, driver: driver).execute(tap)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertNil(outcome.response?.firstFrameMs)
        XCTAssertEqual(outcome.response?.firstFrameMissing, .bridgeError)
    }

    func testPrepareFailureDoesNotChangeTheStep() async {
        let driver = makeDriver(CallLog())
        driver.prepareResult = .failure(DriverError.badResponse(status: 501, body: "x"))
        let outcome = await makeExecutor(measuring: true, driver: driver).execute(tap)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(outcome.response?.firstFrameMissing, .bridgeError)
        XCTAssertNil(outcome.response?.quietWaitMs)
    }

    func testAssertionAndSelectAreNotMeasured() async {
        let log = CallLog()
        let driver = makeDriver(log)
        let executor = makeExecutor(measuring: true, driver: driver)
        let assertion = await executor.execute(FlowStep(assert: "exist", locator: FlowLocator(label: "OK")))
        let select = await executor.execute(FlowStep(action: "select", locator: FlowLocator(label: "OK")))
        XCTAssertNil(assertion.response)
        XCTAssertNil(select.response)
        XCTAssertFalse(log.entries.contains("d.responsePrepare"))
        XCTAssertFalse(log.entries.contains("d.responseCollect"))
    }

    func testModeOffMakesNoCalls() async {
        let log = CallLog()
        let driver = makeDriver(log)
        let outcome = await makeExecutor(measuring: false, driver: driver).execute(tap)
        XCTAssertNil(outcome.response)
        XCTAssertEqual(driver.collectCallCount, 0)
        XCTAssertTrue(driver.prepareArguments.isEmpty)
    }

    func testPacingAndMeasurementShareTheOperationJudgement() {
        XCTAssertTrue(FlowStep(action: "tap", locator: FlowLocator(label: "OK")).isScreenMovingOperation)
        XCTAssertFalse(FlowStep(action: "waitForSettle").isScreenMovingOperation)
        XCTAssertFalse(FlowStep(action: "findImages").isScreenMovingOperation)
        XCTAssertFalse(FlowStep(action: "existImage").isScreenMovingOperation)
        // settle: false は減速だけを止める。計測の対象からは外さない
        XCTAssertTrue(FlowStep(action: "tap", locator: FlowLocator(label: "OK"), settle: false).isScreenMovingOperation)
    }

    func testRecordMakeLeavesUnknownReasonOut() {
        let record = ResponseMeasurementRecord.make(
            prepare: ResponsePrepareResult(quiet: true, waitedMs: 1),
            collect: ResponseCollectResult(downTimeMs: 1, firstFrameDelayMs: nil, reason: "somethingNew"))
        XCTAssertNil(record.firstFrameMs)
        XCTAssertNil(record.firstFrameMissing)
    }

    func testPrepareReasonIsNotCountedAsBusy() {
        let record = ResponseMeasurementRecord.make(
            prepare: ResponsePrepareResult(quiet: false, waitedMs: 0, reason: "noSessionApp"),
            collect: ResponseCollectResult(downTimeMs: 1, firstFrameDelayMs: 30, reason: nil))
        XCTAssertFalse(record.busyBeforeAction)
        XCTAssertNil(record.firstFrameMs)
        XCTAssertEqual(record.firstFrameMissing, .noSessionApp)
    }

    func testRecordRoundTrip() throws {
        let full = ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: 3, firstFrameMs: 40,
                                             firstFrameMissing: nil)
        let empty = ResponseMeasurementRecord(busyBeforeAction: true, quietWaitMs: nil, firstFrameMs: nil,
                                              firstFrameMissing: .busyBeforeAction, readyMissing: nil)
        for record in [full, empty] {
            let data = try JSONEncoder().encode(record)
            XCTAssertEqual(try JSONDecoder().decode(ResponseMeasurementRecord.self, from: data), record)
        }
    }

    func testTimelineCarriesCommandAndResponse() {
        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", platform: "android", title: nil, worker: nil)
        var event = ScenarioEvent(kind: "step")
        event.index = 1
        event.description = "tap OK"
        event.status = "passed"
        event.command = "tap"
        event.response = ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: 7, firstFrameMs: 55,
                                                   firstFrameMissing: nil)
        builder.consume(event)
        var plain = ScenarioEvent(kind: "step")
        plain.index = 2
        plain.description = "exist"
        plain.status = "passed"
        builder.consume(plain)
        let record = builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 1, packageRoot: nil)
        XCTAssertEqual(record.timeline?[0].command, "tap")
        XCTAssertEqual(record.timeline?[0].response?.firstFrameMs, 55)
        XCTAssertNil(record.timeline?[1].command)
        XCTAssertNil(record.timeline?[1].response)
    }

    func testStepResultFromEventCarriesResponse() {
        var event = ScenarioEvent(kind: "step")
        event.status = "passed"
        event.response = ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: 1, firstFrameMs: 2,
                                                   firstFrameMissing: nil)
        XCTAssertEqual(ScenarioRunner.stepResult(from: event).response?.firstFrameMs, 2)
    }
}

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
        tunables.responseObserveMs = 7654
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
        XCTAssertEqual(driver.prepareArguments.first?.observeMs, 7654)
        let response = outcome.response
        XCTAssertEqual(response?.busyBeforeAction, false)
        XCTAssertEqual(response?.quietWaitMs, 12)
        XCTAssertEqual(response?.firstFrameMs, 34)
        XCTAssertNil(response?.firstFrameMissing)
        XCTAssertNil(response?.reactionMs)
        XCTAssertNil(response?.readyMs)
        XCTAssertNil(response?.readyMissing, "t2 の欄は次の計測ステップの判定で後から入る。操作の直後は空")
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

    // MARK: - t2(前の計測ステップの確定)

    private func collected(first: Int?, last: Int? = nil, injections: Int = 1) -> Result<ResponseCollectResult, Error> {
        .success(ResponseCollectResult(downTimeMs: first, firstFrameDelayMs: 30, lastDownTimeMs: last ?? first,
                                       injections: first == nil ? 0 : injections))
    }

    /// OK ボタンが履歴の最初から最後まで揃っている観測(読みは 1100ms から 3 回)
    private func readyObservation() -> ResponseObservation {
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [okButton()], truncatedCount: 0)
        return ResponseObservation(
            found: true, firstDownTimeMs: 1000, lastDownTimeMs: 1000, injections: 1, endedAtMs: 1200,
            endReason: "nextInjection",
            reads: (0..<3).map { ResponseObservation.Read(startMs: 1100 + $0 * 10, endMs: 1104 + $0 * 10, ok: true) },
            trees: [ResponseObservation.Tree(readIndex: 0, snapshot: snapshot)])
    }

    func testPreviousStepIsJudgedWithTheNextStepsTargetAfterItsCollect() async {
        let log = CallLog()
        let driver = makeDriver(log)
        driver.collectResults = [collected(first: 1000), collected(first: 5000)]
        driver.observationResults = [.success(readyObservation())]
        let executor = makeExecutor(measuring: true, driver: driver)

        let first = await executor.execute(tap)
        XCTAssertNil(first.readyUpdateForPreviousStep)
        XCTAssertTrue(first.opensReadyObservation)
        XCTAssertTrue(driver.fetchedFirstDownTimes.isEmpty, "最初の計測ステップは判定する前のステップが無い")

        let second = await executor.execute(tap)
        XCTAssertEqual(driver.fetchedFirstDownTimes, [1000])
        let collects = log.entries.indices.filter { log.entries[$0] == "d.responseCollect" }
        let fetchAt = log.entries.firstIndex(of: "d.responseObservation")
        XCTAssertEqual(collects.count, 2)
        XCTAssertGreaterThan(fetchAt!, collects[1], "取得は次のステップの collect の後")
        XCTAssertEqual(second.readyUpdateForPreviousStep?.readyMs, 104)
        XCTAssertEqual(second.readyUpdateForPreviousStep?.readyDecidedBy, "tree")
        XCTAssertEqual(second.readyUpdateForPreviousStep?.readyIdentity, "locator")
        XCTAssertTrue(second.opensReadyObservation)
        XCTAssertNil(second.response?.readyMs, "更新は前のステップ宛て。自分の欄は空のまま")
    }

    func testNonMeasuredStepsInBetweenDoNotDisturbThePending() async {
        let driver = makeDriver(CallLog())
        driver.collectResults = [collected(first: 1000), collected(first: 5000)]
        driver.observationResults = [.success(readyObservation())]
        let executor = makeExecutor(measuring: true, driver: driver)
        _ = await executor.execute(tap)
        let between = await executor.execute(FlowStep(assert: "exist", locator: FlowLocator(label: "OK")))
        XCTAssertNil(between.readyUpdateForPreviousStep)
        XCTAssertFalse(between.opensReadyObservation)
        XCTAssertTrue(driver.fetchedFirstDownTimes.isEmpty)
        let last = await executor.execute(tap)
        XCTAssertEqual(driver.fetchedFirstDownTimes, [1000])
        XCTAssertNotNil(last.readyUpdateForPreviousStep)
    }

    func testStepWithoutInjectionKeepsThePreviousPending() async {
        let driver = makeDriver(CallLog())
        driver.collectResults = [collected(first: 1000), collected(first: nil), collected(first: 5000)]
        driver.observationResults = [.success(readyObservation())]
        let executor = makeExecutor(measuring: true, driver: driver)
        _ = await executor.execute(tap)
        let noInjection = await executor.execute(tap)
        XCTAssertNil(noInjection.readyUpdateForPreviousStep)
        XCTAssertFalse(noInjection.opensReadyObservation)
        XCTAssertTrue(driver.fetchedFirstDownTimes.isEmpty, "注入しなかったステップは判定しない")
        let third = await executor.execute(tap)
        XCTAssertEqual(driver.fetchedFirstDownTimes, [1000])
        XCTAssertNotNil(third.readyUpdateForPreviousStep)
    }

    func testFetchErrorBecomesBridgeError() async {
        let driver = makeDriver(CallLog())
        driver.collectResults = [collected(first: 1000, last: 1050, injections: 3), collected(first: 5000)]
        driver.observationResults = [.failure(DriverError.badResponse(status: 500, body: "x"))]
        let executor = makeExecutor(measuring: true, driver: driver)
        _ = await executor.execute(tap)
        let update = await executor.execute(tap).readyUpdateForPreviousStep
        XCTAssertEqual(update?.readyMissing, "bridgeError")
        XCTAssertNil(update?.readyMs)
        XCTAssertEqual(update?.injections, 3)
        XCTAssertEqual(update?.injectionSpanMs, 50)
    }

    func testCoordinateStepIsNoTargetAndMakesNoFetch() async {
        let driver = makeDriver(CallLog())
        driver.collectResults = [collected(first: 1000), collected(first: 5000)]
        let executor = makeExecutor(measuring: true, driver: driver)
        _ = await executor.execute(tap)
        let update = await executor.execute(FlowStep(action: "tap", x: 50, y: 120)).readyUpdateForPreviousStep
        XCTAssertEqual(update?.readyMissing, "noTarget")
        XCTAssertTrue(driver.fetchedFirstDownTimes.isEmpty)
    }

    func testModeOffNeverFetches() async {
        let driver = makeDriver(CallLog())
        let executor = makeExecutor(measuring: false, driver: driver)
        let first = await executor.execute(tap)
        let second = await executor.execute(tap)
        XCTAssertTrue(driver.fetchedFirstDownTimes.isEmpty)
        XCTAssertNil(second.readyUpdateForPreviousStep)
        XCTAssertFalse(first.opensReadyObservation)
        await executor.endResponseMeasurement()
        XCTAssertEqual(driver.stopObservationCallCount, 0)
    }

    func testEndResponseMeasurementStopsAndClearsPending() async {
        let driver = makeDriver(CallLog())
        driver.collectResults = [collected(first: 1000), collected(first: 5000)]
        let executor = makeExecutor(measuring: true, driver: driver)
        _ = await executor.execute(tap)
        await executor.endResponseMeasurement()
        XCTAssertEqual(driver.stopObservationCallCount, 1)
        let next = await executor.execute(tap)
        XCTAssertNil(next.readyUpdateForPreviousStep, "終わった後の宛先は残さない")
        XCTAssertTrue(driver.fetchedFirstDownTimes.isEmpty)
    }

    func testResponseReadyEventPatchesTheTimelineEntryByIndex() {
        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", platform: "android", title: nil, worker: nil)
        for index in 1...3 {
            var step = ScenarioEvent(kind: "step")
            step.index = index
            step.description = "step \(index)"
            step.status = "passed"
            if index != 2 {
                step.response = ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: 1, firstFrameMs: 10 * index,
                                                          firstFrameMissing: nil)
            }
            builder.consume(step)
        }
        var ready = ScenarioEvent(kind: "responseReady")
        ready.index = 1
        ready.readyUpdate = ResponseReadyUpdate(readyMs: 300, readyAfterLastInjectionMs: 200, injectionSpanMs: 100,
                                                injections: 2, readyDecidedBy: "tree", readyIdentity: "locator")
        builder.consume(ready)
        // 計測していないステップ宛て・存在しない添字は捨てる(別の行へ当てない)
        var stray = ScenarioEvent(kind: "responseReady")
        stray.index = 2
        stray.readyUpdate = ResponseReadyUpdate(readyMs: 9)
        builder.consume(stray)
        stray.index = 99
        builder.consume(stray)

        let record = builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 1, packageRoot: nil)
        XCTAssertEqual(record.timeline?[0].response?.readyMs, 300)
        XCTAssertEqual(record.timeline?[0].response?.injections, 2)
        XCTAssertEqual(record.timeline?[0].response?.firstFrameMs, 10)
        XCTAssertNil(record.timeline?[1].response)
        XCTAssertNil(record.timeline?[2].response?.readyMs)
        XCTAssertEqual(record.timeline?.count, 3)
    }
}

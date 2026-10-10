// DSL の waitForSettle(StepExecutor+WaitForSettle.swift)。段1 = ブリッジの画像の静止(送り先・範囲・窓の配線)、
// 段2 = ホストの木の追いつき(範囲内の署名が連続2枚一致)、結末(失敗の素性・諦めて通す注記)、
// デバイスに触る前の検査、次のステップへ残す状態。FakeAppDriver の応答は呼び出し回数ごとの列で与える。

import XCTest
@testable import FTCore

final class WaitForSettleExecutorTests: XCTestCase {

    private let listFrame = FTRect(x: 10, y: 20, width: 300, height: 400)

    private func element(_ ref: Int, id: String, label: String? = nil, frame: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: 1)
    }

    /// 呼ぶたびに別の木になるドライバ用の列(`ticker` のラベルが毎回変わる)
    private func drifting(_ count: Int, frame: FTRect) -> [[ElementInfo]] {
        (0..<count).map { [element(1, id: "ticker", label: "n\($0)", frame: frame)] }
    }

    private func steady() -> FakeAppDriver {
        FakeAppDriver(name: "primary", log: CallLog(),
                      snapshotElements: [[element(1, id: "list", frame: listFrame)]])
    }

    private func makeExecutor(_ driver: FakeAppDriver, typeDriver: FakeAppDriver? = nil, isAndroid: Bool = false,
                              framework: AppUIFramework? = .compose, tunables: RunTunables = RunTunables()) -> StepExecutor {
        StepExecutor(driver: driver, typeDriver: typeDriver, isAndroid: isAndroid, tunables: tunables,
                     uiFramework: framework)
    }

    private func message(_ status: StepResult.Status) -> String? {
        if case .failed(let text) = status { return text }
        return nil
    }

    private func isPassed(_ status: StepResult.Status) -> Bool {
        if case .passed = status { return true }
        return false
    }

    private func unsettled(elapsedMs: Int = 5000, change: FTRect? = nil) -> WaitForSettleResponse {
        WaitForSettleResponse(settled: false, elapsedMs: elapsedMs, frames: 40, lastChangeRegion: change)
    }

    // MARK: - 段1: 送り先・範囲・窓

    func testSettledPassesAndSendsTheWholeScreenWithTheFrameworkWindow() async throws {
        let driver = steady()
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        let sent = try XCTUnwrap(driver.waitForSettleRequests.first)
        XCTAssertNil(sent.request.region, "範囲の指定が無ければ画面全体(region: nil)")
        XCTAssertEqual(sent.request.quietMs, 800)
        XCTAssertTrue((4000...5000).contains(sent.request.timeoutMs), "\(sent.request.timeoutMs)")
        XCTAssertGreaterThan(sent.timeoutSeconds, Double(sent.request.timeoutMs) / 1000,
                             "HTTP の待ちは要求の上限より長い(時間切れの応答を通信の失敗にしない)")
    }

    func testTransportMarginIsPinned() {
        XCTAssertEqual(StepExecutor.waitForSettleTransportMarginSeconds, 5)
    }

    func testOmittedWaitSecondsFollowsTheScreenWaitTunable() async throws {
        let driver = steady()
        _ = await makeExecutor(driver, tunables: RunTunables(screenWaitTimeout: 7))
            .execute(FlowStep(action: "waitForSettle"))
        let sent = try XCTUnwrap(driver.waitForSettleRequests.first)
        XCTAssertTrue((6500...7000).contains(sent.request.timeoutMs), "\(sent.request.timeoutMs)")
    }

    func testQuietWindowDefaultFollowsTheFrameworkAndPlatform() async throws {
        let table: [(AppUIFramework?, Bool, Int)] = [
            (.compose, false, 800), (nil, false, 800),
            (.swiftUI, false, 500), (.uikit, false, 500), (.reactNative, false, 500), (.flutter, false, 500),
            (.compose, true, 500), (.androidView, true, 500), (nil, true, 500),
        ]
        for (framework, isAndroid, expected) in table {
            let driver = steady()
            _ = await makeExecutor(driver, isAndroid: isAndroid, framework: framework)
                .execute(FlowStep(action: "waitForSettle", timeout: 5))
            XCTAssertEqual(driver.waitForSettleRequests.first?.request.quietMs, expected,
                           "framework=\(String(describing: framework)) android=\(isAndroid)")
        }
    }

    func testQuietSecondsOverridesTheDefault() async throws {
        let driver = steady()
        _ = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5, quietSeconds: 1.2))
        XCTAssertEqual(driver.waitForSettleRequests.first?.request.quietMs, 1200)
    }

    func testRegionIsTheFrameOfTheResolvedElement() async throws {
        let driver = steady()
        let outcome = await makeExecutor(driver).execute(
            FlowStep(action: "waitForSettle", locator: FlowLocator(id: "list"), timeout: 5))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertEqual(driver.waitForSettleRequests.count, 1)
        XCTAssertEqual(driver.waitForSettleRequests.first?.request.region, listFrame)
    }

    /// iOS は常に XCUITest 側で撮る。hybrid で in-app(driver)へ先に送ると、画面全体を撮れず主スレッドも塞ぐ。
    /// 段2の木は driver から取る(次のステップのロケータを解決するほう)
    func testHybridCapturesWithTheTypeDriverAndReadsTheTreeFromTheDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(1, id: "list", frame: listFrame)]])
        let xcuitest = FakeAppDriver(name: "type", log: log,
                                     snapshotElements: [[element(1, id: "list", frame: listFrame)]])
        let outcome = await makeExecutor(primary, typeDriver: xcuitest).execute(
            FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertEqual(xcuitest.waitForSettleRequests.count, 1)
        XCTAssertTrue(primary.waitForSettleRequests.isEmpty, "in-app へ先に送らない")
        XCTAssertGreaterThanOrEqual(primary.snapshotCallCount, 2, "木の追いつきは driver で見る")
        XCTAssertEqual(xcuitest.snapshotCallCount, 0)
    }

    // MARK: - 画面全体を撮れないエンジン

    func testInAppOnlyFailsWithTheSwitchEngineMessageBeforeReadingTheTree() async {
        let driver = steady()
        driver.waitForSettleError = DriverError.badResponse(status: 501, body: "no")
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5))
        let text = message(outcome.status) ?? ""
        XCTAssertTrue(text.contains("whole-screen capture"), text)
        XCTAssertTrue(text.contains("hybrid or xcuitest"), text)
        XCTAssertEqual(driver.snapshotCallCount, 0, "段1で落ちたら木は読まない")
    }

    func testAndroidAndTheTypeDriverRethrowAn501InsteadOfTheIOSAdvice() async {
        let android = steady()
        android.waitForSettleError = DriverError.badResponse(status: 501, body: "no")
        let androidOutcome = await makeExecutor(android, isAndroid: true)
            .execute(FlowStep(action: "waitForSettle", timeout: 5))
        let androidText = message(androidOutcome.status) ?? ""
        XCTAssertTrue(androidText.contains("501"), androidText)
        XCTAssertFalse(androidText.contains("hybrid"), androidText)

        let primary = steady()
        let xcuitest = steady()
        xcuitest.waitForSettleError = DriverError.badResponse(status: 501, body: "no")
        let hybridOutcome = await makeExecutor(primary, typeDriver: xcuitest)
            .execute(FlowStep(action: "waitForSettle", timeout: 5))
        let hybridText = message(hybridOutcome.status) ?? ""
        XCTAssertTrue(hybridText.contains("501"), hybridText)
        XCTAssertFalse(hybridText.contains("hybrid"), hybridText)
    }

    // MARK: - 結末(段1)

    func testStageOneTimeoutFailsWithTheTimeoutKindAndTheLastChange() async {
        let driver = steady()
        driver.waitForSettleResponses = [unsettled(change: FTRect(x: 12, y: 34, width: 56, height: 78))]
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5))
        let text = message(outcome.status) ?? ""
        XCTAssertTrue(text.contains("the screen kept changing for 5s"), text)
        XCTAssertTrue(text.contains("last change at x=12, y=34, 56×78"), text)
        XCTAssertEqual(outcome.failureKind, .timeout)
        XCTAssertEqual(driver.snapshotCallCount, 0, "静止しなかったら段2へ進まない")
    }

    func testStageOneTimeoutWithoutAChangeRegionOmitsTheClause() async {
        let driver = steady()
        driver.waitForSettleResponses = [unsettled()]
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5))
        let text = message(outcome.status) ?? ""
        XCTAssertTrue(text.contains("kept changing"), text)
        XCTAssertFalse(text.contains("last change"), text)
    }

    func testThrowsExceptionFalseGivesUpWithTheNoteAndTheFactInTheReport() async {
        let driver = steady()
        driver.waitForSettleResponses = [unsettled(change: FTRect(x: 1, y: 2, width: 3, height: 4))]
        let outcome = await makeExecutor(driver).execute(
            FlowStep(action: "waitForSettle", timeout: 5, throwsException: false))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.settleNotReached), "\(outcome.notes)")
        XCTAssertTrue(outcome.driverFallback?.contains("the screen kept changing") == true, "\(outcome.driverFallback ?? "nil")")
        XCTAssertNil(outcome.failureKind)
    }

    /// iOS の座標は px÷倍率で割り切れない(183.666…)。小数1桁に丸めて出す(実機の run で生の小数が出ていた)
    func testTheLastChangeRegionIsRoundedToOneDecimal() async {
        let driver = steady()
        driver.waitForSettleResponses = [unsettled(change: FTRect(x: 183.66666666666666, y: 298.3333333333333,
                                                                  width: 34.333333333333336, height: 347.6666666666667))]
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5))
        let text = message(outcome.status) ?? ""
        XCTAssertTrue(text.contains("last change at x=183.7, y=298.3, 34.3×347.7"), text)
    }

    /// 要素を探すのに上限の大半を使い、残りが窓より短かった = 窓に足りる時間を見ていないので「変わり続けた」とは
    /// 言わない(実機の run で「0.1 秒変わり続けた」と出ていた)。残り時間と窓を事実として書く
    func testTooLittleTimeLeftAfterFindingTheElementIsNotCalledChanging() async {
        let driver = steady()
        driver.snapshotDelay = .milliseconds(400)
        driver.waitForSettleResponses = [unsettled(elapsedMs: 100)]
        let outcome = await makeExecutor(driver).execute(
            FlowStep(action: "waitForSettle", locator: FlowLocator(id: "list"), timeout: 0.6, quietSeconds: 0.5))
        let text = message(outcome.status) ?? ""
        XCTAssertTrue(text.contains("was left after finding the element, shorter than quietSeconds (0.5s)"), text)
        XCTAssertFalse(text.contains("kept changing"), text)
    }

    func testAWaitSecondsShorterThanTheWindowIsNamedInTheFailure() async {
        let driver = steady()
        driver.waitForSettleResponses = [unsettled(elapsedMs: 300)]
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 0.3))
        XCTAssertTrue((message(outcome.status) ?? "").contains("shorter than quietSeconds"), "\(outcome.status)")
    }

    // MARK: - 段2: 木が追いつくまで

    func testStageTwoFailsWhenTheTreeKeepsChangingInsideTheRegion() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: drifting(80, frame: listFrame))
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 0.4))
        let text = message(outcome.status) ?? ""
        XCTAssertTrue(text.contains("the screen was still but the accessibility tree kept changing for"), text)
        XCTAssertTrue(text.contains("(changing: #ticker)"), text)
        XCTAssertEqual(outcome.failureKind, .timeout)
    }

    /// 文言に出すのは最大3件(残りは省略記号)。長い一覧を失敗文言に載せない
    func testTheStageTwoFailureNamesAtMostThreeChangingElements() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: (0..<80).map { index in
            (0..<5).map { element($0 + 1, id: "t\($0)", label: "n\(index)", frame: listFrame) }
        })
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 0.4))
        let text = message(outcome.status) ?? ""
        XCTAssertTrue(text.contains("(changing: #t0, #t1, #t2, …)"), text)
    }

    func testStageTwoThrowsExceptionFalseGivesUpWithTheNote() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: drifting(80, frame: listFrame))
        let outcome = await makeExecutor(driver).execute(
            FlowStep(action: "waitForSettle", timeout: 0.4, throwsException: false))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.settleNotReached))
        XCTAssertTrue(outcome.driverFallback?.contains("accessibility tree kept changing") == true)
    }

    /// 連続2枚が一致するまで撮り直す: 4枚目までは毎回違い、5枚目が4枚目と同じ
    func testStageTwoNeedsTwoConsecutiveEqualSnapshots() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: drifting(4, frame: listFrame))
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertEqual(driver.snapshotCallCount, 5)
    }

    func testStageTwoComparesOnlyInsideTheRegion() async {
        let region = FTRect(x: 0, y: 0, width: 100, height: 100)
        func tree(_ index: Int, tickerFrame: FTRect) -> [ElementInfo] {
            [element(1, id: "list", frame: region), element(2, id: "ticker", label: "n\(index)", frame: tickerFrame)]
        }
        // 範囲の外で毎回変わる要素は無視する(通る)
        let outside = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements:
            (0..<80).map { tree($0, tickerFrame: FTRect(x: 200, y: 500, width: 100, height: 50)) })
        let passed = await makeExecutor(outside).execute(
            FlowStep(action: "waitForSettle", locator: FlowLocator(id: "list"), timeout: 5))
        XCTAssertTrue(isPassed(passed.status), "\(passed.status)")
        // 陽性対照: 同じ変化が範囲の中に入れば落ちる
        let inside = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements:
            (0..<80).map { tree($0, tickerFrame: FTRect(x: 10, y: 10, width: 20, height: 20)) })
        let failed = await makeExecutor(inside).execute(
            FlowStep(action: "waitForSettle", locator: FlowLocator(id: "list"), timeout: 0.4))
        XCTAssertTrue((message(failed.status) ?? "").contains("(changing: #ticker)"), "\(failed.status)")
    }

    func testWholeScreenIgnoresElementsOffTheScreen() async {
        let offscreen = FTRect(x: 0, y: 5000, width: 100, height: 50)
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements:
            (0..<80).map { [element(1, id: "list", frame: listFrame),
                            element(2, id: "row", label: "n\($0)", frame: offscreen)] })
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
    }

    func testStageTwoBypassesTheCacheOnlyWhereTheDriverSupportsIt() async {
        let android = steady()
        android.bypassSupported = true
        _ = await makeExecutor(android, isAndroid: true).execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertGreaterThanOrEqual(android.snapshotCallCount, 2)
        XCTAssertEqual(android.bypassedSnapshotCount, android.snapshotCallCount, "段2の読みは全部キャッシュ迂回")

        let ios = steady()
        _ = await makeExecutor(ios).execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertGreaterThanOrEqual(ios.snapshotCallCount, 2)
        XCTAssertEqual(ios.bypassedSnapshotCount, 0)
    }

    /// 木が動きに遅れるエンジン(XCUITest)は読みの間隔を `laggingTreeSettlePeriodMs`(350ms)以上に保つ。
    /// 下限だけ測る(負荷で長くなるのは正しい)
    func testStageTwoKeepsTheLaggingTreePeriod() async {
        let driver = steady()
        driver.treeLags = true
        let clock = ContinuousClock()
        let start = clock.now
        _ = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(300))
    }

    // MARK: - waitSeconds は段1・段2・範囲の解決で共有する

    func testStageTwoGetsOnlyWhatStageOneLeft() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: drifting(80, frame: listFrame))
        driver.waitForSettleDelay = .milliseconds(800)
        let outcome = await makeExecutor(driver).execute(FlowStep(action: "waitForSettle", timeout: 1.0))
        XCTAssertTrue((message(outcome.status) ?? "").contains("accessibility tree kept changing"), "\(outcome.status)")
        // 残り 0.2 秒 = 周期 0.1 秒で 3 枚前後。全体の 1 秒をもう一度使うと 10 枚を超える
        XCTAssertLessThanOrEqual(driver.snapshotCallCount, 5)
    }

    /// ft_batch は waitSeconds 省略時に timeout nil で来る。上限の無い解決は ghost を戻すために容器を送る分岐
    /// (待つだけのコマンドが画面を動かす)と約 0.7 秒の短い探索になるので、入口で既定の上限を持たせる
    func testAMissingWaitSecondsWithARegionGetsTheDefaultLimitBeforeResolving() async throws {
        // 範囲の要素は 6 枚目で出る。上限の無い解決は3回(約 0.7 秒・4 枚)で諦める = ここで落ちれば入口の補完が抜けている
        let driver = FakeAppDriver(name: "primary", log: CallLog(),
                                   snapshotElements: Array(repeating: [], count: 5) + [[element(1, id: "list", frame: listFrame)]])
        let outcome = await makeExecutor(driver).execute(
            FlowStep(action: "waitForSettle", locator: FlowLocator(id: "list")))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        let sent = try XCTUnwrap(driver.waitForSettleRequests.first)
        XCTAssertGreaterThan(sent.request.timeoutMs, 10_000, "既定の上限(screenWaitTimeout = 15 秒)の残りで待つ")
        XCTAssertFalse(driver.log.entries.contains { $0.contains("swipe") || $0.contains("drag") }, "\(driver.log.entries)")
    }

    func testResolvingTheRegionCountsAgainstWaitSeconds() async throws {
        let driver = steady()
        driver.snapshotDelay = .milliseconds(300)
        _ = await makeExecutor(driver).execute(
            FlowStep(action: "waitForSettle", locator: FlowLocator(id: "list"), timeout: 5))
        let sent = try XCTUnwrap(driver.waitForSettleRequests.first)
        XCTAssertLessThan(sent.request.timeoutMs, 4800, "解決に払った 0.3 秒は waitSeconds から引く")
    }

    // MARK: - 範囲の要素が解決できない

    func testUnresolvableRegionFailsEvenWithThrowsExceptionFalse() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        let outcome = await makeExecutor(driver).execute(
            FlowStep(action: "waitForSettle", locator: FlowLocator(id: "missing"), timeout: 0, throwsException: false))
        XCTAssertTrue((message(outcome.status) ?? "").contains("cannot resolve the locator"), "\(outcome.status)")
        XCTAssertEqual(outcome.failureKind, .notFound)
        XCTAssertTrue(driver.waitForSettleRequests.isEmpty, "範囲が決まらなければブリッジへ送らない")
    }

    // MARK: - デバイスに触る前の検査

    func testOutOfRangeArgumentsAreRejectedBeforeAnyDriverCall() async {
        let cases: [(quiet: Double, wait: Double, fragment: String)] = [
            (0.05, 5, "quietSeconds"), (5.5, 5, "quietSeconds"), (.nan, 5, "quietSeconds"),
            (0.5, 120, "waitSeconds"), (0.5, -1, "waitSeconds"), (0.5, .infinity, "waitSeconds"),
        ]
        for (quiet, wait, fragment) in cases {
            let driver = steady()
            let outcome = await makeExecutor(driver).execute(
                FlowStep(action: "waitForSettle", timeout: wait, quietSeconds: quiet))
            XCTAssertTrue((message(outcome.status) ?? "").contains(fragment), "\(quiet) \(wait): \(outcome.status)")
            XCTAssertEqual(driver.log.entries, [], "\(quiet) \(wait): 弾いたステップはドライバへ触れない")
        }
    }

    /// 範囲の要素を指定していても、範囲外の引数は**要素を探す前に**断る(探すと木を撮ってからの失敗になる)。
    /// 範囲なしの形は executeWaitForSettle の中の検査でも止まるので、入口の検査はこの形でしか見えない
    func testOutOfRangeArgumentsAreRejectedBeforeResolvingTheRegion() async {
        let driver = steady()
        let outcome = await makeExecutor(driver).execute(
            FlowStep(action: "waitForSettle", locator: FlowLocator(id: "list_rows"), timeout: 5, quietSeconds: 0.05))
        XCTAssertTrue((message(outcome.status) ?? "").contains("quietSeconds"), "\(outcome.status)")
        XCTAssertEqual(driver.snapshotCallCount, 0, "要素を探す前に断る")
        XCTAssertTrue(driver.waitForSettleRequests.isEmpty)
    }

    func testBoundaryArgumentsAreAccepted() async throws {
        for (quiet, wait) in [(0.1, 0.0), (5.0, 60.0)] {
            let driver = steady()
            let outcome = await makeExecutor(driver).execute(
                FlowStep(action: "waitForSettle", timeout: wait, quietSeconds: quiet))
            XCTAssertTrue(isPassed(outcome.status), "\(quiet) \(wait): \(outcome.status)")
            let sent = try XCTUnwrap(driver.waitForSettleRequests.first)
            XCTAssertEqual(sent.request.quietMs, Int(quiet * 1000))
            XCTAssertLessThanOrEqual(sent.request.timeoutMs, Int(wait * 1000))
        }
    }

    // MARK: - 次のステップへ残す状態

    func testNextResolveBypassesTheCacheAfterEveryOutcome() async {
        let settled = steady()
        let settledExecutor = makeExecutor(settled)
        XCTAssertFalse(settledExecutor.nextResolveBypassesCache)
        _ = await settledExecutor.execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertTrue(settledExecutor.nextResolveBypassesCache)

        let timedOut = steady()
        timedOut.waitForSettleResponses = [unsettled()]
        let timedOutExecutor = makeExecutor(timedOut)
        _ = await timedOutExecutor.execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertTrue(timedOutExecutor.nextResolveBypassesCache)
    }

    /// 待つだけで画面にも焦点にも触れない: `tap → waitForSettle → 検証` で直前のタップの証跡と
    /// `tap → waitForSettle → type` の焦点救済の手がかりを消さない
    func testItKeepsTheLastTapRecordAndTheFocusRescueTarget() async throws {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements:
            [[element(1, id: "ok", frame: listFrame)]])
        let executor = makeExecutor(driver)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "ok")))
        let before = try XCTUnwrap(executor.lastInteraction?.description)
        XCTAssertNotNil(executor.lastTapTarget)
        let outcome = await executor.execute(FlowStep(action: "waitForSettle", timeout: 5))
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertEqual(executor.lastInteraction?.description, before)
        XCTAssertNotNil(executor.lastTapTarget)
    }
}

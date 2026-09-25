// `swipePointToPoint`(DSL・ft_batch 共通の StepExecutor アクション)。撃つのは dragWithFallback だけ
// = in-app の 501 は XCUITest へ回り、座標と秒数はそのまま渡る

import XCTest
@testable import FTCore

final class StepExecutorPointToPointTests: XCTestCase {

    func testPointToPointDragsBetweenTheGivenCoordinates() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "swipePointToPoint", duration: 0.3, x: 200, y: 550, toX: 200, toY: 250)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        let args = try? XCTUnwrap(primary.lastDragArgs)
        XCTAssertEqual(args?.fromX, 200)
        XCTAssertEqual(args?.fromY, 550)
        XCTAssertEqual(args?.toX, 200)
        XCTAssertEqual(args?.toY, 250)
        XCTAssertEqual(args?.durationSeconds, 0.3)
        XCTAssertEqual(args?.pressSeconds, 0.05)
        XCTAssertNil(outcome.driverFallback)
    }

    /// 秒数の既定(duration nil)は 1.5 秒(Shirates の SWIPE_DURATION_SECONDS)
    func testDefaultDurationIsTheSwipeDefault() async {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        _ = await StepExecutor(driver: primary, isAndroid: false)
            .execute(FlowStep(action: "swipePointToPoint", x: 1, y: 2, toX: 3, toY: 4))
        XCTAssertEqual(primary.lastDragArgs?.durationSeconds, 1.5)
    }

    func testEngineIncapableFallsBackToTheTypeDriver() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        primary.dragError = DriverError.badResponse(status: 501, body: "in-app has no drag")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false)

        let outcome = await executor.execute(
            FlowStep(action: "swipePointToPoint", x: 10, y: 20, toX: 30, toY: 40))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(typeDriver.lastDragArgs?.toY, 40)
    }

    /// 秒数の上限は入口の門で断る(デバイスに触らない)
    func testDurationAboveTheCapIsRefusedBeforeTouchingTheDevice() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let outcome = await StepExecutor(driver: primary, isAndroid: false)
            .execute(FlowStep(action: "swipePointToPoint", duration: 11, x: 1, y: 2, toX: 3, toY: 4))
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(log.entries.isEmpty, "\(log.entries)")
    }

    func testMissingEndPointFails() async {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        let outcome = await StepExecutor(driver: primary, isAndroid: false)
            .execute(FlowStep(action: "swipePointToPoint", x: 1, y: 2))
        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("endX"), reason)
        XCTAssertNil(primary.lastDragArgs)
    }
}

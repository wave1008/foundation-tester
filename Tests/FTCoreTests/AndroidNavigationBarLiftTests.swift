// Android のジェスチャナビゲーションバー(木に載らない OS の帯)へ潜ったタップ対象は、
// 撃つ前に容器を送って外す(StepExecutor.liftCoveredTarget の3つ目の覆い。keyboard/overlay と
// 同じ手順を通るが、判定は木ではなく AppDriver.bottomSystemBar(screen:) の申告だけに頼る)。
import XCTest
@testable import FTCore

final class AndroidNavigationBarLiftTests: XCTestCase {

    /// FakeAppDriver の screen は 400x800(StepExecutorTestSupport 参照)
    private static let band = FTRect(x: 0, y: 760, width: 400, height: 40)

    private func container() -> ElementInfo {
        ElementInfo(ref: 1, type: "collectionView", identifier: "list", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 100, width: 400, height: 700), depth: 0, scrollable: true)
    }

    private func row(y: Double) -> ElementInfo {
        ElementInfo(ref: 2, type: "button", identifier: "row_target", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 368, height: 50), depth: 1)
    }

    private func tapStep() -> FlowStep {
        FlowStep(action: "tap", locator: FlowLocator(id: "row_target"))
    }

    /// **帯の内側 (16,750 368x50, 中心 y=775) に潜った行は、まず容器を送ってから撃つ**。
    /// 送った後の木では行が帯の外 (16,600 368x50) へ出ている。注記が帯を名乗り、
    /// 撃つのは動いた後の要素であること
    func testTargetInsideTheNavigationBandIsLiftedBeforeTapping() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container(), row(y: 750)],
            [container(), row(y: 600)],
        ])
        driver.bottomSystemBarValue = Self.band
        let executor = StepExecutor(driver: driver, isAndroid: true)

        let outcome = await executor.execute(tapStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(driver.dragCalls.isEmpty, "帯へ潜っているのに容器を送っていない")
        XCTAssertTrue(outcome.driverFallback?.contains("the system navigation bar") ?? false,
                      "注記が帯を名乗っていない: \(outcome.driverFallback ?? "nil")")
        XCTAssertTrue(log.entries.contains("primary.tap(ref:2)"),
                      "動いた後の要素を撃っているはず: \(log.entries)")
    }

    /// **帯が分からない(nil)ときは送らない** —— 「常に送る」変異が無い限りこのテストは緑のまま
    func testNoBandInformationMeansNoLift() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container(), row(y: 750)],
        ])
        driver.bottomSystemBarValue = nil
        let executor = StepExecutor(driver: driver, isAndroid: true)

        let outcome = await executor.execute(tapStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(driver.dragCalls.isEmpty, "帯が分からないのに容器を送っている")
        XCTAssertTrue(log.entries.contains("primary.tap(ref:2)"))
    }

    /// 帯の外(16,600 368x50, 中心 y=625)に居る対象はそのまま撃つ(誤って送らない)
    func testTargetOutsideTheBandIsTappedDirectly() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container(), row(y: 600)],
        ])
        driver.bottomSystemBarValue = Self.band
        let executor = StepExecutor(driver: driver, isAndroid: true)

        let outcome = await executor.execute(tapStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(driver.dragCalls.isEmpty, "帯の外なのに容器を送っている")
        XCTAssertTrue(log.entries.contains("primary.tap(ref:2)"))
    }
}

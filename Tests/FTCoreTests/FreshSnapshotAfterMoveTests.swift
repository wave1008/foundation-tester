// 直前のステップが画面を動かしたら、次のロケータ操作の解決の 1 枚はキャッシュを迂回して撮る
// (StepExecutor.previousStepMovedContent)。Android の a11y キャッシュはスクロール後に古い座標を
// 返すことがあり、整定(新鮮な木)で止まったと確かめても、続く tap が素取得の古い座標を叩いていた。

import XCTest
@testable import FTCore

final class FreshSnapshotAfterMoveTests: XCTestCase {
    private func button() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "cb_agree", label: "同意", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 300, width: 200, height: 48), depth: 1)
    }

    /// scroll → exist → tap: tap の解決で迂回付きの snapshot が 1 回増える(exist は消費しない)
    func testTapAfterAScrollStepBypassesTheCacheOnce() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[button()]])
        driver.bypassSupported = true
        let executor = StepExecutor(driver: driver, isAndroid: true)

        _ = await executor.execute(FlowStep(action: "scroll", direction: "up", maxSwipes: 1))
        let afterScroll = driver.bypassedSnapshotCount
        XCTAssertGreaterThan(afterScroll, 0, "整定は迂回付きで撮るはず(前提)")
        _ = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "cb_agree"), timeout: 0))
        XCTAssertEqual(driver.bypassedSnapshotCount, afterScroll, "exist は座標を使わないので迂回しない・印も消費しない")

        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "cb_agree")))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.bypassedSnapshotCount, afterScroll + 1, "tap の解決の 1 枚だけ迂回して撮るはず")
        XCTAssertFalse(executor.previousStepMovedContent, "消費したら印は下りるはず")
    }

    /// 直前が動かないステップ(tap → tap)なら迂回しない(通る側の固定費を増やさない)
    func testTapWithoutAPrecedingMoveDoesNotBypass() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[button()]])
        driver.bypassSupported = true
        let executor = StepExecutor(driver: driver, isAndroid: true)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "cb_agree")))
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "cb_agree")))

        XCTAssertEqual(driver.bypassedSnapshotCount, 0, "動かしていないなら素取得のまま")
    }

    /// 迂回を持たないドライバ(iOS in-app / XCUITest)では印が立っても素取得(bypassesCache の真理値表)
    func testDriverWithoutBypassIsUnaffected() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[button()]])
        let executor = StepExecutor(driver: driver, isAndroid: false)

        _ = await executor.execute(FlowStep(action: "scroll", direction: "up", maxSwipes: 1))
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "cb_agree")))

        XCTAssertEqual(driver.bypassedSnapshotCount, 0)
    }
}

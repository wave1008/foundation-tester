// 起動直後の最初のロケータ操作は、配置の静止を待ってから解決する(StepExecutor.pendingLaunchSettle)。
// 実測(E2E-RN の Android・データ消去後の起動): 最初の1枚は上端の余白が無く、直後に全体が 142px 下がる。
// ずれる前の木で解決した `#nav_scroll` の中心が、すぐ上の `#nav_gesture` に当たった。

import XCTest
@testable import FTCore

final class LaunchSettleTests: XCTestCase {

    private func button(ref: Int, id: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 42, y: y, width: 996, height: 126), depth: 1)
    }

    /// ずれる前の配置(余白なし)とずれた後の配置(142px 下)
    private var beforeShift: [ElementInfo] {
        [button(ref: 1, id: "nav_gesture", y: 680), button(ref: 2, id: "nav_scroll", y: 827)]
    }
    private var afterShift: [ElementInfo] {
        [button(ref: 11, id: "nav_gesture", y: 822), button(ref: 12, id: "nav_scroll", y: 969)]
    }

    func testFirstTapAfterLaunchResolvesOnTheSettledLayoutAndNotesIt() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            beforeShift,  // 解決の最初の1枚
            beforeShift,  // settledSignature の初回
            afterShift,   // 動いた
            afterShift,   // 静止
        ])
        let executor = StepExecutor(driver: driver, isAndroid: true)
        executor.noteAppLaunched()
        XCTAssertTrue(executor.pendingLaunchSettle)

        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "nav_scroll")))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(log.entries.contains("primary.tap(ref:12)"), "ずれた後の木の要素を撃つ: \(log.entries)")
        XCTAssertFalse(log.entries.contains("primary.tap(ref:2)"), "ずれる前の座標を撃ってはいけない")
        XCTAssertTrue(outcome.notes.contains(.settledAfterLaunch))
        XCTAssertFalse(executor.pendingLaunchSettle, "消費したら下りる")
    }

    /// 静止した画面では待ちは消費するが注記は付けない。2 回目の操作は待たない(起動1回につき1度だけ)
    func testSettleIsPaidOncePerLaunchAndNotNotedWhenAlreadyStill() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [afterShift])
        let executor = StepExecutor(driver: driver, isAndroid: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "nav_scroll"))

        var before = driver.snapshotCallCount
        _ = await executor.execute(step)
        let plain = driver.snapshotCallCount - before

        executor.noteAppLaunched()
        before = driver.snapshotCallCount
        let first = await executor.execute(step)
        let afterLaunch = driver.snapshotCallCount - before

        before = driver.snapshotCallCount
        _ = await executor.execute(step)
        let second = driver.snapshotCallCount - before

        XCTAssertEqual(afterLaunch, plain + 2, "静止した画面の静止判定は 2 枚")
        XCTAssertEqual(second, plain, "2 回目の操作は待たない")
        XCTAssertFalse(first.notes.contains(.settledAfterLaunch), "既に静止していた回は注記しない")
    }
}

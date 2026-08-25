// **無効な対象は操作可能になるまで待ってから撃つ**(ユーザー決定)。
//
// 受け手の実アプリで、画面が出た直後は入力欄が無効(かつ id を持たない透明な clickable が
// 覆っている)状態のまま叩いており、タップが空振りして**後段のアサーションが落ちて初めて
// 分かる**形になっていた。要素は木に居るので `waitForDisplay` では待ち切れない。
//
// 契約: **待ち切れなくても撃つ**(無効な要素をわざと叩いて「反応しない」ことを確かめる
// 書き方は正当なので失敗にしない)。`&&enabled=` を明示したセレクタでは待たない。

import XCTest
@testable import FTCore

final class TapWaitsForEnabledTests: XCTestCase {

    /// N 回目の snapshot から enabled になるドライバ
    private final class LateEnableDriver: AppDriver, @unchecked Sendable {
        let enabledFrom: Int
        private(set) var snapshotCount = 0
        private(set) var tappedRefs: [Int] = []
        init(enabledFrom: Int) { self.enabledFrom = enabledFrom }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            snapshotCount += 1
            let element = ElementInfo(ref: 1, type: "button", identifier: "btnLogin", label: nil,
                                      value: nil, placeholder: nil,
                                      enabled: snapshotCount >= enabledFrom,
                                      frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: [element], truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tappedRefs.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    /// 待っている最中に割り込みが湧くドライバ(閉じられるまで居座る)
    private final class LateEnableWithModalDriver: AppDriver, @unchecked Sendable {
        let enabledFrom: Int
        let modalFrom: Int
        private var modalClosed = false
        private(set) var snapshotCount = 0
        private(set) var tappedRefs: [Int] = []
        init(enabledFrom: Int, modalFrom: Int) {
            self.enabledFrom = enabledFrom
            self.modalFrom = modalFrom
        }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            snapshotCount += 1
            var elements = [ElementInfo(ref: 1, type: "button", identifier: "btnLogin", label: nil,
                                        value: nil, placeholder: nil,
                                        enabled: snapshotCount >= enabledFrom,
                                        frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)]
            if snapshotCount >= modalFrom, !modalClosed {
                elements.append(ElementInfo(ref: 2, type: "button", identifier: "btn_promo_close",
                                            label: nil, value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 0, y: 200, width: 100, height: 40),
                                            depth: 1))
                elements.append(ElementInfo(ref: 3, type: "other", identifier: "promo_modal",
                                            label: nil, value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 0, y: 100, width: 400, height: 300),
                                            depth: 1))
            }
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {
            tappedRefs.append(ref)
            if ref == 2 { modalClosed = true }
        }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    /// 本命: 有効になってから撃つ(注記も残る)
    func testWaitsUntilTheTargetBecomesEnabled() async throws {
        let driver = LateEnableDriver(enabledFrom: 3)
        let outcome = await StepExecutor(driver: driver).execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btnLogin"), timeout: 3))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.tappedRefs, [1])
        XCTAssertTrue(outcome.notes.contains(.waitedForEnabled), "待ったことを注記に残す")
        XCTAssertFalse((outcome.driverFallback ?? "").contains("is disabled"),
                       "有効になってから撃ったので「無効」の警告は出ない: \(outcome.driverFallback ?? "")")
    }

    /// **待ち切れなくても撃つ**(意図的に無効な要素を叩く書き方を壊さない)
    func testTapsAnywayWhenItNeverBecomesEnabled() async throws {
        let driver = LateEnableDriver(enabledFrom: .max)
        let outcome = await StepExecutor(driver: driver).execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btnLogin"), timeout: 1))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.tappedRefs, [1], "撃たずに終わってはいけない")
        XCTAssertTrue((outcome.driverFallback ?? "").contains("is disabled"),
                      "従来どおり警告は出す: \(outcome.driverFallback ?? "")")
    }

    /// **待っている間に湧いた割り込みは閉じる**。待ちは「撃つまでの時間」を伸ばすので、
    /// 閉じないと**モーダルが被さる窓を自分で広げる**(有効になった瞬間に覆いの上を撃つ)
    func testDismissesInterruptionsWhileWaiting() async throws {
        let driver = LateEnableWithModalDriver(enabledFrom: 3, modalFrom: 2)
        let executor = StepExecutor(driver: driver)
        executor.interruptHandlers = [
            StepExecutor.InterruptHandler(detect: FlowLocator(id: "promo_modal"),
                                          dismiss: FlowLocator(id: "btn_promo_close")),
        ]

        let outcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btnLogin"), timeout: 3))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(driver.tappedRefs.contains(2), "待っている間の割り込みを閉じていない")
        XCTAssertEqual(driver.tappedRefs.last, 1, "最後に本命を撃つこと")
    }

    /// 最初から有効なら待たない(正常系のコストを増やさない)
    func testDoesNotWaitWhenAlreadyEnabled() async throws {
        let driver = LateEnableDriver(enabledFrom: 1)
        let outcome = await StepExecutor(driver: driver).execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btnLogin"), timeout: 3))

        XCTAssertEqual(driver.tappedRefs, [1])
        XCTAssertFalse(outcome.notes.contains(.waitedForEnabled))
        XCTAssertLessThanOrEqual(driver.snapshotCount, 2, "余分に読まない")
    }

    /// **`&&enabled=false` は「無効なものを狙う」宣言**なので待たない(予算を捨てない)
    func testDoesNotWaitWhenTheSelectorAsksForDisabled() async throws {
        let driver = LateEnableDriver(enabledFrom: .max)
        var locator = FlowLocator(id: "btnLogin")
        locator.enabled = false
        let outcome = await StepExecutor(driver: driver).execute(
            FlowStep(action: "tap", locator: locator, timeout: 3))

        XCTAssertEqual(driver.tappedRefs, [1])
        XCTAssertFalse(outcome.notes.contains(.waitedForEnabled))
        XCTAssertLessThanOrEqual(driver.snapshotCount, 2, "待たずに撃つこと(予算を捨てない)")
    }
}

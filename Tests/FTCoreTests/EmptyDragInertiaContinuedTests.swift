// 探索の終わりの空打ちの後も対象が流れ続けた回は、止まった位置へもう1回だけ空打ちしてから返す。一覧の末尾を越えて引っ張られた
// まま止まった Compose の一覧は、次のタッチで引っ張りが解けて元へ戻り、そのタッチはクリックにならない(E2EX-CMP の無限スクロール・
// XCUITest: 整定で 414 に止まった行が撃った瞬間に +247pt 戻った)。緑の回は空打ちの後に動かない = 1回のまま

import XCTest
@testable import FTCore

/// 払う前は対象が木に無い。払った後は `found`、空打ち1回目の後は `afterFirst` を順に(尽きたら最後を繰り返す)、
/// 2回目の後は `afterSecond` に居る
private final class InertiaAfterEmptyDragDriver: AppDriver {
    let found: Double
    let afterFirst: [Double]
    let afterSecond: Double
    private(set) var swiped = false
    private(set) var dragStartY: [Double] = []
    private var snapsSinceDrag = 0

    init(found: Double, afterFirst: [Double], afterSecond: Double) {
        self.found = found
        self.afterFirst = afterFirst
        self.afterSecond = afterSecond
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swiped = true }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws { swiped = true }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        dragStartY.append(fromY)
        snapsSinceDrag = 0
    }

    func snapshot() async throws -> SnapshotResponse {
        var elements = [
            ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1),
        ]
        if swiped {
            let y: Double
            switch dragStartY.count {
            case 0: y = found
            case 1: y = afterFirst[min(snapsSinceDrag, afterFirst.count - 1)]
            default: y = afterSecond
            }
            snapsSinceDrag += 1
            elements.append(ElementInfo(ref: 2, type: "button", identifier: "target", label: "対象", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 2))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class EmptyDragInertiaContinuedTests: XCTestCase {
    private func run(_ driver: InertiaAfterEmptyDragDriver) async -> StepOutcome {
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"), direction: "up", maxSwipes: 3)
        return await StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false, tunables: RunTunables(),
                                  uiFramework: .compose).execute(step)
    }

    func testListThatKeptMovingAfterTheEmptyDragGetsOneMoreAtWhereItStopped() async {
        let driver = InertiaAfterEmptyDragDriver(found: 600, afterFirst: [450, 420, 414, 414], afterSecond: 661)
        let outcome = await run(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.dragStartY.count, 2, "\(driver.dragStartY)")
        XCTAssertEqual(driver.dragStartY.first ?? 0, 628, accuracy: 1, "1回目は見つけた位置(600 + 56/2)")
        XCTAssertEqual(driver.dragStartY.last ?? 0, 442, accuracy: 1, "2回目は止まった位置(414 + 56/2)を撮り直して押す")
    }

    /// 対照: 空打ちの後に動かない一覧(緑の回の形)は1回のまま
    func testListThatStayedPutGetsOnlyOneEmptyDrag() async {
        let driver = InertiaAfterEmptyDragDriver(found: 600, afterFirst: [600], afterSecond: 600)
        let outcome = await run(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.dragStartY.count, 1, "\(driver.dragStartY)")
    }
}

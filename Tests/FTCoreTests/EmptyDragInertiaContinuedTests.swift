// 探索の終わりの空打ちの後も、探索の向きへ空打ちの移動距離を超えて流れ続けた回だけ、止まった位置へもう1回空打ちする
// (E2EX-CMP の無限スクロール・XCUITest。形と件数は StepExecutor.settleAfterFind)。空打ち自身の送り・逆向きの戻り・
// 横へ抜けた空打ちでは1回のまま(空打ち自身の送りで2回目を撃った版は赤を悪化させた)

import XCTest
@testable import FTCore

/// 払う前は対象が木に無い。払った後は `found`、空打ち1回目の後は `afterFirst` を順に(尽きたら最後を繰り返す)、
/// 2回目の後は `afterSecond` に居る
private final class InertiaAfterEmptyDragDriver: AppDriver {
    let found: Double
    let afterFirst: [Double]
    let afterSecond: Double
    let rowX: Double
    let rowWidth: Double
    private(set) var swiped = false
    private(set) var drags: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] = []
    private var snapsSinceDrag = 0

    init(found: Double, afterFirst: [Double], afterSecond: Double, rowX: Double = 0, rowWidth: Double = 402) {
        self.found = found
        self.afterFirst = afterFirst
        self.afterSecond = afterSecond
        self.rowX = rowX
        self.rowWidth = rowWidth
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
        drags.append((fromX, fromY, toX, toY))
        snapsSinceDrag = 0
    }

    func snapshot() async throws -> SnapshotResponse {
        var elements = [
            ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1),
        ]
        if swiped {
            let y: Double
            switch drags.count {
            case 0: y = found
            case 1: y = afterFirst[min(snapsSinceDrag, afterFirst.count - 1)]
            default: y = afterSecond
            }
            snapsSinceDrag += 1
            elements.append(ElementInfo(ref: 2, type: "button", identifier: "target", label: "対象", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: rowX, y: y, width: rowWidth, height: 56), depth: 2))
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

    /// 赤の回の形: 全幅の行(縦に 32pt 抜く空打ち)の後に 600 → 414 まで流れた
    func testListThatKeptFlowingAfterTheEmptyDragGetsOneMoreAtWhereItStopped() async {
        let driver = InertiaAfterEmptyDragDriver(found: 600, afterFirst: [450, 420, 414, 414], afterSecond: 661)
        let outcome = await run(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.drags.count, 2, "\(driver.drags)")
        XCTAssertEqual(driver.drags.first?.fromY ?? 0, 628, accuracy: 1, "1回目は見つけた位置(600 + 56/2)")
        XCTAssertEqual(driver.drags.last?.fromY ?? 0, 442, accuracy: 1, "2回目は止まった位置(414 + 56/2)を撮り直して押す")
    }

    /// 対照: 空打ちの後に動かない一覧は1回のまま
    func testListThatStayedPutGetsOnlyOneEmptyDrag() async {
        let driver = InertiaAfterEmptyDragDriver(found: 600, afterFirst: [600], afterSecond: 600)
        let outcome = await run(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.drags.count, 1, "\(driver.drags)")
    }

    /// 対照: 空打ち自身の送り(32pt の空打ちで 22pt。616 → 594 の実測)は流れ続けではない
    func testEmptyDragsOwnScrollGetsOnlyOneEmptyDrag() async {
        let driver = InertiaAfterEmptyDragDriver(found: 616, afterFirst: [594, 594], afterSecond: 572)
        let outcome = await run(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.drags.count, 1, "\(driver.drags)")
    }

    /// 対照: 逆向きに大きく戻った(524 → 665 の実測・緑の回)は流れ続けではない
    func testSnapBackAgainstTheSearchGetsOnlyOneEmptyDrag() async {
        let driver = InertiaAfterEmptyDragDriver(found: 524, afterFirst: [665, 665], afterSecond: 665)
        let outcome = await run(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.drags.count, 1, "\(driver.drags)")
    }

    /// 対照: 横へ抜けた空打ち(全幅でない行)は移動距離が測れないので1回のまま
    func testSidewaysEmptyDragGetsOnlyOneEvenIfTheListFlowed() async {
        let driver = InertiaAfterEmptyDragDriver(found: 600, afterFirst: [450, 414, 414], afterSecond: 661,
                                                 rowX: 16, rowWidth: 370)
        let outcome = await run(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.drags.count, 1, "\(driver.drags)")
        XCTAssertEqual(driver.drags.first?.toY ?? 0, driver.drags.first?.fromY ?? -1, "横へ抜けている")
    }

    /// 境目は空打ちの探索軸上の移動距離ちょうど(超えたら流れ続け)。向きは指の向き
    func testBoundaryIsTheEmptyDragTravelAlongTheSearchAxis() {
        let before = FTRect(x: 0, y: 600, width: 402, height: 56)
        func flowed(toY: Double, finger: FTSwipeDirection, movingPolls: Int = 2) -> Bool {
            StepExecutor.keptFlowingAfterEmptyDrag(before: before, after: FTRect(x: 0, y: toY, width: 402, height: 56),
                                                   movingPolls: movingPolls,
                                                   dragFrom: (201, 628), dragTo: (201, 596), finger: finger)
        }
        XCTAssertFalse(flowed(toY: 568, finger: .up), "32pt ちょうどは空打ち自身で起こせる")
        XCTAssertTrue(flowed(toY: 567, finger: .up))
        XCTAssertFalse(flowed(toY: 900, finger: .up), "逆向き")
        XCTAssertTrue(flowed(toY: 633, finger: .down))
        XCTAssertFalse(flowed(toY: 400, finger: .up, movingPolls: 1), "1周で跳んで止まった段差は流れ続けではない")
    }

    /// 対照: バーが隠れる段差(525 → 358 と1周で跳んで止まる実測の形)は1回のまま。2回目を撃つと指が下へ動いて
    /// バーが戻り、次の払いで行が画面の外へ出た(E2EY-CMP の隠れるバー 24 回中 23 回)
    func testOnePollLayoutJumpGetsOnlyOneEmptyDrag() async {
        let driver = InertiaAfterEmptyDragDriver(found: 525, afterFirst: [358, 358], afterSecond: 380)
        let outcome = await run(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.drags.count, 1, "\(driver.drags)")
    }
}

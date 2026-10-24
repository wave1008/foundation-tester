// runScrollSearch が、**進む先の縁に付いた要素**(枠が見えている部分へ切り詰められた形)を見つけたとき、
// 同じ向きへ1回だけ送り直してから見つかったとすることを固定する。
// 実測: Android の Flutter で E2EY-Flutter の #card_0_14 が右端に 18px だけ出た所で見つかったとし、
// その中心 = 右端の戻るの帯を撃って飲まれた(並列で 5/5)

import XCTest
@testable import FTCore

/// **送った本数**で台本の次の木へ進む(尽きたら最後を繰り返す)。探索の1周目は静止を待って木を2回撮るので、
/// 撮るたびに進めると送る前に次の絵を読んでしまう。画面は Pixel 9 の 1080x2424
private final class ScriptedShelfDriver: AppDriver {
    private let scripted: [[ElementInfo]]
    private(set) var swipeCount = 0

    init(scripted: [[ElementInfo]]) { self.scripted = scripted }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
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
    func swipe(_ direction: FTSwipeDirection) async throws { swipeCount += 1 }
    /// 送り直しは遅いドラッグ(slowDrag)= drag で来る。台本を進めるのは払いと同じ
    private(set) var dragCount = 0
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        dragCount += 1
        swipeCount += 1
    }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipeCount += 1
    }
    func snapshot() async throws -> SnapshotResponse {
        let elements = scripted[min(swipeCount, scripted.count - 1)]
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                                elements: elements, truncatedCount: 0)
    }
}

final class ScrollSearchLeadingEdgeTests: XCTestCase {

    private func shelf() -> ElementInfo {
        ElementInfo(ref: 1, type: "scrollView", identifier: "shelf_0", label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 512, width: 1080, height: 315), depth: 1, scrollable: true)
    }

    private func card(_ ref: Int, _ id: String, x: Double, width: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: 512, width: width, height: 315), depth: 2)
    }

    private func search(_ driver: ScriptedShelfDriver) async -> StepOutcome {
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "card_0_14"), direction: "left", maxSwipes: 8)
        step.scrollFrame = FlowLocator(id: "shelf_0")
        return await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(step)
    }

    /// 右端に 18px だけ出た(枠が切り詰められた)カード → 1回送り、全体が見えてから見つかったとする
    func testSliverAtTheLeadingEdgeIsSwipedOnceMoreBeforeItCounts() async {
        let sliver = [shelf(), card(2, "card_0_13", x: 694, width: 368), card(3, "card_0_14", x: 1062, width: 18)]
        let visible = [shelf(), card(3, "card_0_14", x: 500, width: 368)]
        let driver = ScriptedShelfDriver(scripted: [sliver, visible])
        let outcome = await search(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.swipeCount, 1)
        XCTAssertEqual(driver.dragCount, 1, "探索の払い(慣性が出る)ではなく遅いドラッグで送ること")
    }

    /// 送っても縁に付いたまま(細いまま動かない)なら、それ以上は送らずに見つかったとする(往復しない)
    func testFlushElementThatDoesNotMoveCountsAfterOneNudge() async {
        let atEnd = [shelf(), card(3, "card_0_14", x: 1060, width: 20)]
        let driver = ScriptedShelfDriver(scripted: [atEnd])
        let outcome = await search(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.swipeCount, 1)
    }

    /// 縁に付いていても、指で押せる大きさ(44pt/dp)以上見えていれば送らない(RN の XCUITest の 140pt のカード)
    func testWideElementAtTheLeadingEdgeIsNotNudged() async {
        let driver = ScriptedShelfDriver(scripted: [[shelf(), card(3, "card_0_14", x: 712, width: 368)]])
        let outcome = await search(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.swipeCount, 0)
        XCTAssertEqual(StepExecutor.leadingEdgeNudgeMinVisiblePt, 44)
    }

    /// 縁から離れていれば送らない
    func testElementAwayFromTheLeadingEdgeIsNotNudged() async {
        let driver = ScriptedShelfDriver(scripted: [[shelf(), card(3, "card_0_14", x: 300, width: 368)]])
        let outcome = await search(driver)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.swipeCount, 0)
    }

    func testNudgeRatioIsPinned() {
        XCTAssertEqual(StepExecutor.leadingEdgeNudgeRatio, 0.5)
    }

    func testTouchesLeadingEdgeByFingerDirection() {
        let viewport = FTRect(x: 0, y: 100, width: 400, height: 600)
        XCTAssertTrue(ScrollGeometry.touchesLeadingEdge(FTRect(x: 380, y: 200, width: 20, height: 50),
                                                         viewport: viewport, finger: .left))
        XCTAssertFalse(ScrollGeometry.touchesLeadingEdge(FTRect(x: 380, y: 200, width: 20, height: 50),
                                                          viewport: viewport, finger: .right))
        XCTAssertTrue(ScrollGeometry.touchesLeadingEdge(FTRect(x: 0, y: 200, width: 20, height: 50),
                                                         viewport: viewport, finger: .right))
        XCTAssertTrue(ScrollGeometry.touchesLeadingEdge(FTRect(x: 0, y: 690, width: 400, height: 10),
                                                         viewport: viewport, finger: .up))
        XCTAssertTrue(ScrollGeometry.touchesLeadingEdge(FTRect(x: 0, y: 100, width: 400, height: 10),
                                                         viewport: viewport, finger: .down))
        // 容器以上の大きさは縁に付くのが当然
        XCTAssertFalse(ScrollGeometry.touchesLeadingEdge(FTRect(x: 0, y: 100, width: 400, height: 600),
                                                          viewport: viewport, finger: .up))
    }
}

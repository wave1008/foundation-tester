// 「容器の縁に切られた対象は、送っても y が変わらず height だけ伸びる」形の固定
// (liftCoveredTarget が y だけを見て 1 回で諦めていたバグ)。貼り付く見出しの下に潜った行を
// 1 回送ると、まず高さだけが伸びて(まだ見出しの下)、もう 1 回送って初めて見出しの外へ出る
// 実測(RN Android)を再現する。
import XCTest
@testable import FTCore

/// ドラッグの**実行回数**でスナップショットを進める最小 AppDriver スタブ。snapshot() の呼び出し
/// 回数では駄目 —— liftCoveredTarget は解決・診断のために何度も撮り直すので、実際に送った回数
/// (drag call count)だけを進行の目印にしないと「1 回送った後の絵」を狙って返せない
final class DragCountedDriver: AppDriver {
    private let statesByDragCount: [[ElementInfo]]
    private let screen: FTRect
    private(set) var dragCallCount = 0
    private(set) var tapRefs: [Int] = []
    /// tap(ref:) が撃った時点の対象の中心(ブリッジが ref を frame の中心へ解決する挙動の模写)
    private(set) var lastTapCentre: (x: Double, y: Double)?

    init(screen: FTRect, statesByDragCount: [[ElementInfo]]) {
        self.screen = screen
        self.statesByDragCount = statesByDragCount
    }

    private var currentElements: [ElementInfo] {
        statesByDragCount[min(dragCallCount, statesByDragCount.count - 1)]
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}

    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: currentElements,
                         truncatedCount: 0, keyboardShown: nil, keyboardFrame: nil,
                         overlayWindowFrames: nil)
    }

    func tap(ref: Int) async throws {
        tapRefs.append(ref)
        if let element = currentElements.first(where: { $0.ref == ref }) {
            lastTapCentre = (element.frame.centerX, element.frame.centerY)
        }
    }

    func tap(x: Double, y: Double) async throws { lastTapCentre = (x, y) }
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        dragCallCount += 1
    }
}

final class LiftClippedTargetTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)
    private let container = FTRect(x: 42, y: 403, width: 996, height: 1979)

    private let clippedByTop = FTRect(x: 84, y: 403, width: 912, height: 40)
    /// 1 回送った直後: y は容器の縁(見出しの下端)に張り付いたまま、高さだけ伸びる。
    /// 中心 (457) はまだ見出し (403..499) の下
    private let heightGrownStillCovered = FTRect(x: 84, y: 403, width: 912, height: 109)
    /// 2 回送って初めて見出しの外(下端 499)へ出る
    private let liftedClear = FTRect(x: 84, y: 520, width: 912, height: 116)

    /// scrollView(容器)・貼り付く見出し・行3件。**見出しの ref は行より大きくする**
    /// (`PaintOrder.drawnAbove` は z が無ければ ref の大小で塗り順を決める。実測の RN Android の
    /// witness でも見出しは行より後に塗られる = ref が大きい)
    private func scene(rowFrame: FTRect) -> [ElementInfo] {
        let scrollView = ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil,
                                     value: nil, placeholder: nil, enabled: true,
                                     frame: container, depth: 1, scrollable: true)
        let header = ElementInfo(ref: 99, type: "staticText", identifier: "hdr_B", label: "セクション B",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 42, y: 403, width: 996, height: 96), depth: 2)
        let row1 = ElementInfo(ref: 10, type: "button", identifier: "row_s_B1", label: "行 B1",
                               value: nil, placeholder: nil, enabled: true, frame: rowFrame, depth: 2)
        let row2 = ElementInfo(ref: 11, type: "button", identifier: "row_s_B2", label: "行 B2",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 84, y: 600, width: 912, height: 80), depth: 2)
        let row3 = ElementInfo(ref: 12, type: "button", identifier: "row_s_B3", label: "行 B3",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 84, y: 690, width: 912, height: 80), depth: 2)
        return [scrollView, header, row1, row2, row3]
    }

    /// 1 回目は高さだけが変わる → y だけの比較なら「動いていない」と誤って諦めていたはずの形。
    /// 2 回目で見出しの外に出て初めて撃つ
    func testSecondLiftRunsWhenOnlyTheHeightChanged() async throws {
        let driver = DragCountedDriver(screen: screen, statesByDragCount: [
            scene(rowFrame: clippedByTop),
            scene(rowFrame: heightGrownStillCovered),
            scene(rowFrame: liftedClear),
        ])
        let executor = StepExecutor(driver: driver, isAndroid: true)

        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_s_B1")))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertGreaterThanOrEqual(driver.dragCallCount, 2,
                                    "高さだけ変わった1回目で諦めてはいけない")
        XCTAssertTrue(outcome.driverFallback?.contains(
            "scrolled the container to bring the target out from under") == true,
            outcome.driverFallback ?? "(注記なし)")
        XCTAssertGreaterThan(driver.lastTapCentre?.y ?? 0, 499,
                             "見出しの下端(499)より下を撃つはず")
    }

    /// 送っても本当に何も動かない(y も height も不変)なら 1 回で諦め、無警告のまま撃たない
    func testGivesUpWhenNothingMoves() async throws {
        let driver = DragCountedDriver(screen: screen,
                                       statesByDragCount: [scene(rowFrame: clippedByTop)])
        let executor = StepExecutor(driver: driver, isAndroid: true)

        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_s_B1")))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.dragCallCount, 1, "動かないなら1回で諦めるはず(撃ち続けない)")
        XCTAssertTrue(outcome.driverFallback?.contains("centre is covered by") == true,
                     outcome.driverFallback ?? "(注記なし)")
    }
}

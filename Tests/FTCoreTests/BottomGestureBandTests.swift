// Android の下端ジェスチャ帯(ホーム・アプリ切替)を避ける配線と、横の探索の枠を窓へ入れる判定

import XCTest
@testable import FTCore

final class BottomGestureBandTests: XCTestCase {

    private func element(_ ref: Int, _ id: String, _ frame: FTRect, scrollable: Bool = false) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: scrollable ? "scroll" : "button", identifier: id, label: nil,
                            value: nil, placeholder: nil, enabled: true, frame: frame, depth: 0)
        if scrollable { e.scrollable = true }
        return e
    }

    // MARK: - parse

    private static let gestureNav = """
          EdgeBackGestureHandler:
            mIsGestureHandlingEnabled=true
            mEdgeWidthLeft=78
            mEdgeWidthRight=78
          mLastReportedConfig=
        """

    /// 下端は mBottomGestureHeight が読めればその値、読めなければ呼び手のフォールバック。3ボタンは 0
    func testBottomBandUsesReportedHeightThenFallbackAndIsZeroForThreeButton() {
        let withHeight = """
              EdgeBackGestureHandler:
                mIsGestureHandlingEnabled=true
                mEdgeWidthLeft=78
                mEdgeWidthRight=78
                mBottomGestureHeight=63
            """
        XCTAssertEqual(AndroidBackGestureEdges.parse(withHeight, bottomFallback: 126)?.bottom, 63)
        XCTAssertEqual(AndroidBackGestureEdges.parse(Self.gestureNav, bottomFallback: 126)?.bottom, 126)
        let threeButton = Self.gestureNav.replacingOccurrences(of: "mIsGestureHandlingEnabled=true",
                                                               with: "mIsGestureHandlingEnabled=false")
        XCTAssertEqual(AndroidBackGestureEdges.parse(threeButton, bottomFallback: 126)?.bottom, 0)
    }

    // MARK: - ScrollGeometry

    func testClearingBottomGestureBandMovesOnlyStartsInsideTheBand() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let inside = ScrollGeometry.clearingBottomGestureBand(y: 790, viewport: screen, bottom: 100)
        XCTAssertTrue(inside.moved)
        XCTAssertLessThan(inside.y, 700)
        let outside = ScrollGeometry.clearingBottomGestureBand(y: 650, viewport: screen, bottom: 100)
        XCTAssertFalse(outside.moved)
        XCTAssertEqual(outside.y, 650)
        XCTAssertFalse(ScrollGeometry.clearingBottomGestureBand(y: 790, viewport: screen, bottom: 0).moved)
    }

    func testPanPathKeepsBothEndsAboveTheBottomBand() throws {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let path = try XCTUnwrap(ScrollGeometry.panPath(container: screen, viewport: screen,
                                                        dxRatio: 0, dyRatio: -0.9,
                                                        backGestureEdgeWidths: (0, 0, 100)))
        XCTAssertLessThanOrEqual(max(path.fromY, path.toY), 700)
    }

    /// E2EY-iOS の #shelf_9 の形: 高さ 120 のうち 47 だけ見える横の一覧 → 外側の縦の容器を送る
    func testBringIntoViewPicksTheEnclosingVerticalContainerForAMostlyOffscreenFrame() throws {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let shelf = FTRect(x: 0, y: 827, width: 402, height: 120)
        let outer = element(1, "outer", FTRect(x: 0, y: 100, width: 402, height: 900), scrollable: true)
        let inner = element(2, "shelf", shelf, scrollable: true)
        let reach = try XCTUnwrap(ScrollGeometry.bringIntoView(frame: shelf, screen: screen,
                                                               elements: [outer, inner]))
        XCTAssertEqual(reach.outer.height, 774)  // 画面と交差させた外側
        XCTAssertGreaterThan(reach.jump, 0)      // 枠が下 = 指を上へ
    }

    func testBringIntoViewIsNilWhenVisibleEnoughOrNoEnclosingContainer() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let outer = element(1, "outer", FTRect(x: 0, y: 100, width: 402, height: 900), scrollable: true)
        let visible = FTRect(x: 0, y: 500, width: 402, height: 120)
        XCTAssertNil(ScrollGeometry.bringIntoView(frame: visible, screen: screen, elements: [outer]))
        let shelf = FTRect(x: 0, y: 827, width: 402, height: 120)
        XCTAssertNil(ScrollGeometry.bringIntoView(frame: shelf, screen: screen,
                                                  elements: [element(2, "shelf", shelf, scrollable: true)]))
    }

    // MARK: - StepExecutor(画面は FakeAppDriver の 400x800)

    func testPointToPointStartInsideTheBottomGestureBandIsMovedAboveIt() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        primary.backGestureEdgeWidthsValue = (left: 78, right: 78, bottom: 100)
        let outcome = await StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "swipePointToPoint", x: 200, y: 780, toX: 200, toY: 300))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        let args = try XCTUnwrap(primary.lastDragArgs)
        XCTAssertLessThan(args.fromY, 700)
        XCTAssertEqual(args.toY, 300)
        XCTAssertTrue(outcome.driverFallback?.contains("bottom gesture band") == true,
                      "\(String(describing: outcome.driverFallback))")
    }

    func testPointToPointStartOutsideTheBandIsUntouched() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        primary.backGestureEdgeWidthsValue = (left: 78, right: 78, bottom: 100)
        let outcome = await StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "swipePointToPoint", x: 200, y: 600, toX: 200, toY: 300))
        XCTAssertEqual(primary.lastDragArgs?.fromY, 600)
        XCTAssertNil(outcome.driverFallback)
    }

    /// E2EY の画面最下端のミニプレーヤーから上へ払う形
    func testSwipeElementToElementStartInsideTheBottomBandIsMovedAboveIt() async throws {
        let from = element(1, "mini", FTRect(x: 0, y: 700, width: 400, height: 100))
        let to = element(2, "state", FTRect(x: 0, y: 100, width: 400, height: 40))
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[from, to]])
        primary.backGestureEdgeWidthsValue = (left: 78, right: 78, bottom: 100)
        let outcome = await StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "mini"),
                              endLocator: FlowLocator(id: "state")))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        let args = try XCTUnwrap(primary.lastDragArgs)
        XCTAssertLessThan(args.fromY, 700)
        XCTAssertEqual(args.toY, 120)
    }
}

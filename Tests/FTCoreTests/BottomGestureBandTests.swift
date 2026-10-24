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

    /// 帯は [上端, 画面下端) = 上端ちょうども帯の中(実測: 帯 84px・y=2340 の押下がランチャーに取られた)
    func testClearingBottomGestureBandTreatsTheBandTopAsInside() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let onEdge = ScrollGeometry.clearingBottomGestureBand(y: 700, viewport: screen, bottom: 100)
        XCTAssertTrue(onEdge.moved)
        XCTAssertEqual(onEdge.y, 699)
        XCTAssertFalse(ScrollGeometry.clearingBottomGestureBand(y: 699, viewport: screen, bottom: 100).moved)
    }

    /// E2EY-Flutter の #txt_mini_title(42,2312 849x56)・帯 84px(2340〜2424)の実寸
    func testTapYMovesTheMiniPlayerTitleIntoItsPartAboveTheBand() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)
        let title = FTRect(x: 42, y: 2312, width: 849, height: 56)
        XCTAssertEqual(ScrollGeometry.tapYClearingBottomGestureBand(frame: title, viewport: screen, bottom: 84), 2326)
    }

    func testTapYIsNilWhenTheCentreIsAboveTheBandOrNothingIsAboveItOrNoBand() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertNil(ScrollGeometry.tapYClearingBottomGestureBand(
            frame: FTRect(x: 0, y: 600, width: 400, height: 60), viewport: screen, bottom: 100))
        XCTAssertNil(ScrollGeometry.tapYClearingBottomGestureBand(
            frame: FTRect(x: 0, y: 710, width: 400, height: 60), viewport: screen, bottom: 100))
        XCTAssertNil(ScrollGeometry.tapYClearingBottomGestureBand(
            frame: FTRect(x: 0, y: 680, width: 400, height: 40), viewport: screen, bottom: 0))
    }

    /// Pixel 9 の密度(2.625)= 帯の上限の見積り 48dp は 126px。画面は 400x800 なので 674 より下の中心だけ帯を問い合わせる
    private func bandDriver(_ elements: [ElementInfo]) -> FakeAppDriver {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [elements])
        driver.backGestureEdgeWidthsValue = (left: 78, right: 78, bottom: 100)
        driver.pointScaleValue = 2.625
        return driver
    }

    /// 中心が下端の 48dp より上の要素では帯を問い合わせない(dumpsys を払わない)
    func testTapFarAboveTheBottomDoesNotQueryTheBand() async throws {
        let primary = bandDriver([element(1, "row", FTRect(x: 0, y: 300, width: 400, height: 40))])
        _ = await StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row")))
        XCTAssertEqual(primary.backGestureEdgeWidthsCalls, 0)
        XCTAssertTrue(primary.log.entries.contains("primary.tap(ref:1)"), "\(primary.log.entries)")
    }

    /// 判定そのもの(MCP・ライブ操作が直接呼ぶ口)
    func testSharedTapYRespectsPlatformAndThePrefilter() async {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let mini = FTRect(x: 0, y: 680, width: 400, height: 40)
        let driver = bandDriver([])
        let y = await BottomGestureBandTap.tapY(for: mini, screen: screen, isAndroid: true, driver: driver)
        XCTAssertEqual(y, 690)
        let ios = await BottomGestureBandTap.tapY(for: mini, screen: screen, isAndroid: false, driver: driver)
        XCTAssertNil(ios)
        XCTAssertEqual(BottomGestureBandTap.maxBandHeightDp, 48)
    }

    func testTapOnAnElementWhoseCentreIsInTheBandTouchesItsPartAboveTheBand() async throws {
        let primary = bandDriver([element(1, "mini", FTRect(x: 0, y: 680, width: 400, height: 40))])
        let outcome = await StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "mini")))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(primary.coordinateTaps.map(\.y), [690])
        XCTAssertFalse(primary.log.entries.contains { $0.contains("tap(ref:") }, "\(primary.log.entries)")
        XCTAssertTrue(outcome.driverFallback?.contains("above the Android bottom gesture band") == true,
                      "\(String(describing: outcome.driverFallback))")
    }

    func testTapAboveTheBandStaysOnTheRefAndIOSIsUntouched() async throws {
        let primary = bandDriver([element(1, "row", FTRect(x: 0, y: 600, width: 400, height: 40))])
        _ = await StepExecutor(driver: primary, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row")))
        XCTAssertTrue(primary.coordinateTaps.isEmpty)
        XCTAssertTrue(primary.log.entries.contains("primary.tap(ref:1)"), "\(primary.log.entries)")
        let ios = bandDriver([element(1, "mini", FTRect(x: 0, y: 680, width: 400, height: 40))])
        _ = await StepExecutor(driver: ios, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "mini")))
        XCTAssertTrue(ios.coordinateTaps.isEmpty)
    }

    func testLongPressAndDoubleTapInTheBandTouchAboveIt() async throws {
        let mini = element(1, "mini", FTRect(x: 0, y: 680, width: 400, height: 40))
        let pressing = bandDriver([mini])
        pressing.acceptsCoordinatePress = true
        _ = await StepExecutor(driver: pressing, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "mini"), duration: 0.5))
        XCTAssertEqual(pressing.lastCoordinatePress?.y, 690)
        let doubling = bandDriver([mini])
        let outcome = await StepExecutor(driver: doubling, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "doubleTap", locator: FlowLocator(id: "mini")))
        XCTAssertEqual(doubling.lastDoubleTap?.y, 690)
        XCTAssertTrue(outcome.driverFallback?.contains("above the Android bottom gesture band") == true,
                      "\(String(describing: outcome.driverFallback))")
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

    /// 実物の外側(画面の下端で止まる一覧 #list_nested = 143〜873)。枠の中心 y=887 は外側の下に出ている
    func testBringIntoViewFindsTheOuterListEvenWhenTheFrameCentreIsBelowIt() throws {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let shelf = FTRect(x: 16, y: 827, width: 370, height: 120)
        let outer = element(2, "list_nested", FTRect(x: 0, y: 143, width: 402, height: 730), scrollable: true)
        let reach = try XCTUnwrap(ScrollGeometry.bringIntoView(frame: shelf, screen: screen,
                                                               elements: [outer, element(29, "shelf_9", shelf, scrollable: true)]))
        XCTAssertEqual(reach.outer.y, 143)
        XCTAssertGreaterThan(reach.jump, 0)
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

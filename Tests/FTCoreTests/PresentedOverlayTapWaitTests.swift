// 出てきたばかりのダイアログ・シートの中を XCUITest で押す前だけ、表示の切り替えが終わる長さを待つ(PresentedOverlayTapWait)。
// 実測: RN の Modal の fade の最中の tap が飲まれ、E2E-RN の xcuitest でダイアログの3本が 16 本中 10 本赤。0.5 秒待つと 16/16

import XCTest
@testable import FTCore

final class PresentedOverlayTapWaitTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, id: String, y: Double, height: Double = 48) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 370, height: height), depth: 1)
    }

    /// 前の画面: 全面のスクロール容器 + 「開く」ボタン
    private var screenTree: [ElementInfo] {
        [el(1, "scrollView", id: "content", y: 0, height: 800), el(2, "button", id: "btn_show_dialog", y: 195)]
    }
    /// ダイアログが前面: 木はダイアログの中身だけ(上下が空く = RN の Modal で 46%)
    private var dialogTree: [ElementInfo] {
        [el(3, "staticText", id: "txt_dialog_title", y: 398, height: 17), el(4, "button", id: "btn_dialog_ok", y: 427)]
    }
    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.rn", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    func testWaitsOnlyForANewTargetInAPresentedOverlayOfAReactNativeAppTappedBySystemTouch() {
        let ok = dialogTree[1]
        XCTAssertTrue(PresentedOverlayTapWait.shouldWait(framework: .reactNative, tapsWithSystemTouch: true, target: ok,
                                                         previousTapTree: screenTree, current: snapshot(dialogTree)))
        // それぞれ1つずつ外すと待たない
        XCTAssertFalse(PresentedOverlayTapWait.shouldWait(framework: .uikit, tapsWithSystemTouch: true, target: ok,
                                                          previousTapTree: screenTree, current: snapshot(dialogTree)))
        XCTAssertFalse(PresentedOverlayTapWait.shouldWait(framework: nil, tapsWithSystemTouch: true, target: ok,
                                                          previousTapTree: screenTree, current: snapshot(dialogTree)))
        XCTAssertFalse(PresentedOverlayTapWait.shouldWait(framework: .reactNative, tapsWithSystemTouch: false, target: ok,
                                                          previousTapTree: screenTree, current: snapshot(dialogTree)))
        XCTAssertFalse(PresentedOverlayTapWait.shouldWait(framework: .reactNative, tapsWithSystemTouch: true, target: ok,
                                                          previousTapTree: nil, current: snapshot(dialogTree)))
        XCTAssertFalse(PresentedOverlayTapWait.shouldWait(framework: .reactNative, tapsWithSystemTouch: true, target: ok,
                                                          previousTapTree: dialogTree, current: snapshot(dialogTree)),
                       "前の tap の木にもあった = 出てきたばかりではない")
        // 全面の画面へ遷移した(画面を覆う木)= ダイアログではない
        let fullScreen = [el(5, "scrollView", id: "next", y: 0, height: 800), ok]
        XCTAssertFalse(PresentedOverlayTapWait.shouldWait(framework: .reactNative, tapsWithSystemTouch: true, target: ok,
                                                          previousTapTree: screenTree, current: snapshot(fullScreen)))
    }

    /// 根拠の数字はリテラルで固定する(既定を戻す変更が緑のまま通らないように)
    func testTheConstantsArePinned() {
        XCTAssertEqual(PresentedOverlayTapWait.transitionSeconds, 0.55)
        XCTAssertEqual(PresentedOverlayTapWait.overlayUncoveredFraction, 0.3)
    }

    // MARK: - StepExecutor の配線

    private func tapOK(framework: AppUIFramework?, systemTouch: Bool) async -> (StepOutcome, Double) {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [screenTree])
        driver.systemTouch = systemTouch
        let dialog = dialogTree
        driver.afterTap = { [unowned driver] in driver.snapshotElements = [dialog] }
        let executor = StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false, tunables: RunTunables(),
                                    uiFramework: framework)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_show_dialog")))
        let start = Date()
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_dialog_ok")))
        return (outcome, Date().timeIntervalSince(start))
    }

    func testTheExecutorWaitsBeforeTappingTheJustPresentedDialog() async {
        let (outcome, elapsed) = await tapOK(framework: .reactNative, systemTouch: true)
        XCTAssertTrue(outcome.notes.contains(.waitedForPresentedOverlay), "\(outcome.notes)")
        XCTAssertGreaterThanOrEqual(elapsed, PresentedOverlayTapWait.transitionSeconds - 0.05, "待ちを撃っていない")
    }

    /// **待った後に読み直した位置で撃つ**(切り替えの途中に読んだ木の ref・枠のまま撃たない。せり上がる slide のシート)
    func testTheTapAfterTheWaitUsesTheTreeReadAfterIt() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [screenTree])
        driver.systemTouch = true
        let midway = [el(3, "staticText", id: "txt_dialog_title", y: 698, height: 17), el(4, "button", id: "btn_dialog_ok", y: 727)]
        let settled = [el(13, "staticText", id: "txt_dialog_title", y: 398, height: 17), el(14, "button", id: "btn_dialog_ok", y: 427)]
        driver.afterTap = { [unowned driver] in
            guard driver.elementsAfter == nil else { return }
            driver.snapshotElements = [midway]
            driver.elementsAfter = (Date().addingTimeInterval(0.3), settled)
        }
        let executor = StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false, tunables: RunTunables(),
                                    uiFramework: .reactNative)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_show_dialog")))
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_dialog_ok")))
        XCTAssertTrue(outcome.notes.contains(.waitedForPresentedOverlay), "\(outcome.notes)")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.tap(") }.last, "primary.tap(ref:14)", "\(log.entries)")
    }

    func testInAppTapsDoNotWait() async {
        let (outcome, _) = await tapOK(framework: .reactNative, systemTouch: false)
        XCTAssertFalse(outcome.notes.contains(.waitedForPresentedOverlay), "\(outcome.notes)")
    }
}

// scrollToEdge が端で無駄な1本を送らずに済ませる判定(ScrollActionAvailability.atEdge)の
// 純粋な入出力を固定する。実物は Android の PullToRefreshBox 一覧(先頭で「もう1本」下向きに
// 送ると引っ張り更新に化ける。90_既知の制約.swift S0020 の陽性対照)。

import XCTest
@testable import FTCore

final class ScrollActionAvailabilityTests: XCTestCase {

    // MARK: - 縦(scrollToTop = finger "down" / scrollToBottom = finger "up")

    func testVerticalTopOnlyForwardMeansAtEdge() {
        // 先頭に着いた: forward/down しか申告しない = もう上(backward/up)へは動けない
        XCTAssertTrue(ScrollActionAvailability.atEdge(scrollActions: ["forward", "down"], forSwipe: .down))
    }

    func testVerticalBothMeansNotAtEdge() {
        XCTAssertFalse(ScrollActionAvailability.atEdge(scrollActions: ["backward", "forward"], forSwipe: .down))
    }

    func testVerticalBottomOnlyBackwardMeansAtEdge() {
        // scrollToBottom は finger "up" を送る。backward/up しか申告しない = もう下(forward/down)へは動けない
        XCTAssertTrue(ScrollActionAvailability.atEdge(scrollActions: ["backward", "up"], forSwipe: .up))
    }

    func testVerticalBottomBothMeansNotAtEdge() {
        XCTAssertFalse(ScrollActionAvailability.atEdge(scrollActions: ["forward", "down"], forSwipe: .up))
    }

    // MARK: - 横(scrollToLeftEdge = finger "right" / scrollToRightEdge = finger "left")

    func testHorizontalLeftEdgeOnlyForwardMeansAtEdge() {
        XCTAssertTrue(ScrollActionAvailability.atEdge(scrollActions: ["forward", "right"], forSwipe: .right))
    }

    func testHorizontalLeftEdgeBothMeansNotAtEdge() {
        XCTAssertFalse(ScrollActionAvailability.atEdge(scrollActions: ["backward", "forward"], forSwipe: .right))
    }

    func testHorizontalRightEdgeOnlyBackwardMeansAtEdge() {
        XCTAssertTrue(ScrollActionAvailability.atEdge(scrollActions: ["backward", "left"], forSwipe: .left))
    }

    func testHorizontalRightEdgeBothMeansNotAtEdge() {
        XCTAssertFalse(ScrollActionAvailability.atEdge(scrollActions: ["forward", "backward"], forSwipe: .left))
    }

    // MARK: - 汎用名(backward/forward)だけでも方向つき名(up/down/left/right)だけでも通る

    func testGenericNameAloneSatisfiesRequirement() {
        XCTAssertFalse(ScrollActionAvailability.atEdge(scrollActions: ["backward"], forSwipe: .down))
    }

    func testDirectionalNameAloneSatisfiesRequirement() {
        XCTAssertFalse(ScrollActionAvailability.atEdge(scrollActions: ["up"], forSwipe: .down))
    }

    // MARK: - nil(未申告: iOS・旧ブリッジ・容器を一意に決められない)は常に「分からない」

    func testNilScrollActionsNeverClaimsEdge() {
        for finger in FTSwipeDirection.allCases {
            XCTAssertFalse(ScrollActionAvailability.atEdge(scrollActions: nil, forSwipe: finger),
                          "\(finger) で nil を端と誤認した")
        }
    }

    func testEmptyScrollActionsMeansAtEdgeInEveryDirection() {
        // 容器が scrollable ではあるが、この瞬間どちらへも動けない(両端が同時に画面に収まる等)
        for finger in FTSwipeDirection.allCases {
            XCTAssertTrue(ScrollActionAvailability.atEdge(scrollActions: [], forSwipe: finger),
                         "\(finger) で空配列を「動ける」と誤認した")
        }
    }

    // MARK: - 包む容器(伸縮するヘッダ。実測 Android: 一覧 ["forward"]・外側 ["backward", "forward"])

    private func scrollable(ref: Int, y: Double, height: Double, actions: [String]?) -> ElementInfo {
        ElementInfo(ref: ref, type: "scrollView", identifier: nil, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 1080, height: height), depth: ref,
                    scrollable: true, scrollActions: actions)
    }

    func testInnerAtEdgeButEnclosingCanStillMoveIsNotAtEdge() {
        let list = scrollable(ref: 2, y: 340, height: 2084, actions: ["forward"])
        let outer = scrollable(ref: 1, y: 168, height: 2256, actions: ["backward", "forward"])
        XCTAssertFalse(ScrollActionAvailability.atEdge(container: list, enclosing: [outer], forSwipe: .down))
        XCTAssertTrue(ScrollActionAvailability.atEdge(container: list, enclosing: [], forSwipe: .down))
    }

    func testEnclosingAlsoAtEdgeOrUndeclaredMeansAtEdge() {
        let list = scrollable(ref: 2, y: 746, height: 1678, actions: ["forward"])
        let expanded = scrollable(ref: 1, y: 168, height: 2256, actions: ["forward"])
        let undeclared = scrollable(ref: 3, y: 168, height: 2256, actions: nil)
        XCTAssertTrue(ScrollActionAvailability.atEdge(container: list, enclosing: [expanded, undeclared],
                                                      forSwipe: .down))
    }

    // MARK: - 同じ枠に横のページャと縦の一覧(実測 E2EY-CMP の Android: ページャ ["forward","right"]・
    // 一覧 ["backward","forward","up","down"]。ページャを採って scrollToTop が1本も払わずに終わった)

    private func pagerAndList() -> [ElementInfo] {
        [scrollable(ref: 10, y: 677, height: 1684, actions: ["forward", "right"]),
         scrollable(ref: 11, y: 677, height: 1684, actions: ["backward", "forward", "up", "down"])]
    }

    func testVerticalEdgeIgnoresAHorizontalPagerWithTheSameFrame() {
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                                        elements: pagerAndList(), truncatedCount: 0)
        let step = FlowStep(action: "scrollToEdge", direction: "down")
        XCTAssertEqual(StepExecutor.scrollContainerElement(step: step, in: snapshot, vertical: true)?.ref, 11)
        XCTAssertEqual(StepExecutor.scrollContainerElement(step: step, in: snapshot, vertical: false)?.ref, 10)
    }

    /// RN の collapsible-tab-view(実測): 同じ枠に汎用の forward だけの容器が2つと、up/down を申告する一覧
    func testSameSizeTiePrefersTheContainerDeclaringTheAxis() {
        let elements = [scrollable(ref: 6, y: 495, height: 1929, actions: ["forward"]),
                        scrollable(ref: 7, y: 495, height: 1929, actions: ["forward"]),
                        scrollable(ref: 8, y: 495, height: 1929, actions: ["backward", "forward", "up", "down"])]
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                                        elements: elements, truncatedCount: 0)
        let step = FlowStep(action: "scrollToEdge", direction: "down")
        XCTAssertEqual(StepExecutor.scrollContainerElement(step: step, in: snapshot, vertical: true)?.ref, 8)
    }

    func testScrollToTopSwipesWhenOnlyTheListCanStillMove() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [pagerAndList()])
        _ = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "scrollToEdge", direction: "down", maxSwipes: 3))
        XCTAssertTrue(driver.log.entries.contains("primary.swipe"),
                      "ページャの申告を縦の端と読んで1本も払っていない: \(driver.log.entries)")
    }

    func testInnerThatCanMoveIsNotAtEdgeWhateverTheEnclosingSays() {
        let list = scrollable(ref: 2, y: 340, height: 2084, actions: ["backward", "forward"])
        let outer = scrollable(ref: 1, y: 168, height: 2256, actions: ["forward"])
        XCTAssertFalse(ScrollActionAvailability.atEdge(container: list, enclosing: [outer], forSwipe: .down))
    }
}

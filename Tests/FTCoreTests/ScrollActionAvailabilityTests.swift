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
}

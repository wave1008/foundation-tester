import XCTest
@testable import FTCore

/// 反転したスクロールビュー(RN の `inverted`・transform で上下反転した UITableView)では、in-app の
/// contentOffset 経路が指の向きを裏返して読む(`FTSwipeDirection.inContentSpace`)。
/// witness: E2EY の反転チャット(写さないと最新の位置で「もう端」と判定し、探索が1回も送らなかった)
final class SwipeDirectionContentSpaceTests: XCTestCase {
    func testUnflippedKeepsTheFingerDirection() {
        for d in FTSwipeDirection.allCases {
            XCTAssertEqual(d.inContentSpace(flipX: false, flipY: false), d)
        }
    }

    func testVerticalFlipSwapsOnlyUpAndDown() {
        XCTAssertEqual(FTSwipeDirection.up.inContentSpace(flipX: false, flipY: true), .down)
        XCTAssertEqual(FTSwipeDirection.down.inContentSpace(flipX: false, flipY: true), .up)
        XCTAssertEqual(FTSwipeDirection.left.inContentSpace(flipX: false, flipY: true), .left)
        XCTAssertEqual(FTSwipeDirection.right.inContentSpace(flipX: false, flipY: true), .right)
    }

    func testHorizontalFlipSwapsOnlyLeftAndRight() {
        XCTAssertEqual(FTSwipeDirection.left.inContentSpace(flipX: true, flipY: false), .right)
        XCTAssertEqual(FTSwipeDirection.right.inContentSpace(flipX: true, flipY: false), .left)
        XCTAssertEqual(FTSwipeDirection.up.inContentSpace(flipX: true, flipY: false), .up)
        XCTAssertEqual(FTSwipeDirection.down.inContentSpace(flipX: true, flipY: false), .down)
    }
}

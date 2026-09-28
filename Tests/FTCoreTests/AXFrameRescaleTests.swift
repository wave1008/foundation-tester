import XCTest
@testable import FTCore

final class AXFrameRescaleTests: XCTestCase {

    private let view = FTRect(x: 0, y: 0, width: 402, height: 874)

    /// 実測の形(iPhone 17 Pro・倍率 3): ルートのノードが 134x291.3 と申告し、戻るボタンが (0,20.7 18.7x18.7)
    func testShrunkenRouteIsMappedBackToTheView() throws {
        let rescale = try XCTUnwrap(AXFrameRescale.shrunkSubtree(
            reported: FTRect(x: 0, y: 0, width: 134, height: 291.333_333), view: view, screenScale: 3))
        let back = rescale.apply(FTRect(x: 0, y: 20.666_667, width: 18.666_667, height: 18.666_667))
        XCTAssertEqual(back.x, 0, accuracy: 0.01)
        XCTAssertEqual(back.y, 62, accuracy: 0.01)
        XCTAssertEqual(back.width, 56, accuracy: 0.01)
        XCTAssertEqual(back.height, 56, accuracy: 0.01)
    }

    func testTwoTimesScreenIsHandledToo() throws {
        let rescale = try XCTUnwrap(AXFrameRescale.shrunkSubtree(
            reported: FTRect(x: 0, y: 0, width: 187.5, height: 333.5),
            view: FTRect(x: 0, y: 0, width: 375, height: 667), screenScale: 2))
        let row = rescale.apply(FTRect(x: 10, y: 50, width: 20, height: 5))
        XCTAssertEqual(row.x, 20, accuracy: 0.01)
        XCTAssertEqual(row.y, 100, accuracy: 0.01)
        XCTAssertEqual(row.width, 40, accuracy: 0.01)
    }

    /// 健全なルート(実寸)・ちょうど 1/倍率 でない小さな要素・倍率 1 の画面には掛けない
    func testOtherShapesAreLeftAlone() {
        XCTAssertNil(AXFrameRescale.shrunkSubtree(reported: view, view: view, screenScale: 3))
        XCTAssertNil(AXFrameRescale.shrunkSubtree(
            reported: FTRect(x: 0, y: 0, width: 134, height: 437), view: view, screenScale: 3))
        XCTAssertNil(AXFrameRescale.shrunkSubtree(
            reported: FTRect(x: 16, y: 0, width: 134, height: 291.333_333), view: view, screenScale: 3))
        XCTAssertNil(AXFrameRescale.shrunkSubtree(
            reported: FTRect(x: 0, y: 0, width: 201, height: 437), view: view, screenScale: 3))
        XCTAssertNil(AXFrameRescale.shrunkSubtree(reported: view, view: view, screenScale: 1))
    }
}

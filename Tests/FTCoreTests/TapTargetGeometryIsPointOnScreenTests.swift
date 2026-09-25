// TapTargetGeometry.isPointOnScreen の判定。MCP(offscreenCoordinateError)とライブ操作
// (ApiLiveCommand.requireOnScreen)が共有する唯一の定義元(LiveControlExitParityTests が
// 両側の配線を固定する)。G1(2026-09-25): ライブ操作の drag に 1e308 が渡り、この判定を
// 経ずに AndroidDriver の Int32 変換が trap してプロセスごと落ちた。

import XCTest
@testable import FTCore

final class TapTargetGeometryIsPointOnScreenTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    func testCentreIsOnScreen() {
        XCTAssertTrue(TapTargetGeometry.isPointOnScreen(x: 540, y: 1212, screen: screen))
    }

    /// 縁は外(`<`): 幅 1080 の画面で x=1080 は画素の外(0…1079)
    func testTopLeftOriginIsInsideButFarEdgeIsOutside() {
        XCTAssertTrue(TapTargetGeometry.isPointOnScreen(x: 0, y: 0, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: 1080, y: 0, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: 0, y: 2424, screen: screen))
        XCTAssertTrue(TapTargetGeometry.isPointOnScreen(x: 1079, y: 2423, screen: screen))
    }

    func testNegativeCoordinatesAreOutside() {
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: -1, y: 100, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: 100, y: -1, screen: screen))
    }

    /// G1 の実地値そのもの
    func testWildlyOutOfRangeFiniteValueIsOutside() {
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: 1e308, y: 0, screen: screen))
    }

    func testNonFiniteValuesAreOutside() {
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: .nan, y: 100, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: 100, y: .nan, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: .infinity, y: 100, screen: screen))
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: 100, y: -.infinity, screen: screen))
    }

    /// screen が分からない(幅/高さ 0)ときは「分からない」を「外れている」と読まない = 許す
    func testUnknownZeroSizedScreenAllowsAnyFiniteCoordinate() {
        let unknown = FTRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertTrue(TapTargetGeometry.isPointOnScreen(x: 1e308, y: -50, screen: unknown))
        XCTAssertTrue(TapTargetGeometry.isPointOnScreen(x: 0, y: 0, screen: unknown))
    }

    /// screen の原点が 0 でない構成でも矩形基準で判定する
    func testNonZeroOriginScreen() {
        let offset = FTRect(x: 100, y: 200, width: 300, height: 400)
        XCTAssertTrue(TapTargetGeometry.isPointOnScreen(x: 150, y: 250, screen: offset))
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: 50, y: 250, screen: offset))
        XCTAssertFalse(TapTargetGeometry.isPointOnScreen(x: 150, y: 700, screen: offset))
    }
}

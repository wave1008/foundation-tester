import XCTest
@testable import FTCore

/// ScrollGeometry(shirates-core ScrollingInfo の移植)の境界を固定する。
/// 実機を必要としない層なので、ここで落とせない誤りは E2E まで見つからない。
final class ScrollGeometryTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    func testVerticalDownUsesBottomToTopWithMargins() {
        // 指は上へ動く(コンテンツは下へ進む)。始点は下の縁から startMargin ぶん内側
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .down,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        XCTAssertEqual(path?.fromY ?? 0, 874 * 0.8, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 874 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.fromX ?? 0, 201, accuracy: 0.001)
        XCTAssertEqual(path?.toX ?? 0, 201, accuracy: 0.001)
    }

    func testVerticalUpIsMirrored() {
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .up,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        XCTAssertEqual(path?.fromY ?? 0, 874 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 874 * 0.8, accuracy: 0.001)
    }

    func testAsymmetricMarginsApplyToTheCorrectEdges() {
        // start=0.1(指を置く側 = 下)/ end=0.4(離す側 = 上)
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .down,
                                       startMarginRatio: 0.1, endMarginRatio: 0.4)
        XCTAssertEqual(path?.fromY ?? 0, 874 * 0.9, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 874 * 0.4, accuracy: 0.001)
    }

    func testHorizontalUsesCenterYAndWidth() {
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .right,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        XCTAssertEqual(path?.fromX ?? 0, 402 * 0.8, accuracy: 0.001)
        XCTAssertEqual(path?.toX ?? 0, 402 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.fromY ?? 0, 437, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 437, accuracy: 0.001)
    }

    /// **容器は画面と交差させる**。E2E-iOS のリストは (16,270 370x492) で画面の一部しか占めない。
    /// 交差を取らずに容器そのものを使うと、画面外へはみ出す容器で座標が画面外に出る
    func testContainerIsClippedToViewport() {
        let container = FTRect(x: 16, y: 270, width: 370, height: 900)   // 画面下端を超える高さ
        let path = ScrollGeometry.path(container: container, viewport: screen, direction: .down,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        // 交差は y 270..874(高さ 604)
        XCTAssertEqual(path?.fromY ?? 0, 270 + 604 * 0.8, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 270 + 604 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.fromX ?? 0, 201, accuracy: 0.001)   // 16 + 370/2
    }

    func testNoIntersectionReturnsNil() {
        let offscreen = FTRect(x: 0, y: 900, width: 402, height: 100)
        XCTAssertNil(ScrollGeometry.path(container: offscreen, viewport: screen, direction: .down,
                                         startMarginRatio: 0.2, endMarginRatio: 0.2))
    }

    /// 接しているだけ(高さ 0 の交差)は操作できないので nil
    func testTouchingEdgeReturnsNil() {
        let touching = FTRect(x: 0, y: 874, width: 402, height: 100)
        XCTAssertNil(ScrollGeometry.path(container: touching, viewport: screen, direction: .down,
                                         startMarginRatio: 0.2, endMarginRatio: 0.2))
    }

    /// マージンの合計が 1 に達すると始点と終点が重なる = 1ミリも動かない。
    /// 上限で頭打ちにして「動くスワイプ」を返す
    func testMarginsAreClampedSoTheSwipeStillMoves() {
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .down,
                                       startMarginRatio: 0.9, endMarginRatio: 0.9)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.fromY ?? 0, 874 * (1 - ScrollGeometry.maxMarginRatio), accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 874 * ScrollGeometry.maxMarginRatio, accuracy: 0.001)
        XCTAssertGreaterThan((path?.fromY ?? 0) - (path?.toY ?? 0), ScrollGeometry.minUsableDistance)
    }

    func testNegativeAndNonFiniteMarginsAreTreatedAsZero() {
        let negative = ScrollGeometry.path(container: screen, viewport: screen, direction: .down,
                                           startMarginRatio: -1, endMarginRatio: .nan)
        XCTAssertEqual(negative?.fromY ?? 0, 874, accuracy: 0.001)
        XCTAssertEqual(negative?.toY ?? 0, 0, accuracy: 0.001)
    }

    /// 小さすぎる容器では座標を作らず、呼び出し側を従来経路へ落とす
    func testTinyContainerReturnsNil() {
        let tiny = FTRect(x: 0, y: 400, width: 402, height: 10)
        XCTAssertNil(ScrollGeometry.path(container: tiny, viewport: screen, direction: .down,
                                         startMarginRatio: 0.2, endMarginRatio: 0.2))
    }

    /// 用途ごとの既定。**探索だけ保守側**(行き過ぎると戻らずシナリオ全体が中断するため)
    func testSearchMarginIsMoreConservativeThanEdge() {
        let search = FTScrollDefaults.startMarginRatio(intent: .search, vertical: true)
        let edge = FTScrollDefaults.startMarginRatio(intent: .edge, vertical: true)
        XCTAssertGreaterThan(search, edge)
        XCTAssertEqual(search, 0.25, accuracy: 0.0001)
        XCTAssertEqual(edge, 0.2, accuracy: 0.0001)
    }

    /// 横は現行の 0.2↔0.8(スパン 0.6)と同じ = 用途で分けない
    func testHorizontalMarginIsUniform() {
        for intent in FTSwipeIntent.allCases {
            XCTAssertEqual(FTScrollDefaults.startMarginRatio(intent: intent, vertical: false),
                           0.2, accuracy: 0.0001)
        }
    }
}

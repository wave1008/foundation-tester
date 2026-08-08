// 2026-08-09 のマップ監査(Apple マップ / Google マップ)で出た4件の修正。
//
// **判定は実アプリの木で確かめる**(自前 SUT はこの形を1つも持たない):
//   - nested     = 行セルの中心を、その中の別アクションの帯が横取りする(P2)
//   - scrolledOut = 申告されたスクロール容器の外へ送り出された行(P3)
// どちらも witness をフィクスチャに固定してあり、件数の砦は SweepHarnessTests 側。
// ここでは「どれを名指すか」と「配線されているか」を見る。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPMapAuditFixesTests: XCTestCase {

    private func fixture(_ name: String) throws -> SnapshotResponse {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots/\(name).json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    // MARK: - P2 子孫による中心の横取り

    /// Simulator 上で実際に踏んだ形: `#Maps.PlaceTableViewCell` を撃つとガイド一覧が開いた
    func testNestedActionInsideTheRowIsNamed() throws {
        let snap = try fixture("ios-maps_suggest_guides")
        let cell = try XCTUnwrap(snap.elements.first { $0.identifier == "Maps.PlaceTableViewCell" })
        let nested = try XCTUnwrap(
            RefGuard.nestedActionCoveringCentre(cell, in: snap.elements))
        XCTAssertEqual(nested.identifier, "FeaturedInMultipleGuidesContextLineItem")
        let warning = RefGuard.overlapWarning(found: cell, in: snap.elements, screen: snap.screen)
        XCTAssertTrue(warning.contains("#FeaturedInMultipleGuidesContextLineItem"), warning)
        XCTAssertTrue(warning.contains("#Maps.PlaceTableViewCell"), warning)
    }

    /// **行を包み直すだけのラッパーは名指さない**: 同じセルの中の無名 button は
    /// セルとほぼ同じ矩形(面積比 0.99)で、押しても行と同じ結果になる
    func testWrapperOfTheSameSizeIsNotReported() throws {
        let snap = try fixture("ios-maps_suggest_guides")
        let cell = try XCTUnwrap(snap.elements.first { $0.identifier == "Maps.PlaceTableViewCell" })
        let nested = RefGuard.nestedActionCoveringCentre(cell, in: snap.elements)
        XCTAssertNotEqual(nested?.ref, cell.ref + 1, "直後の無名 button(0.99)は対象外のはず")
    }

    /// 非対話の容器は `missesItsOwnContent` の担当なので、こちらは黙る(二重に言わない)
    func testNonInteractiveContainerIsNotReportedAsNested() throws {
        let snap = try fixture("ios-place")
        for e in snap.elements where e.type == "other" {
            XCTAssertNil(RefGuard.nestedActionCoveringCentre(e, in: snap.elements),
                         "\(RefGuard.describe(e)) が nested として出ている")
        }
    }

    // MARK: - P3 申告されたスクロール容器の外

    func testScrolledOutRowNamesItsScroller() throws {
        let snap = try fixture("ios-place_guides_scrolled")
        let section = try XCTUnwrap(
            snap.elements.first { $0.identifier == "CuratedGuidesSection" })
        let scroller = try XCTUnwrap(
            RefGuard.outsideDeclaredScroller(section, in: snap.elements))
        XCTAssertEqual(scroller.identifier, "MUScrollableStackView")
        let warning = RefGuard.scrolledOutWarning(section, in: snap.elements)
        XCTAssertTrue(warning.contains("#MUScrollableStackView"), warning)
        XCTAssertTrue(warning.contains("ft_scroll_to"), warning)
    }

    /// **間引きで繋がっただけの相手を容器と読まない**。Google マップの検索結果では、
    /// カード容器が落ちた結果 本文が写真カルーセル `#recycler_view` の子孫に見え、
    /// ガード前は 10 件まとめて誤検知していた
    func testPrunedTreeDoesNotFakeAScroller() throws {
        let snap = try fixture("and-results")
        for e in snap.elements {
            XCTAssertNil(RefGuard.outsideDeclaredScroller(e, in: snap.elements),
                         "\(RefGuard.describe(e)) が誤って容器の外と判定されている")
        }
    }

    /// 配線: 一覧の印(⚠️scroll-leftover)にも乗ること。判定だけ足して印に繋がないと、
    /// 「撃つまで気付けない」が残る
    func testScrolledOutRowsAreFlaggedInTheListing() throws {
        let snap = try fixture("ios-place_guides_scrolled")
        let section = try XCTUnwrap(
            snap.elements.first { $0.identifier == "CuratedGuidesSection" })
        XCTAssertTrue(MCPServer.ghostRefs(snap).contains(section.ref))
        XCTAssertEqual(MCPServer.ghostFlags(snap)[section.ref], "⚠️scroll-leftover")
        XCTAssertTrue(MCPServer.ghostNote(snap).contains("#CuratedGuidesSection"))
    }

    /// 容器の外に何も無い画面では印を増やさない
    func testCleanScreenGetsNoScrollLeftoverFlag() throws {
        let snap = try fixture("ios-place")
        XCTAssertTrue(MCPServer.ghostRefs(snap).isEmpty)
    }

    // MARK: - P4 座標ピンチの対象領域

    /// 既定の半径は**画面の短辺相対**(iOS=pt / Android=px で桁が違うため)
    func testPinchAreaScalesWithTheScreen() {
        let ios = MCPServer.pinchArea(x: 201, y: 300, radius: nil,
                                      screen: FTRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertEqual(ios.width, 402 * MCPServer.pinchRadiusScreenRatio * 2, accuracy: 0.001)
        XCTAssertEqual(ios.centerX, 201, accuracy: 0.001)
        XCTAssertEqual(ios.centerY, 300, accuracy: 0.001)
        let android = MCPServer.pinchArea(x: 540, y: 1200, radius: nil,
                                          screen: FTRect(x: 0, y: 0, width: 1080, height: 2361))
        XCTAssertGreaterThan(android.width, ios.width)
    }

    /// **画面からはみ出さない**: 外へ出た指はタッチとして届かず、要求より小さいズームになる
    func testPinchAreaIsClampedToTheScreen() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let area = MCPServer.pinchArea(x: 20, y: 300, radius: nil, screen: screen)
        XCTAssertGreaterThanOrEqual(area.x, 0)
        XCTAssertLessThanOrEqual(area.x + area.width, screen.width)
    }

    /// 画面が分からない(まだ撮っていない)ときも領域は作れる
    func testPinchAreaFallsBackWithoutAScreen() {
        let area = MCPServer.pinchArea(x: 100, y: 100, radius: nil, screen: nil)
        XCTAssertEqual(area.width, MCPServer.pinchRadiusFallback * 2, accuracy: 0.001)
    }

    func testExplicitRadiusWins() {
        let area = MCPServer.pinchArea(x: 200, y: 400, radius: 30,
                                       screen: FTRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertEqual(area.width, 60, accuracy: 0.001)
    }
}

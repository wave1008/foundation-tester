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

    /// 配線: 一覧の印にも乗ること。判定だけ足して印に繋がないと、「撃つまで気付けない」が残る。
    ///
    /// **印は ⚠️offscreen になる**(2026-08-09 に印を2種へ割った): この要素は中心が y=-83 =
    /// 画面の外にあり、`RefGuard.preTapWarnings` も画面外を容器外より先に言う(そちらのほうが
    /// 具体的で、frame が今の描画位置でないことも同時に説明できる)。印の優先順位を
    /// タップ時の警告と揃える —— 同じ要素についてツールごとに言うことが変わらないように
    func testScrolledOutRowsAreFlaggedInTheListing() throws {
        let snap = try fixture("ios-place_guides_scrolled")
        let section = try XCTUnwrap(
            snap.elements.first { $0.identifier == "CuratedGuidesSection" })
        XCTAssertTrue(MCPServer.ghostRefs(snap).contains(section.ref))
        XCTAssertEqual(MCPServer.ghostFlags(snap)[section.ref], MCPServer.offscreenMark)
        XCTAssertTrue(MCPServer.ghostNote(snap).contains("#CuratedGuidesSection"))
    }

    /// **画面内に居る残骸は ⚠️scroll-leftover のまま**(印を割った副作用で、危険な側が
    /// 「ただの画面外」に化けていないこと)。同一矩形へクランプされた行は画面の中に描かれており、
    /// 撃つと別の行に当たる —— こちらが2種のうち重いほうの印
    func testOnScreenLeftoverKeepsTheHeavierMark() throws {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        // 同一矩形に畳まれたラベル付きの行3つ(RefGuard.stackedRefs が拾う形)
        let frame = FTRect(x: 16, y: 270, width: 330, height: 56)
        let elements = (1...3).map { i in
            ElementInfo(ref: i, type: "staticText", identifier: "row_0\(i)", label: "行 \(i)",
                        value: nil, placeholder: nil, enabled: true, frame: frame, depth: 2)
        }
        let snap = SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                                    elements: elements, truncatedCount: 0)
        XCTAssertEqual(MCPServer.ghostFlags(snap)[2], MCPServer.leftoverMark)
        XCTAssertTrue(MCPServer.ghostNote(snap).contains("may hit something else"),
                      MCPServer.ghostNote(snap))
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

    // MARK: - 打ち切りの申告

    private func snapshot(elements: [ElementInfo], truncated: Int,
                          tiers: [String: Int]? = nil) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: truncated,
                         truncatedTiers: tiers)
    }

    /// **末尾の1行では読まれない**: 実測(Apple マップの経路プランナー)で 91 件落ちていたのに、
    /// `(+91 elements truncated)` は 120 行の一覧のいちばん下にしか出ていなかった
    func testTruncationIsAnnouncedUpFront() {
        let note = MCPServer.truncationNote(snapshot(elements: [], truncated: 91))
        XCTAssertTrue(note.contains("91 element(s) were dropped"), note)
        XCTAssertTrue(note.contains("waitFor"), note)
    }

    /// 申告があれば**何が落ちたか**まで言う(ホストは残った側しか見られない)
    func testTruncationBreakdownIsShownWhenTheBridgeReportsIt() {
        let note = MCPServer.truncationNote(
            snapshot(elements: [], truncated: 91, tiers: ["decoration": 80, "bulk": 11]))
        XCTAssertTrue(note.contains("80 unlabelled decorations"), note)
        XCTAssertTrue(note.contains("11 repeated same-id elements"), note)
    }

    /// 旧ブリッジ(申告なし)では件数だけ。**推測で内訳を書かない**
    func testTruncationNoteHasNoBreakdownWithoutAReport() {
        let note = MCPServer.truncationNote(snapshot(elements: [], truncated: 5))
        XCTAssertTrue(note.contains("5 element(s) were dropped"), note)
        for tier in SnapshotResponse.truncatedTierOrder {
            XCTAssertFalse(note.contains(tier.label), "内訳を推測で書いている: \(note)")
        }
    }

    func testNoTruncationNoNote() {
        XCTAssertEqual(MCPServer.truncationNote(snapshot(elements: [], truncated: 0)), "")
    }

    // MARK: - id もラベルも無い要素のスコープ付きセレクタ

    /// **「セレクタを書けない」は嘘だった**: id を持つ祖先があれば `>>` で書ける。
    /// 実測(Google マップの移動手段タブ)は `#directions_mode_tabs` の中の名無し clickable
    func testUnlabeledClickableGetsAScopedSelector() throws {
        let snap = try fixture("and-directions_tabs")
        // **移動手段タブ**を狙う(ref 1 は祖先を持たない全画面の地図なので対象外 = 正しく nil)
        let tabs = try XCTUnwrap(snap.elements.first { $0.identifier == "directions_mode_tabs" })
        let target = try XCTUnwrap(snap.elements.first {
            $0.type == "clickable" && ($0.identifier ?? "").isEmpty && ($0.label ?? "").isEmpty
                && $0.depth > tabs.depth && $0.ref > tabs.ref
        })
        let selector = try XCTUnwrap(MCPServer.scopedSelector(for: target, in: snap))
        XCTAssertTrue(selector.hasPrefix("#directions_mode_tabs >> .clickable["), selector)
        let note = MCPServer.unlabeledClickablesNote(snap)
        XCTAssertTrue(note.contains(selector), note)
        XCTAssertTrue(note.contains("scoped selector"), note)
    }

    /// **スコープの id が一意でないなら書かない**(`#recycler_view` が4つある画面で
    /// 別の容器を掴む)。祖先が名無しのときも nil
    func testScopedSelectorIsNotOfferedWhenTheScopeIsAmbiguous() throws {
        let snap = try fixture("and-results")
        for e in snap.elements where e.type == "clickable" {
            guard let selector = MCPServer.scopedSelector(for: e, in: snap) else { continue }
            let scopeID = String(selector.dropFirst().prefix(while: { $0 != " " }))
            let count = snap.elements.filter { $0.identifier == scopeID }.count
            XCTAssertEqual(count, 1, "曖昧なスコープを勧めている: \(selector)")
        }
    }

    /// **勧めたセレクタが本当に解決すること**を DSL の照合器で確かめる。
    /// 「それらしい文字列を出す」と「その文字列が当たる」は別物で、
    /// 添字の起点(1 オリジン)やスコープ内の数え方を間違えると**黙って別の要素**を指す
    func testTheSuggestedSelectorResolvesBackToTheSameElement() throws {
        let snap = try fixture("and-directions_tabs")
        var checked = 0
        for target in snap.elements where target.type == "clickable" {
            guard let text = MCPServer.scopedSelector(for: target, in: snap) else { continue }
            let locator = FTSelector.parse(text).primary
            let resolved = try XCTUnwrap(StepExecutor.match(locator, in: snap),
                                         "勧めたセレクタが1件も当たらない: \(text)")
            XCTAssertEqual(resolved.ref, target.ref,
                           "\(text) が別の要素を指している(期待 [\(target.ref)])")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "検証対象が1件も無い")
    }

    /// 祖先に id が1つも無ければ従来どおり「ref か座標しかない」
    func testNoScopeMeansTheOldAdvice() {
        let root = ElementInfo(ref: 1, type: "other", identifier: nil, label: nil, value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 402, height: 874), depth: 1)
        let child = ElementInfo(ref: 2, type: "clickable", identifier: nil, label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 40, height: 40), depth: 2)
        let snap = snapshot(elements: [root, child], truncated: 0)
        XCTAssertNil(MCPServer.scopedSelector(for: child, in: snap))
        XCTAssertTrue(MCPServer.unlabeledClickablesNote(snap).contains("only be targeted by ref"))
    }
}

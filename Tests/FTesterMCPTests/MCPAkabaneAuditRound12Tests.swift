// 2026-08-12 のマップ監査(赤羽→立川)で出た3件の修正。MCPServer+Hints.swift 側だけを直した
// (Sources/ftester-mcp/MCPServer+Hints.swift)。各テストは陽性・陰性の両方を持つ ——
// 「常に空を返す」変異を素通ししないため。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPAkabaneAuditRound12Tests: XCTestCase {

    private func screen(_ elements: [ElementInfo], width: Double = 390,
                        height: Double = 900) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: width, height: height),
                         elements: elements, truncatedCount: 0)
    }

    private func element(_ ref: Int, type: String = "cell", id: String? = nil, label: String? = nil,
                         value: String? = nil, x: Double, y: Double, w: Double = 100, h: Double = 40,
                         depth: Int = 2, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth,
                    scrollable: scrollable)
    }

    // MARK: - ① pageIndicator 誘導に scrollFrame: を添える

    /// 容器が id で一意に指せるとき: 案内に `scrollFrame: #id` が乗る
    func testPagerHintNamesTheScrollFrameWhenTheContainerIDIsUnique() {
        let snap = screen([
            element(1, type: "scrollView", id: "route_pager", x: 0, y: 700, w: 390, h: 130,
                    depth: 1, scrollable: true),
            element(2, type: "cell", id: "route_a", label: "Route A", x: 10, y: 710, w: 180, h: 110),
            element(3, type: "cell", id: "route_b", label: "Route B", x: 200, y: 710, w: 180, h: 110),
            element(4, type: "cell", id: "route_c", label: "Route C", x: 401, y: 710, w: 180, h: 110),
            element(5, type: "pageIndicator", value: "2 of 3", x: 150, y: 844, w: 90, h: 14, depth: 1),
        ])
        let note = MCPServer.ghostNote(snap)
        XCTAssertTrue(note.contains("horizontal pager"), note)
        XCTAssertTrue(note.contains("ft_scroll_to (direction: right)"), note)
        XCTAssertTrue(note.contains("Pass scrollFrame: #route_pager to ft_scroll_to"), note)
    }

    /// 容器の id がページャ自身と重複しているとき(実測: Apple マップの経路候補・横ページャで
    /// scrollView と pageIndicator が同じ id を名乗っていた): `#id` は使えないので ref 形になる
    func testPagerHintFallsBackToARefWhenTheContainerIDIsNotUnique() {
        let snap = screen([
            element(1, type: "scrollView", id: "RoutePlanningOverviewViewController",
                    x: 0, y: 700, w: 390, h: 130, depth: 1, scrollable: true),
            element(2, type: "cell", id: "route_a", label: "Route A", x: 10, y: 710, w: 180, h: 110),
            element(3, type: "cell", id: "route_b", label: "Route B", x: 200, y: 710, w: 180, h: 110),
            element(4, type: "cell", id: "route_c", label: "Route C", x: 401, y: 710, w: 180, h: 110),
            element(5, type: "pageIndicator", id: "RoutePlanningOverviewViewController",
                    value: "2 of 3", x: 150, y: 844, w: 90, h: 14, depth: 1),
        ])
        let note = MCPServer.ghostNote(snap)
        XCTAssertTrue(
            note.contains("Pass scrollFrame: 1 (its ft_snapshot ref — #id here is not unique)"),
            note)
        XCTAssertFalse(note.contains("scrollFrame: #RoutePlanningOverviewViewController"), note)
    }

    /// 右にはみ出す行が2つの別々のスクロール容器に属し、どちらを渡せばよいか決められないとき:
    /// 嘘の助言を出さず、従来の文言のまま(scrollFrame: は言わない)
    func testPagerHintStaysQuietWhenTheScrollContainerCannotBePinnedDown() {
        let snap = screen([
            element(1, type: "scrollView", id: "pager_a", x: 0, y: 700, w: 390, h: 130,
                    depth: 1, scrollable: true),
            element(2, type: "cell", id: "a1", label: "A1", x: 10, y: 710, w: 180, h: 110),
            element(3, type: "cell", id: "a2", label: "A2", x: 200, y: 710, w: 180, h: 110),
            element(4, type: "cell", id: "a3", label: "A3", x: 401, y: 710, w: 180, h: 110),
            element(5, type: "scrollView", id: "pager_b", x: 0, y: 400, w: 390, h: 130,
                    depth: 1, scrollable: true),
            element(6, type: "cell", id: "b1", label: "B1", x: 10, y: 410, w: 180, h: 110),
            element(7, type: "cell", id: "b2", label: "B2", x: 200, y: 410, w: 180, h: 110),
            element(8, type: "cell", id: "b3", label: "B3", x: 401, y: 410, w: 180, h: 110),
            element(9, type: "pageIndicator", value: "2 of 3", x: 150, y: 844, w: 90, h: 14, depth: 1),
        ])
        let note = MCPServer.ghostNote(snap)
        XCTAssertTrue(note.contains("ft_scroll_to (direction: right)"), note)
        XCTAssertFalse(note.contains("scrollFrame:"), note)
    }

    // MARK: - ② 重複 id の注記

    /// 実測(Google マップの時刻ピッカー): 「時」「分」の両方が id=numberpicker_input。
    /// 兄弟であって入れ子ではないので、重複として名指しされるべき
    func testDuplicateIDsNoteNamesTheSharedID() {
        let snap = screen([
            element(1, type: "textField", id: "numberpicker_input", x: 300, y: 986, w: 168, h: 126),
            element(2, type: "textField", id: "numberpicker_input", x: 561, y: 986, w: 168, h: 126),
        ])
        let note = MCPServer.duplicateIDsNote(snap)
        XCTAssertTrue(note.contains("#numberpicker_input ×2"), note)
        XCTAssertTrue(note.contains("Write one of these instead"), note)
    }

    /// **入れ子の一本鎖は曖昧ではない**(ambiguousLabelsNote の isSingleChain と同じ除外):
    /// 容器とその唯一の中身が同じ id を名乗るラッパー対は鳴らさない
    func testDuplicateIDsNoteIgnoresANestedWrapperPair() {
        let snap = screen([
            element(1, type: "button", id: "IconImage-TitleLabel-SubtitleLabel", label: "自宅、追加",
                    x: 0, y: 0, w: 300, h: 80, depth: 1),
            element(2, type: "other", id: "IconImage-TitleLabel-SubtitleLabel", label: "自宅、追加",
                    x: 0, y: 0, w: 300, h: 80, depth: 2),
        ])
        XCTAssertEqual(MCPServer.duplicateIDsNote(snap), "")
    }

    // MARK: - ③ 索引セレクタのアンカーは frame の包含で検証する

    /// 実測(Google マップの時刻ピッカー): 分の入力欄に `#divider`(「：」1文字、対象を包含しない)
    /// が祖先として誤選択されていた。preorder+depth の再構成は間引かれた木で叔父を拾いうるので、
    /// frame の包含を確かめる。除外後は正当な外側の祖先(picker_root)へ落ちる
    func testScopeSkipsAnUncleThatDoesNotContainTheElement() throws {
        let snap = screen([
            element(1, type: "other", id: "picker_root", x: 500, y: 980, w: 300, h: 150, depth: 1),
            element(2, type: "staticText", id: "divider", label: "：",
                    x: 535, y: 1021, w: 10, h: 56, depth: 2),
            element(3, type: "textField", id: "numberpicker_input",
                    x: 561, y: 986, w: 168, h: 126, depth: 3),
        ], width: 1080, height: 2400)
        XCTAssertEqual(MCPServer.uniqueScopeID(for: snap.elements[2], in: snap), "picker_root")
        let selector = try XCTUnwrap(MCPServer.scopedSelector(for: snap.elements[2], in: snap))
        XCTAssertEqual(selector, "#picker_root >> .textField[1]")
        XCTAssertFalse(selector.contains("divider"), selector)
    }

    /// 包含する祖先が1つも無ければ(叔父だけの木)、スコープを組まない —— nil のまま
    /// (`#divider >> …` のような当たらないセレクタを出すより安全)
    func testScopeReturnsNilWhenNoAncestorActuallyContainsTheElement() {
        let snap = screen([
            element(1, type: "staticText", id: "divider", label: "：",
                    x: 535, y: 1021, w: 10, h: 56, depth: 1),
            element(2, type: "textField", id: "numberpicker_input",
                    x: 561, y: 986, w: 168, h: 126, depth: 2),
        ], width: 1080, height: 2400)
        XCTAssertNil(MCPServer.uniqueScopeID(for: snap.elements[1], in: snap))
        XCTAssertNil(MCPServer.scopedSelector(for: snap.elements[1], in: snap))
    }

    /// 叔父が絡まない素直な入れ子では従来どおりスコープ付きセレクタが出る(退行していないこと)
    func testScopeStillWorksForAPlainContainedChild() throws {
        let snap = screen([
            element(1, type: "other", id: "row", x: 0, y: 0, w: 300, h: 200, depth: 1),
            element(2, type: "button", label: "送信", x: 20, y: 20, w: 100, h: 40, depth: 2),
        ])
        XCTAssertEqual(MCPServer.uniqueScopeID(for: snap.elements[1], in: snap), "row")
        let selector = try XCTUnwrap(MCPServer.scopedSelector(for: snap.elements[1], in: snap))
        XCTAssertEqual(selector, "#row >> .button[1]")
    }
}

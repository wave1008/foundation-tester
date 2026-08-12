// 曖昧ラベル/重複 id 注記の圧縮形(2026-08-12 の Apple マップ監査)。
//
// 同じ容器に並ぶ同型の繰り返しセル(map POI の隣接行など)は、代替セレクタが
// index-based(`[n]`)にしかならず、10件ぶん並べても読み手の役に立たない
// (実測: 注記15行 vs 要素30行)。`MCPServer.compactGroupLine` が判定と整形を持ち、
// `renderGroups`(ambiguousLabelsNote / duplicateIDsNote が共有する描画本体)から呼ばれる。
//
// 検知の類なので**両方向**を固定する: 畳むべきものが畳まれる / 畳んではいけないものが
// 従来どおり列挙されること。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPNoteCompactionTests: XCTestCase {

    private func element(_ ref: Int, type: String = "clickable", id: String? = nil,
                         label: String? = nil, frame: FTRect, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: depth)
    }

    private func snapshot(_ elements: [ElementInfo],
                          screen: FTRect = FTRect(x: 0, y: 0, width: 402, height: 874))
        -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                         elements: elements, truncatedCount: 0)
    }

    /// 容器 + N件の同型子(同じ id・ラベル無し)。子はすべて容器の frame に収まる —— これが
    /// `uniqueScopeElement` の包含条件で、無いと indexed 候補自体が生まれない
    private func repeatingCells(count: Int, containerID: String = "RouteSearchResultsTableView",
                                cellID: String = "Maps.PlaceTableViewCell") -> [ElementInfo] {
        let container = element(1, type: "other", id: containerID,
                                frame: FTRect(x: 0, y: 0, width: 400, height: 2000), depth: 1)
        let cells = (0..<count).map { i in
            element(100 + i, type: "clickable", id: cellID,
                    frame: FTRect(x: 0, y: Double(60 * i), width: 400, height: 56), depth: 2)
        }
        return [container] + cells
    }

    // MARK: - 圧縮される: 同一容器・同型・index-based のみ

    func testDuplicateIDsNoteCompactsARepeatingGroupUnderTheSameContainer() throws {
        let snap = snapshot(repeatingCells(count: 10))
        let note = MCPServer.duplicateIDsNote(snap)
        XCTAssertTrue(note.contains("#Maps.PlaceTableViewCell ×10"), note)
        XCTAssertTrue(note.contains("#RouteSearchResultsTableView"), note)
        XCTAssertTrue(note.contains("tap by ref instead"), note)
        XCTAssertTrue(note.contains("[100]") && note.contains("[105]"), note)
        // 圧縮形は index セレクタを一切出さない(ヘッダの凡例に "~" の説明はあるので、
        // ここで見るのは選択子の断片であって "~" 単体ではない)
        XCTAssertFalse(note.contains(".clickable["), note)
    }

    func testCompactGroupLineDirectlyForARepeatingGroup() throws {
        let snap = snapshot(repeatingCells(count: 10))
        let naming = MCPServer.SelectorNaming(snap)
        let cells = Array(snap.elements.dropFirst())
        let line = MCPServer.compactGroupLine(label: "#Maps.PlaceTableViewCell",
                                              matches: cells, naming: naming, in: snap)
        let unwrapped = try XCTUnwrap(line, "全員 index-based・同一スコープなので圧縮できるはず")
        XCTAssertTrue(unwrapped.contains("×10"), unwrapped)
        XCTAssertTrue(unwrapped.contains("#RouteSearchResultsTableView"), unwrapped)
        XCTAssertFalse(unwrapped.contains(".clickable["), unwrapped)
    }

    // MARK: - 圧縮されない: スコープ(親)が違う

    /// 実測(Google マップのタブ帯): 同じ id `#navigation_bar_item_icon_container` が
    /// 5つのタブそれぞれの下にある。どのタブかという情報が代替セレクタの祖先名に乗っているので、
    /// 畳むと読み手はどのタブの子か分からなくなる
    func testDuplicateIDsNoteDoesNotCompactWhenScopesDiffer() throws {
        let childID = "navigation_bar_item_icon_container"
        var elements: [ElementInfo] = []
        for (i, tabID) in ["explore_tab", "transportation_tab", "saved_tab",
                           "contribute_tab", "updates_tab"].enumerated() {
            let x = Double(i * 80)
            elements.append(element(1 + i * 2, type: "other", id: "\(tabID)_strip_button",
                                    frame: FTRect(x: x, y: 800, width: 80, height: 60), depth: 1))
            elements.append(element(2 + i * 2, type: "other", id: childID,
                                    frame: FTRect(x: x + 10, y: 810, width: 30, height: 30), depth: 2))
        }
        let note = MCPServer.duplicateIDsNote(snapshot(elements))
        XCTAssertTrue(note.contains("#\(childID) ×5"), note)
        // スコープが5つとも違うので、圧縮できず従来どおり各 index セレクタが出る
        // (添字は付かない —— 各タブの下に1件ずつなので asWritten が `[1]` を落とす。
        // 見るべきは「祖先付きのセレクタが要素ごとに並ぶ」ことで、添字の有無ではない)
        XCTAssertTrue(note.contains(">> .other"), note)
        XCTAssertTrue(note.contains("explore_tab_strip_button"), note)
        XCTAssertTrue(note.contains("saved_tab_strip_button"), note)
        XCTAssertFalse(note.contains("tap by ref instead"), note)
    }

    func testCompactGroupLineReturnsNilWhenScopesDiffer() throws {
        let childID = "navigation_bar_item_icon_container"
        var elements: [ElementInfo] = []
        for (i, tabID) in ["a_tab", "b_tab", "c_tab"].enumerated() {
            let x = Double(i * 80)
            elements.append(element(1 + i * 2, type: "other", id: "\(tabID)_strip_button",
                                    frame: FTRect(x: x, y: 800, width: 80, height: 60), depth: 1))
            elements.append(element(2 + i * 2, type: "other", id: childID,
                                    frame: FTRect(x: x + 10, y: 810, width: 30, height: 30), depth: 2))
        }
        let snap = snapshot(elements)
        let naming = MCPServer.SelectorNaming(snap)
        let children = elements.filter { $0.identifier == childID }
        XCTAssertNil(MCPServer.compactGroupLine(label: "#\(childID)", matches: children,
                                                naming: naming, in: snap))
    }

    // MARK: - 圧縮されない: 群の1件でも stable

    /// 5件が同じ id を共有するが、うち1件だけ画面で一意なラベルを持ち stable に書ける。
    /// stable な候補があるのに畳むと、そのセレクタが読み手から隠れてしまう
    func testDuplicateIDsNoteDoesNotCompactWhenOneMemberIsStable() throws {
        let sharedID = "row_item"
        var elements: [ElementInfo] = []
        for i in 0..<5 {
            elements.append(element(10 + i, type: "clickable", id: sharedID,
                                    label: i == 0 ? "自宅" : nil,
                                    frame: FTRect(x: 0, y: Double(60 * i), width: 400, height: 56),
                                    depth: 1))
        }
        let note = MCPServer.duplicateIDsNote(snapshot(elements))
        XCTAssertTrue(note.contains("#\(sharedID) ×5"), note)
        XCTAssertTrue(note.contains("自宅"), "stable な候補は隠れず出るはず: \(note)")
        XCTAssertFalse(note.contains("tap by ref instead"), note)
    }

    func testCompactGroupLineReturnsNilWhenOneMemberIsStable() throws {
        let sharedID = "row_item"
        let elements = (0..<5).map { i in
            element(10 + i, type: "clickable", id: sharedID, label: i == 0 ? "自宅" : nil,
                    frame: FTRect(x: 0, y: Double(60 * i), width: 400, height: 56), depth: 1)
        }
        let snap = snapshot(elements)
        let naming = MCPServer.SelectorNaming(snap)
        XCTAssertNil(MCPServer.compactGroupLine(label: "#\(sharedID)", matches: elements,
                                                naming: naming, in: snap))
    }

    // MARK: - 群の並びは同数タイでも決定的

    /// **同数タイは key の昇順**。決めないと順序が Dictionary の反復順(プロセスごとに変わる)
    /// に委ねられ、上限で打ち切るので「どの群が出るか」まで実行ごとに変わる。
    /// **注記の文字列を2回比べても差は出ない**(同一プロセス内では辞書順が固定)ので、
    /// 比較関数そのものを固定する
    func testTiedGroupsAreOrderedByKey() throws {
        XCTAssertTrue(MCPServer.groupPrecedes(key: "aaa", count: 3, otherKey: "zzz", otherCount: 3),
                      "同数なら key の昇順で aaa が先")
        XCTAssertFalse(MCPServer.groupPrecedes(key: "zzz", count: 3, otherKey: "aaa", otherCount: 3),
                       "逆向きは false(順序が一意に決まる)")
    }

    /// 件数の差があるときは従来どおり件数優先(タイ処理で件数順を壊していないこと)
    func testLargerGroupsStillComeFirst() throws {
        XCTAssertTrue(MCPServer.groupPrecedes(key: "zzz", count: 5, otherKey: "aaa", otherCount: 3))
        XCTAssertFalse(MCPServer.groupPrecedes(key: "aaa", count: 3, otherKey: "zzz", otherCount: 5))
    }

    /// 実際の注記でもタイが key 昇順で出ること(比較関数が sort に配線されている証拠)
    func testDuplicateIDsNoteOrdersTiedGroupsByKey() throws {
        let rows: [(String, Int)] = [("zzz_row", 4), ("aaa_row", 1)]
        let elements = rows.flatMap { id, base in
            (0..<3).map { i in
                element(base + i, type: "clickable", id: id, label: nil,
                        frame: FTRect(x: 0, y: Double(base + i) * 60, width: 400, height: 56),
                        depth: 1)
            }
        }
        let note = MCPServer.duplicateIDsNote(snapshot(elements))
        let a = try XCTUnwrap(note.range(of: "#aaa_row"))
        let z = try XCTUnwrap(note.range(of: "#zzz_row"))
        XCTAssertLessThan(a.lowerBound, z.lowerBound, "同数タイは key の昇順で並ぶはず: \(note)")
    }

    // MARK: - ambiguousLabelsNote 側でも同じ圧縮が効く

    func testAmbiguousLabelsNoteCompactsARepeatingGroupUnderTheSameContainer() throws {
        let container = element(1, type: "other", id: "RouteSearchResultsTableView",
                                frame: FTRect(x: 0, y: 0, width: 400, height: 2000), depth: 1)
        let cells = (0..<10).map { i in
            element(100 + i, type: "clickable", label: "乗り換え",
                    frame: FTRect(x: 0, y: Double(60 * i), width: 400, height: 56), depth: 2)
        }
        let note = MCPServer.ambiguousLabelsNote(snapshot([container] + cells))
        XCTAssertTrue(note.contains("\"乗り換え\" ×10"), note)
        XCTAssertTrue(note.contains("#RouteSearchResultsTableView"), note)
        XCTAssertTrue(note.contains("tap by ref instead"), note)
        XCTAssertFalse(note.contains(".clickable["), note)
    }

    // MARK: - 上限超えでも打ち切り表記は残る

    func testCompactedLineStillMarksTruncationPastTheDisplayLimit() throws {
        let snap = snapshot(repeatingCells(count: 12))
        let note = MCPServer.duplicateIDsNote(snap)
        XCTAssertTrue(note.contains("#Maps.PlaceTableViewCell ×12"), note)
        XCTAssertTrue(note.contains("(+6 more matches not shown)"), note)
        // 見えているのは上限(6件)だけ
        XCTAssertTrue(note.contains("[100]") && note.contains("[105]"), note)
        XCTAssertFalse(note.contains("[106]"), note)
    }
}

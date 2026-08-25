// duplicateRegionNote / missingPageContentNote(2026-08-13・jma.go.jp)。
//
// witness は Tests/Fixtures/RealAppSnapshots/ios-browser_jma_hscroll.json(横スクロール後、
// 前後のコピーが両方ツリーに残る)と and-browser_jma_notree.json(ブラウザ chrome しか
// ツリーに無く、ページ本体が丸ごと欠落)。ここは**合成木でのアルゴリズムそのものの単体テスト**
// (フィクスチャには依存しない)。NoteCoverageTests / SweepHarnessTests がフィクスチャ側の
// 回帰ゲート。

import XCTest
@testable import ftester_mcp
import FTCore

final class DuplicateRegionNoteTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil,
                         value: String? = nil, x: Double = 0, y: Double = 0,
                         width: Double = 50, height: Double = 20) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: width, height: height), depth: 3)
    }

    private func tree(_ elements: [ElementInfo],
                      screen: FTRect = FTRect(x: 0, y: 0, width: 1000, height: 1000)) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }

    /// 同じ行(y 差 ≤2pt)・違う列(x 差 >2pt)の複製行を作る。**2つのコピーは配列上でも
    /// 別々の連続区間にする**(実アプリの木と同じ形 —— 前のコピーの行がまとまって出た後、
    /// 離れた位置に後のコピーの行がまとまって出る。1件ずつ交互に並べると「連続する一致」に
    /// ならず、アルゴリズムが検出できる形にならない)。`dy` は2行目の y オフセット
    /// (2pt 以下なら「同じ行」、それより大きければ「別の行」の実験に使う)
    private func duplicatedRow(count: Int, firstRef: Int, secondRef: Int,
                               y: Double = 100, dy: Double = 1, dx: Double = 500,
                               secondType: String = "staticText") -> [ElementInfo] {
        var elements: [ElementInfo] = []
        for i in 0..<count {
            let label = "cell\(i)"
            elements.append(element(firstRef + i, "staticText", label: label,
                                    value: label, x: Double(i) * 60, y: y))
        }
        for i in 0..<count {
            let label = "cell\(i)"
            elements.append(element(secondRef + i, secondType, label: label,
                                    value: label, x: Double(i) * 60 + dx, y: y + dy))
        }
        return elements
    }

    // MARK: - duplicateRegionNote: 発火する形

    /// 境界: 同じ行・違う列が6要素そろうと発火する(duplicateRegionMinimumRun)
    func testFiresOnASixElementRunOnTheSameRowShiftedInX() {
        let elements = duplicatedRow(count: 6, firstRef: 1, secondRef: 101)
        let note = MCPServer.duplicateRegionNote(tree(elements))
        XCTAssertTrue(note.contains("6 elements"), note)
        XCTAssertTrue(note.contains("[1]"), note)
        XCTAssertTrue(note.contains("[101]"), note)
        XCTAssertTrue(note.contains("ft_screenshot"), "確かめる手段まで書くこと: \(note)")
    }

    // MARK: - duplicateRegionNote: 発火しない形

    /// 境界のもう片側: 5要素では届かない(duplicateRegionMinimumRun 未満)
    func testStaysSilentOnAFiveElementRun() {
        let elements = duplicatedRow(count: 5, firstRef: 1, secondRef: 101)
        XCTAssertEqual(MCPServer.duplicateRegionNote(tree(elements)), "")
    }

    /// **y の制約を単体で確かめる**: x は複製らしくずれている(dx>2 は満たす)のに、
    /// y が離れている(dy=300 > 2pt の許容)ので、6要素そろっていても発火しない。
    /// x 側の条件だけでは通らないことを確かめるため、あえて x をずらしてある
    /// (x も y も同じにすると「なぜ黙るか」が2つの条件のどちらのおかげか区別できない)
    func testStaysSilentWhenTheSecondCopyIsOnADifferentRowEvenIfXIsShifted() {
        let elements = duplicatedRow(count: 6, firstRef: 1, secondRef: 101, dy: 300)
        XCTAssertEqual(MCPServer.duplicateRegionNote(tree(elements)), "",
                       "同じ行でなければ複製ではない — x のずれだけで発火してはいけない")
    }

    /// **実アプリで最初に踏んだ誤検知の再現**(2026-08-13): 別々の2つの表が同じ見出し行を
    /// 名乗る形(x は同じ列のまま・y だけ離れている)。単純な「キーだけの最長一致」だと
    /// これが11要素で一致し、正当なページ構造を「複製」と誤って警告していた
    func testStaysSilentWhenTwoSiblingTablesShareAnIdenticalHeaderRow() {
        var elements: [ElementInfo] = []
        for i in 0..<8 {
            let label = "header\(i)"
            elements.append(element(1 + i, "staticText", label: label, value: label,
                                    x: Double(i) * 60, y: 100))
        }
        for i in 0..<8 {
            let label = "header\(i)"
            // **x は最初の表とまったく同じ**(列が揃った別の表という実際の形)——
            // dx を入れると「x がずれているから複製」という別の理由で黙ってしまい、
            // y の制約を試したことにならない
            elements.append(element(101 + i, "staticText", label: label, value: label,
                                    x: Double(i) * 60, y: 400))
        }
        let note = MCPServer.duplicateRegionNote(tree(elements))
        XCTAssertEqual(note, "",
                       "同じ見出しを共有する別々の表は複製ではない: \(note)")
    }

    /// 一致は type/label/value の3つ組(frame は位置の制約にしか使わない)。**型が違えば
    /// その位置で連鎖が切れる**: 6要素中5要素だけ複製の形(同じ行・ずれた列)で、最後の1要素
    /// だけ型が違うと、届く連鎖の長さは5に留まり(duplicateRegionMinimumRun 未満)発火しない
    func testTypeMismatchLimitsTheChainBelowTheThreshold() {
        let elements = duplicatedRow(count: 6, firstRef: 1, secondRef: 101, secondType: "staticText")
        var mismatched = elements
        // 2番目のコピーの最後の要素だけ image にする(label/value/位置関係は複製のまま)
        let last = mismatched.removeLast()
        mismatched.append(element(last.ref, "image", label: last.label, value: last.value,
                                  x: last.frame.x, y: last.frame.y))
        XCTAssertEqual(MCPServer.duplicateRegionNote(tree(mismatched)), "",
                       "型が違う位置では連鎖が切れ、残りは5要素までしか届かないはず")
    }

    // MARK: - missingPageContentNote: 発火する形

    private func chromeOnlyElements() -> [ElementInfo] {
        // 画面の上 10% だけブラウザ chrome を置き、残り 90% は何も無い(unrepresentedScreenFraction
        // 0.9 ≥ missingPageContentFractionThreshold)
        [
            element(1, "button", label: "戻る", x: 0, y: 0, width: 100, height: 100),
            element(2, "textField", id: "url_bar", value: "jma.go.jp/bosai/forecast/",
                    x: 100, y: 0, width: 800, height: 100),
        ]
    }

    func testFiresWhenOnlyBrowserChromeIsPublishedAndNoPageContentAtAll() {
        let note = MCPServer.missingPageContentNote(tree(chromeOnlyElements()))
        XCTAssertTrue(note.contains("no page content"), note)
        XCTAssertTrue(note.contains("ft_screenshot"), note)
    }

    // MARK: - missingPageContentNote: 発火しない形

    /// webView 要素が1つでもあれば黙る(webViewGapNote の管轄になる)
    func testStaysSilentWhenAWebViewElementIsPresent() {
        var elements = chromeOnlyElements()
        elements.append(element(3, "webView", label: "page", x: 0, y: 100, width: 10, height: 10))
        XCTAssertEqual(MCPServer.missingPageContentNote(tree(elements)), "")
    }

    /// **アドレス欄が無ければブラウザとは判定しない**(and-overflow の witness: 空白率だけなら
    /// 0.564 まで達するネイティブ画面がある。ブラウザに絞らないとそこまで拾ってしまう)
    func testStaysSilentWithoutAnAddressBar() {
        let elements = [element(1, "button", label: "何か", x: 0, y: 0, width: 100, height: 100)]
        XCTAssertEqual(MCPServer.missingPageContentNote(tree(elements)), "")
    }

    /// 空きが閾値未満なら黙る(chrome が画面の半分未満しか占めない=だいたい埋まっている)
    func testStaysSilentWhenTheUnrepresentedFractionIsBelowTheThreshold() {
        let elements = [
            element(1, "textField", id: "url_bar", value: "example.com",
                    x: 0, y: 0, width: 1000, height: 100),
            element(2, "staticText", label: "page content", x: 0, y: 100, width: 1000, height: 800),
        ]
        XCTAssertEqual(MCPServer.missingPageContentNote(tree(elements)), "")
    }

    // MARK: - unrepresentedScreenFraction(境界)

    /// 画面いっぱいの要素が1つあれば空き 0
    func testUnrepresentedFractionIsZeroWhenAnElementSpansTheWholeScreen() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let snapshot = tree([element(1, "webView", x: 0, y: 0, width: 400, height: 800)],
                            screen: screen)
        XCTAssertEqual(MCPServer.unrepresentedScreenFraction(snapshot), 0)
    }

    /// 要素が1つも無ければ画面全体が空き = 1
    func testUnrepresentedFractionIsOneWhenThereAreNoElements() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertEqual(MCPServer.unrepresentedScreenFraction(tree([], screen: screen)), 1)
    }

    /// screen.height <= 0 では判定できないので 0(嘘の警告を出さない)
    func testUnrepresentedFractionIsZeroWhenScreenHeightIsNotPositive() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 0)
        XCTAssertEqual(MCPServer.unrepresentedScreenFraction(tree([], screen: screen)), 0)
    }

    /// **同じ行に同種・同ラベルのセルが並んでいるだけでは発火しない**(2026-08-13 のレビュー指摘)。
    /// 区間の重なりを禁じていなかったため、`minimumRun=6` に対して7個並ぶと
    /// **自分自身と一致して**「同じ要素が2回出ている」と言っていた
    func testARowOfIdenticalCellsDoesNotMatchItself() {
        let row = (0..<8).map {
            ElementInfo(ref: $0 + 1, type: "staticText", identifier: nil, label: "",
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: Double($0) * 40, y: 100, width: 36, height: 20), depth: 1)
        }
        let note = MCPServer.duplicateRegionNote(
            SnapshotResponse(sessionBundleID: "com.example.app",
                             screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                             elements: row, truncatedCount: 0))
        XCTAssertEqual(note, "", "1行の並びを『2回出ている』と誤検知した: \(note)")
    }

    /// **一様な1行は「2回出ている」ではない**(2026-08-13 のレビュー指摘)。重なり禁止だけでは
    /// 足りず、同じキーのセルが 12 個並ぶと 6+6 の**重ならない**2区間に割れて発火していた。
    /// 本物の複製は「変化のある並びがそのまま繰り返される」形なので、区間が2種類以上の
    /// キーを含むことを要求する
    func testALongUniformRowIsNotReportedAsADuplicatedRegion() {
        let row = (0..<12).map {
            ElementInfo(ref: $0 + 1, type: "staticText", identifier: nil, label: "",
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: Double($0) * 40, y: 100, width: 36, height: 20), depth: 1)
        }
        let note = MCPServer.duplicateRegionNote(
            SnapshotResponse(sessionBundleID: "com.example.app",
                             screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                             elements: row, truncatedCount: 0))
        XCTAssertEqual(note, "", "一様な12個の並びを 6+6 の複製と読んだ: \(note)")
    }
}

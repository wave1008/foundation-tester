import XCTest
@testable import FTCore

/// set-of-mark 1行の形。**読み手はエージェント**なので、印の有無がそのまま
/// 「どう書くか」の判断材料になる(scroll = `scrollFrame:` に指定できる容器)。
final class SnapshotRenderingTests: XCTestCase {

    private func element(_ ref: Int, id: String?, scrollable: Bool?) -> ElementInfo {
        ElementInfo(ref: ref, type: "scrollView", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 100, width: 400, height: 500), depth: 1,
                    scrollable: scrollable)
    }

    func testScrollableContainerIsMarked() {
        let line = SnapshotRenderer.renderElement(element(1, id: "list_rows", scrollable: true))
        XCTAssertEqual(line, "[1] scrollView id=list_rows scroll (0,100 400x500)")
    }

    /// 申告できないエンジンでは nil。**印が無い = スクロールしない、ではない**ので、
    /// 何も足さない(推測の印を出すと読み手はそれを事実として使う)
    func testUndeclaredContainerGetsNoMark() {
        let line = SnapshotRenderer.renderElement(element(2, id: "list_rows", scrollable: nil))
        XCTAssertEqual(line, "[2] scrollView id=list_rows (0,100 400x500)")
    }

    /// ゼロ幅文字(Google マップの実データ「​​中央線​」等)は画面にもスナップショットにも
    /// 見えないので、コピーしたセレクタが FlowMatchMode.matches と必ず一致するよう出力からも除去する
    func testLabelStripsZeroWidthCharacters() {
        let el = ElementInfo(ref: 1, type: "staticText",
                              identifier: nil, label: "\u{200B}\u{200B}中央線\u{200D}\u{FEFF}\u{2060}",
                              value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 1)
        let line = SnapshotRenderer.renderElement(el)
        XCTAssertEqual(line, "[1] staticText \"中央線\" (0,0 100x20)")
    }

    /// label があるのに `empty` と出す自己矛盾を避ける(実観測: textField "東京駅" ... empty)。
    /// label も value も無いときだけ `empty`(意図は維持)
    func testTextFieldWithLabelIsNotMarkedEmpty() {
        let el = ElementInfo(ref: 1, type: "textField",
                              identifier: "search_omnibox_text_box", label: "東京駅",
                              value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 1)
        let line = SnapshotRenderer.renderElement(el)
        XCTAssertFalse(line.contains("empty"))
    }

    func testTextFieldWithoutLabelOrValueIsMarkedEmpty() {
        let el = ElementInfo(ref: 1, type: "textField",
                              identifier: "search_omnibox_text_box", label: nil,
                              value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 1)
        let line = SnapshotRenderer.renderElement(el)
        XCTAssertTrue(line.contains("empty"))
    }

    /// 同じ id を持つ要素が2つ以上あるスナップショットでは `id=` の直後に件数を付す
    /// (実観測: id=fab_icon が3要素・生成側が曖昧なセレクタを書いてしまう)
    func testRenderMarksDuplicateIdsWithCount() {
        let snapshot = SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: [
                ElementInfo(ref: 1, type: "button", identifier: "fab_icon", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1),
                ElementInfo(ref: 2, type: "button", identifier: "fab_icon", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 100, width: 10, height: 10), depth: 1),
                ElementInfo(ref: 3, type: "staticText", identifier: "title", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 200, width: 10, height: 10), depth: 1),
            ], truncatedCount: 0)
        let text = SnapshotRenderer.render(snapshot)
        XCTAssertTrue(text.contains("id=fab_icon ×2"))
        XCTAssertTrue(text.contains("id=title (0,200"))
        XCTAssertFalse(text.contains("id=title ×"))
    }
    /// **値だけでは意味が決まらない**ので範囲も出す。実測(2026-08-07): 同じ SUT の同じ
    /// スライダーが iOS では `value="50%"`、Android では**値すら無い**状態だった
    /// (`getRangeInfo` を採っていなかった)。パーセントへ正規化せず生値+範囲で出す決定
    func testSliderRangeIsRendered() {
        let e = ElementInfo(ref: 1, type: "slider", identifier: "slider_volume", label: nil,
                            value: "50", placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 2,
                            range: "0-100")
        let line = SnapshotRenderer.renderElement(e)
        XCTAssertTrue(line.contains("value=\"50\""), line)
        XCTAssertTrue(line.contains("range=0-100"), line)
    }

    /// 範囲を持たない要素では出さない(全要素に付くと表が太る)
    func testNonRangeElementsGetNoRange() {
        let e = ElementInfo(ref: 1, type: "button", identifier: "b", label: "OK", value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 2)
        XCTAssertFalse(SnapshotRenderer.renderElement(e).contains("range="))
    }

    // MARK: - 同一 id の大群を1行に畳む(2026-08-09。地図の POI 対策)

    /// `other` の葉を `count` 個 + その後ろに普通の要素1つ
    private func bulkSnapshot(count: Int, type: String = "other",
                              scrollable: Bool? = nil) -> SnapshotResponse {
        var elements: [ElementInfo] = []
        for i in 0..<count {
            elements.append(ElementInfo(ref: i + 1, type: type, identifier: "VKPointFeature",
                                        label: "POI\(i)", value: nil, placeholder: nil,
                                        enabled: true,
                                        frame: FTRect(x: Double(i), y: 10, width: 30, height: 30),
                                        depth: 3, scrollable: scrollable))
        }
        elements.append(ElementInfo(ref: count + 1, type: "button", identifier: "search",
                                    label: "検索", value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 500, width: 100, height: 40), depth: 3))
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }

    /// 畳んでも **ref では撃てる**(索引にラベルと ref が全件残る)のが条件。
    /// 実測で `#VKPointFeature` の ref タップは場所カードを開くので、消してはいけない
    func testBulkGroupCollapsesIntoOneLineWithARefIndex() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25), collapsingBulk: true)
        XCTAssertTrue(text.contains("[1-25] other id=VKPointFeature ×25 collapsed"), text)
        // **逃げ道はツール名まで書く**: この行は ft_scroll_to の結果にも出るが、
        // あちらは expandBulk を受け取らない
        XCTAssertTrue(text.contains("call ft_snapshot with expandBulk: true"), text)
        XCTAssertTrue(text.contains("POI0[1]"), text)
        XCTAssertTrue(text.contains("POI24[25]"), text)
        // 畳んだ行の frame は出さない / 畳んでいない要素は従来どおり
        XCTAssertFalse(text.contains("(0,10 30x30)"), text)
        XCTAssertTrue(text.contains("[26] button \"検索\" id=search (0,500 100x40)"), text)
    }

    func testBulkGroupIsNotCollapsedByDefault() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25))
        XCTAssertFalse(text.contains("collapsed"), text)
        XCTAssertTrue(text.contains("[1] other \"POI0\" id=VKPointFeature ×25 (0,10 30x30)"), text)
    }

    /// 下限未満は畳まない(検索候補の `#TitleLabel ×10` のような**中身の一覧**を守る)
    func testGroupBelowTheMinimumStaysExpanded() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: SnapshotRenderer.bulkGroupMinimum - 1),
                                           collapsingBulk: true)
        XCTAssertFalse(text.contains("collapsed"), text)
    }

    /// **件数を直に書く**: 上の相対テストは `bulkGroupMinimum` を参照しているので、
    /// 下限を下げる変異と一緒に動いて素通しする(2026-08-09 の変異テストで実際に素通しした)。
    /// 数個の同 id の飾りは1行ずつ出る、が守りたい契約
    func testHandfulOfSameIdElementsStaysExpanded() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 5), collapsingBulk: true)
        XCTAssertFalse(text.contains("collapsed"), text)
        XCTAssertTrue(text.contains("[1] other \"POI0\" id=VKPointFeature ×5 (0,10 30x30)"), text)
    }

    /// **`other` の葉だけ**。型が付いている一覧(staticText の行など)は中身なので畳まない
    func testTypedGroupIsNotCollapsed() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25, type: "staticText"),
                                           collapsingBulk: true)
        XCTAssertFalse(text.contains("collapsed"), text)
    }

    /// スクロール容器は `scrollFrame:` の候補なので畳まない
    func testScrollableGroupIsNotCollapsed() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25, scrollable: true),
                                           collapsingBulk: true)
        XCTAssertFalse(text.contains("collapsed"), text)
    }

    /// 印(⚠️scroll-leftover)が付いた要素を含む群は畳まない —— 印は行ごとに読ませるためにある
    func testFlaggedGroupIsNotCollapsed() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25),
                                           flagging: [7: "⚠️scroll-leftover"],
                                           collapsingBulk: true)
        XCTAssertFalse(text.contains("collapsed"), text)
        XCTAssertTrue(text.contains("⚠️scroll-leftover"), text)
    }

    /// 子を持つ要素は畳まない(畳むと子の行だけが親を失って残る)
    func testGroupWithChildrenIsNotCollapsed() {
        var elements: [ElementInfo] = []
        for i in 0..<25 {
            elements.append(ElementInfo(ref: i * 2 + 1, type: "other", identifier: "Row",
                                        label: nil, value: nil, placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: Double(i) * 10, width: 30, height: 30),
                                        depth: 3))
            elements.append(ElementInfo(ref: i * 2 + 2, type: "staticText", identifier: "t\(i)",
                                        label: "x", value: nil, placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: Double(i) * 10, width: 30, height: 30),
                                        depth: 4))
        }
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: elements, truncatedCount: 0)
        XCTAssertFalse(SnapshotRenderer.render(snapshot, collapsingBulk: true).contains("collapsed"))
    }
}

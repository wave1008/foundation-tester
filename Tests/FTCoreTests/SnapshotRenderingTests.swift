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

    /// 印(⚠️scroll-leftover)が付いた要素は**その1件だけ**畳まない —— 印は行ごとに
    /// 読ませるためにある。**群ごと畳むのをやめない**(2026-08-09 に all-or-nothing を撤回。
    /// 実機では 158 件中1件の巻き添えで全部が個別列挙になっていた。PartialBulkCollapseTests)
    func testFlaggedMemberIsExcludedButTheGroupStillCollapses() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25),
                                           flagging: [7: "⚠️scroll-leftover"],
                                           collapsingBulk: true)
        XCTAssertTrue(text.contains("id=VKPointFeature ×24 collapsed"), text)
        XCTAssertTrue(text.contains("⚠️scroll-leftover"), text)
        XCTAssertTrue(text.contains("1 more with this id are listed separately below"), text)
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

    // MARK: - interactiveOnly(レイアウト専用の行を隠す)

    /// 実測(2026-08-09・Google マップ Android)の形を縮尺: 88 行のうち意味のある行は 10 行程度で、
    /// 残りは子と同じ矩形のレイアウト容器だった
    private func mixedSnapshot() -> SnapshotResponse {
        let frame = FTRect(x: 0, y: 0, width: 100, height: 40)
        let elements = [
            ElementInfo(ref: 1, type: "button", identifier: "ok", label: "OK", value: nil,
                        placeholder: nil, enabled: true, frame: frame, depth: 1),
            ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "本文", value: nil,
                        placeholder: nil, enabled: true, frame: frame, depth: 2),
            // id だけを持つレイアウト容器 = 隠したい当人
            ElementInfo(ref: 3, type: "other", identifier: "icon_container", label: nil,
                        value: nil, placeholder: nil, enabled: true, frame: frame, depth: 2),
            ElementInfo(ref: 4, type: "other", identifier: nil, label: nil, value: nil,
                        placeholder: nil, enabled: true, frame: frame, depth: 3),
            ElementInfo(ref: 5, type: "other", identifier: "list", label: nil, value: nil,
                        placeholder: nil, enabled: true, frame: frame, depth: 1, scrollable: true),
        ]
        return SnapshotResponse(sessionBundleID: "com.example.app",
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }

    func testInteractiveOnlyHidesLayoutContainers() {
        let text = SnapshotRenderer.render(mixedSnapshot(), interactiveOnly: true)
        XCTAssertFalse(text.contains("icon_container"), text)
        XCTAssertTrue(text.contains("2 layout-only line(s) hidden"), text)
    }

    /// 操作できる型・文字を持つもの・スクロール容器は残す(`scrollFrame:` に渡せなくなるため)
    func testInteractiveOnlyKeepsWhatTheReaderCanActuallyUse() {
        let text = SnapshotRenderer.render(mixedSnapshot(), interactiveOnly: true)
        XCTAssertTrue(text.contains("id=ok"), text)
        XCTAssertTrue(text.contains("\"本文\""), text)
        XCTAssertTrue(text.contains("id=list"), text)
    }

    /// **印の付いた行は隠さない** —— 印は行ごとに読ませるためにある
    func testInteractiveOnlyNeverHidesAFlaggedRow() {
        let text = SnapshotRenderer.render(mixedSnapshot(), flagging: [3: "⚠️scroll-leftover"],
                                           interactiveOnly: true)
        XCTAssertTrue(text.contains("icon_container"), text)
        XCTAssertTrue(text.contains("⚠️scroll-leftover"), text)
    }

    /// 既定は従来どおり全行(隠す注記も出さない)
    func testDefaultRenderStillListsEverything() {
        let text = SnapshotRenderer.render(mixedSnapshot())
        XCTAssertTrue(text.contains("icon_container"), text)
        XCTAssertFalse(text.contains("layout-only"), text)
    }
}

/// **群の中の1件で全滅しない**(D-2。2026-08-09 に実機で確定)。
/// Apple マップの経路一覧では `#VKPointFeature` 158 件のうち `isLeaf` が false なのは
/// **1件だけ**で、理由は「preorder 上の次がたまたま深い別要素だった」。それで 158 行が
/// 個別に出るのは、畳み込みの目的(読める量に収める)を丸ごと損なう。
final class PartialBulkCollapseTests: XCTestCase {

    /// POI を n 件 + 末尾に「次がより深い」状況を作る要素を置く
    private func snapshot(poi: Int, outlierIsDeepNext: Bool) -> SnapshotResponse {
        var elements: [ElementInfo] = []
        for i in 0..<poi {
            elements.append(ElementInfo(ref: i + 1, type: "other", identifier: "VKPointFeature",
                                        label: "POI\(i)", value: nil, placeholder: nil,
                                        enabled: true,
                                        frame: FTRect(x: Double(i), y: 10, width: 30, height: 30),
                                        depth: 8))
        }
        if outlierIsDeepNext {
            // 実機で観測した形: 群の直後に**より深い**別要素が来るので、最後の POI が葉でなくなる
            elements.append(ElementInfo(ref: poi + 1, type: "button", identifier: "UserLocationButton",
                                        label: "現在地", value: nil, placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: 500, width: 40, height: 40),
                                        depth: 10))
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }

    /// **1件だけ外れても残りは畳む**。外れた1件は自分の位置に個別行として残る
    func testOneOutlierDoesNotDefeatTheWholeGroup() {
        let text = SnapshotRenderer.render(snapshot(poi: 25, outlierIsDeepNext: true),
                                           collapsingBulk: true)
        XCTAssertTrue(text.contains("id=VKPointFeature ×24 collapsed"), text)
        // 外れた1件(最後の POI)は個別行で残る = 手順から消えない
        XCTAssertTrue(text.contains("[25] other \"POI24\""), text)
        // **一部だけ畳んだことを言う**(同じ id が2箇所に出る理由を読み手に渡す)
        XCTAssertTrue(text.contains("1 more with this id are listed separately below"), text)
    }

    /// 印の付いた要素も同じ扱い(印は行ごとに読ませるので畳まない・残りは畳む)
    func testFlaggedMemberIsLeftOutButTheRestCollapse() {
        let snap = snapshot(poi: 25, outlierIsDeepNext: false)
        let text = SnapshotRenderer.render(snap, flagging: [7: "⚠️scroll-leftover"],
                                           collapsingBulk: true)
        XCTAssertTrue(text.contains("id=VKPointFeature ×24 collapsed"), text)
        XCTAssertTrue(text.contains("⚠️scroll-leftover"), text)
    }

    /// **畳める分が下限に届かないなら畳まない**(数件を畳んでも読む量は減らない)
    func testTooFewQualifyingMembersMeansNoFold() {
        let snap = snapshot(poi: 25, outlierIsDeepNext: false)
        var flags: [Int: String] = [:]
        for ref in 1...10 { flags[ref] = "⚠️offscreen" }   // 残り15件 < 20
        let text = SnapshotRenderer.render(snap, flagging: flags, collapsingBulk: true)
        XCTAssertFalse(text.contains("collapsed"), text)
    }

    /// 全員が条件を満たすときは従来どおり(「別に出ている」とは言わない)
    func testAllQualifyingStillFoldsAsBefore() {
        let text = SnapshotRenderer.render(snapshot(poi: 25, outlierIsDeepNext: false),
                                           collapsingBulk: true)
        XCTAssertTrue(text.contains("id=VKPointFeature ×25 collapsed"), text)
        XCTAssertFalse(text.contains("listed separately below"), text)
    }
}

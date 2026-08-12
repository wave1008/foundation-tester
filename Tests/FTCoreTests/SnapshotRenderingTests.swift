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

    /// **ラベルで一意に特定できる行では ×N を省く**(2026-08-10): id の共有件数は「ラベルだけで
    /// 指せるか」には無関係。実測(iOS の検索候補): セル id が10行で共有され、全行に無意味な
    /// ×10 が付いていた
    func testRenderOmitsTheCountWhenEachSharedIdHasAUniqueLabel() {
        let snapshot = SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: [
                ElementInfo(ref: 1, type: "cell", identifier: "row", label: "立川駅",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1),
                ElementInfo(ref: 2, type: "cell", identifier: "row", label: "東京駅",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 100, width: 10, height: 10), depth: 1),
            ], truncatedCount: 0)
        let text = SnapshotRenderer.render(snapshot)
        XCTAssertFalse(text.contains("×2"), text)
        XCTAssertTrue(text.contains("id=row (0,0"), text)
        XCTAssertTrue(text.contains("id=row (0,100"), text)
    }

    /// 同じ id・同じラベルが並ぶ形は引き続き ×N を出す(ラベルだけでは指せない)
    func testRenderKeepsTheCountWhenTheSharedIdAlsoSharesTheLabel() {
        let snapshot = SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: [
                ElementInfo(ref: 1, type: "cell", identifier: "row", label: "候補",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1),
                ElementInfo(ref: 2, type: "cell", identifier: "row", label: "候補",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 100, width: 10, height: 10), depth: 1),
            ], truncatedCount: 0)
        let text = SnapshotRenderer.render(snapshot)
        XCTAssertTrue(text.contains("id=row ×2"), text)
    }

    /// ラベルの無い要素では従来どおり id の件数で判断する(空ラベルは「一意」と数えない)
    func testRenderKeepsTheCountWhenLabelsAreEmpty() {
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
            ], truncatedCount: 0)
        XCTAssertTrue(SnapshotRenderer.render(snapshot).contains("id=fab_icon ×2"))
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

    /// 畳んでも **ref では撃てる**(索引の先頭サンプルにラベルと ref が残る)のが条件。
    /// 実測で `#VKPointFeature` の ref タップは場所カードを開くので、消してはいけない。
    /// **索引の全件は出さない**(2026-08-10): 235件級の実測で索引の全件印字が出力の7割を
    /// 占めていたため、先頭 `bulkIndexSampleCount` 件だけに削る(件数の検証は
    /// testBulkIndexIsTruncatedToASampleWithACountOfTheRest)
    func testBulkGroupCollapsesIntoOneLineWithARefIndex() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25), collapsingBulk: true)
        XCTAssertTrue(text.contains("[1-25] other id=VKPointFeature ×25 collapsed"), text)
        // **逃げ道はツール名まで書く**: この行は ft_scroll_to の結果にも出る。両方が
        // expandBulk を受け取る(2026-08-10 に ft_scroll_to も対応)
        XCTAssertTrue(text.contains(
            "pass expandBulk: true (ft_snapshot and ft_scroll_to both take it) to list them in full"),
            text)
        XCTAssertTrue(text.contains("POI0[1]"), text)
        // 索引はサンプルのみ(25件のうち先頭12件)なので、末尾の POI24 はここには出ない
        XCTAssertFalse(text.contains("POI24[25]"), text)
        // 畳んだ行の frame は出さない / 畳んでいない要素は従来どおり
        XCTAssertFalse(text.contains("(0,10 30x30)"), text)
        XCTAssertTrue(text.contains("[26] button \"検索\" id=search (0,500 100x40)"), text)
    }

    /// **索引は先頭 `bulkIndexSampleCount` 件だけ + 残りは件数のみの1行**
    /// (2026-08-10。Apple マップ #VKPointFeature ×235 の実測で索引の全件印字が
    /// 出力の7割前後を占めていた対策)
    func testBulkIndexIsTruncatedToASampleWithACountOfTheRest() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25), collapsingBulk: true)
        XCTAssertEqual(SnapshotRenderer.bulkIndexSampleCount, 12)
        XCTAssertTrue(text.contains("POI0[1]"), text)
        XCTAssertTrue(text.contains("POI11[12]"), text)
        // 13件目以降は索引に出ない
        XCTAssertFalse(text.contains("POI12[13]"), text)
        XCTAssertFalse(text.contains("POI24[25]"), text)
        // 残り13件(25-12)は件数だけの1行にまとまる
        XCTAssertTrue(text.contains("(+13 more — expandBulk: true lists them all)"), text)
    }

    /// expandBulk 相当(collapsingBulk: false)では索引ではなく個別行がそのまま全件出る
    /// (索引のサンプリングは畳んだときだけの話で、こちらには影響しない)
    func testBulkGroupIsNotCollapsedByDefault() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25))
        XCTAssertFalse(text.contains("collapsed"), text)
        // **ラベルがそれぞれ一意なので ×25 は出ない**(2026-08-10・Fix4): id の共有件数は
        // ラベルだけで指せるかとは無関係。id そのものは残る(scrollFrame 等に使える)
        XCTAssertTrue(text.contains("[1] other \"POI0\" id=VKPointFeature (0,10 30x30)"), text)
        XCTAssertTrue(text.contains("[25] other \"POI24\" id=VKPointFeature (24,10 30x30)"), text)
        XCTAssertFalse(text.contains("×25"), text)
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
        // ラベルが一意なので ×5 は出ない(2026-08-10・Fix4)
        XCTAssertTrue(text.contains("[1] other \"POI0\" id=VKPointFeature (0,10 30x30)"), text)
        XCTAssertFalse(text.contains("×5"), text)
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

    /// **印(⚠️scroll-leftover)が付いた要素も畳む**(2026-08-10・Fix2): タップ時に RefGuard が
    /// 改めて警告するので(testTapWarnsInsteadOfRefusingForAScrollLeftover)、snapshot 時点の
    /// 個別列挙は冗長 —— 地図 POI 231件中40件が印付きというだけで出力の半分を占めていた実害。
    /// 群に何件混じっているかは見出しの内訳(flagSummary)が言う
    func testFlaggedMemberIsIncludedInTheFoldWithAFlagCount() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25),
                                           flagging: [7: "⚠️scroll-leftover"],
                                           collapsingBulk: true)
        XCTAssertTrue(text.contains("id=VKPointFeature ×25 collapsed"), text)
        XCTAssertTrue(text.contains("1 ⚠️scroll-leftover among them"), text)
        XCTAssertFalse(text.contains("listed separately below"), text)
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
        XCTAssertTrue(text.contains("2 layout-only or duplicate-content line(s) hidden"), text)
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

    // MARK: - interactiveOnly + bulk 群(2026-08-10。索引を隠すのは interactiveOnly の趣旨と一致)

    /// bulk 群の要素はラベルを持つので isSubstantive=true —— interactiveOnly でも
    /// **群そのものは消えない**(見出し1行に畳まれるだけ)。索引(ラベル+ref)は1件も出ない
    func testInteractiveOnlyCollapsesBulkGroupToHeadlineOnly() {
        let text = SnapshotRenderer.render(bulkSnapshot(count: 25), collapsingBulk: true,
                                           interactiveOnly: true)
        XCTAssertTrue(text.contains("[1-25] other id=VKPointFeature ×25 collapsed"), text)
        XCTAssertTrue(text.contains("index hidden by interactiveOnly"), text)
        XCTAssertTrue(text.contains(
            "call without interactiveOnly for the label/ref index, or with expandBulk: true"),
            text)
        XCTAssertFalse(text.contains("POI0[1]"), text)
        XCTAssertFalse(text.contains("POI24[25]"), text)
        // 通常どおり畳んでいない要素は残る
        XCTAssertTrue(text.contains("[26] button \"検索\" id=search (0,500 100x40)"), text)
    }

    /// **隠すのは描画だけ**: interactiveOnly の有無で同じスナップショットを描いても、
    /// bulk 見出しの span(=先頭/末尾 ref を含む)は変わらない —— ref/frame の間引きや
    /// 振り直しはしていないことの確認
    func testInteractiveOnlyDoesNotChangeTheBulkHeadlineSpan() {
        let withIndex = SnapshotRenderer.render(bulkSnapshot(count: 25), collapsingBulk: true)
        let headlineOnly = SnapshotRenderer.render(bulkSnapshot(count: 25), collapsingBulk: true,
                                                   interactiveOnly: true)
        XCTAssertTrue(withIndex.contains("[1-25] other id=VKPointFeature ×25 collapsed"),
                      withIndex)
        XCTAssertTrue(headlineOnly.contains("[1-25] other id=VKPointFeature ×25 collapsed"),
                      headlineOnly)
    }

    // MARK: - 切り詰めラベル注記の例(2026-08-10。「, 」を含む例が複数要素の列挙に読める事故対策)

    private func snapshotWithOneLabel(_ label: String) -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [ElementInfo(ref: 1, type: "staticText", identifier: nil, label: label,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 300, height: 40), depth: 1)],
            truncatedCount: 0)
    }

    /// **実害の再現**(2026-08-06): 先頭12文字の中に「, 」があると `(e.g. *新宿, JR JA*)` の
    /// ように複数要素の列挙に読め、endsWith セレクタを渡して7スクロール空振りした。
    /// 区切りの手前で止め、かつ引用符で1つの文字列だと分かる形にする
    func testTruncatedLabelNoteCutsExampleAtDelimiterAndQuotesIt() {
        let label = "新宿, JR JA, " + String(repeating: "X", count: 30)
        let note = SnapshotRenderer.truncatedLabelNote(snapshotWithOneLabel(label))
        XCTAssertTrue(note?.contains("(e.g. \"*新宿*\" — the *text* form matches anywhere") == true,
                      note ?? "<nil>")
        // 区切りの手前で止めるので、後半の「JR JA」は例に含まれない
        XCTAssertFalse(note?.contains("JR JA") ?? false, note ?? "<nil>")
        XCTAssertTrue(note?.contains("Use a partial match built from the start of the label"
            ) == true, note ?? "<nil>")
    }

    /// 区切りが先頭12文字の先頭にあり、そこで切ると空文字列になるケースだけ
    /// 従来どおり先頭12文字をそのまま使う(空の例より12文字の方がまだ手掛かりになる)
    func testTruncatedLabelNoteFallsBackToTwelveCharsWhenCuttingWouldBeEmpty() {
        let label = ", " + String(repeating: "A", count: 50)
        let note = SnapshotRenderer.truncatedLabelNote(snapshotWithOneLabel(label))
        XCTAssertTrue(note?.contains("(e.g. \"*, AAAAAAAAAA*\"") == true, note ?? "<nil>")
    }

    /// truncatedSelectorHint の例も同じ形(引用符つき)で出す
    func testTruncatedSelectorHintQuotesItsExample() {
        let label = "新宿, JR JA, " + String(repeating: "X", count: 30)
        let snap = snapshotWithOneLabel(label)
        let asPrinted = String(label.prefix(SnapshotRenderer.labelDisplayLimit)) + "…"
        let hint = SnapshotRenderer.truncatedSelectorHint(asPrinted, in: snap)
        XCTAssertTrue(hint?.contains("(e.g. \"*新宿*\").") == true, hint ?? "<nil>")
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

    /// 印の付いた要素も畳む(2026-08-10・Fix2。件数は見出しの内訳が言う)
    func testFlaggedMemberIsIncludedInTheFoldWithAFlagCount() {
        let snap = snapshot(poi: 25, outlierIsDeepNext: false)
        let text = SnapshotRenderer.render(snap, flagging: [7: "⚠️scroll-leftover"],
                                           collapsingBulk: true)
        XCTAssertTrue(text.contains("id=VKPointFeature ×25 collapsed"), text)
        XCTAssertTrue(text.contains("1 ⚠️scroll-leftover among them"), text)
    }

    /// interactiveOnly の見出しでは旗の内訳を「leaves」の直後に置く(interactiveOnly の節へ
    /// 挟むと em-dash 節が連なって読めない)
    func testInteractiveOnlyHeadlinePutsFlagCountsRightAfterLeaves() {
        let snap = snapshot(poi: 25, outlierIsDeepNext: false)
        let text = SnapshotRenderer.render(snap, flagging: [7: "⚠️scroll-leftover"],
                                           collapsingBulk: true, interactiveOnly: true)
        XCTAssertTrue(text.contains(
            "non-interactive leaves — 1 ⚠️scroll-leftover among them; index hidden"), text)
    }

    /// **畳める分が下限に届かないなら畳まない**(数件を畳んでも読む量は減らない)。
    /// disqualify する条件は type にする —— 印はもう disqualify 要因ではない(Fix2)ので、
    /// 印だけでは 20 件の下限を割り込ませられない
    func testTooFewQualifyingMembersMeansNoFold() {
        var elements: [ElementInfo] = []
        for i in 0..<25 {
            elements.append(ElementInfo(ref: i + 1, type: i < 10 ? "button" : "other",
                                        identifier: "VKPointFeature", label: "POI\(i)", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: Double(i), y: 10, width: 30, height: 30),
                                        depth: 8))
        }
        let snap = SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                    elements: elements, truncatedCount: 0)
        let text = SnapshotRenderer.render(snap, collapsingBulk: true)
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

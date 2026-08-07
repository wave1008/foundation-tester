import XCTest
@testable import FTCore

/// `scrollFrame:` 候補の列挙。**デバイスを必要としない層**なので、ここで落とせない誤りは
/// エージェントに嘘を返す形(= 存在しない容器を勧める・分からないのに「無い」と言う)で表に出る。
final class ScrollFrameCandidatesTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen,
                         elements: elements, truncatedCount: 0)
    }

    private func element(_ ref: Int, type: String = "other", id: String? = nil,
                         label: String? = nil, frame: FTRect, scrollable: Bool? = nil,
                         depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: depth,
                    scrollable: scrollable)
    }

    // MARK: - candidates

    func testDeclaredScrollableIsACandidateWithItsIdSelector() {
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 400, height: 500),
                    scrollable: true),
            element(2, id: "header", frame: FTRect(x: 0, y: 0, width: 400, height: 100)),
        ])
        let found = ScrollFrameCandidates.candidates(in: snap)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.selector, "#list_rows")
        XCTAssertEqual(found.first?.ref, 1)
    }

    /// 申告できないエンジン(Compose/Flutter の in-app)は全要素が nil。
    /// **「候補なし」ではなく「分からない」**なので、黙る側に倒れていることを固定する
    func testEngineThatCannotDeclareScrollableYieldsNothingAndNoNote() {
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 400, height: 500)),
            element(2, id: "row_1", frame: FTRect(x: 0, y: 110, width: 400, height: 40), depth: 2),
        ])
        XCTAssertTrue(ScrollFrameCandidates.candidates(in: snap).isEmpty)
        XCTAssertNil(ScrollFrameCandidates.note(snap))
    }

    func testOffscreenContainerIsNotACandidate() {
        let snap = snapshot([
            element(1, id: "drawer", frame: FTRect(x: -400, y: 0, width: 400, height: 800),
                    scrollable: true),
        ])
        XCTAssertTrue(ScrollFrameCandidates.candidates(in: snap).isEmpty)
    }

    /// Android は容器と中身の両方が isScrollable を立てることがある。
    /// 同じ矩形は1つに畳み、**名指しできる方**を残す
    func testNestedSameFrameCollapsesKeepingTheNameableOne() {
        let frame = FTRect(x: 0, y: 100, width: 400, height: 500)
        let snap = snapshot([
            element(1, frame: frame, scrollable: true),
            element(2, id: "list_rows", frame: frame, scrollable: true, depth: 2),
        ])
        let found = ScrollFrameCandidates.candidates(in: snap)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.selector, "#list_rows")
    }

    func testLabelIsUsedWhenThereIsNoIdButNotWhenItIsTooLongOrQuoted() {
        let frame = FTRect(x: 0, y: 100, width: 400, height: 200)
        XCTAssertEqual(ScrollFrameCandidates.selector(
            for: element(1, label: "Recent items", frame: frame, scrollable: true)),
                       "\"Recent items\"")
        // 切り詰めると別のセレクタになるので、長いラベルは名指しできない扱い
        let long = String(repeating: "a", count: ScrollFrameCandidates.maxLabelLength + 1)
        XCTAssertNil(ScrollFrameCandidates.selector(
            for: element(2, label: long, frame: frame, scrollable: true)))
        XCTAssertNil(ScrollFrameCandidates.selector(
            for: element(3, label: "say \"hi\"", frame: frame, scrollable: true)))
    }

    // MARK: - note

    func testNoteStaysSilentForASingleScrollArea() {
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 400, height: 500),
                    scrollable: true),
        ])
        XCTAssertNil(ScrollFrameCandidates.note(snap))
    }

    func testNoteListsBothAreasAndNamesTheOneWithoutAnId() {
        let snap = snapshot([
            element(1, id: "chips", frame: FTRect(x: 0, y: 60, width: 400, height: 60),
                    scrollable: true),
            element(2, frame: FTRect(x: 0, y: 120, width: 400, height: 500), scrollable: true),
        ])
        let text = ScrollFrameCandidates.note(snap) ?? ""
        XCTAssertTrue(text.contains("2 scroll areas"), text)
        XCTAssertTrue(text.contains("#chips"), text)
        XCTAssertTrue(text.contains("(0,120 400x500 — no id)"), text)
        XCTAssertTrue(text.contains("scrollFrame:"), text)
        XCTAssertTrue(text.hasSuffix("\n"), text)
    }

    /// **1つも名指しできない画面では scrollFrame を勧めない**(2026-08-08。in-app が版57で
    /// Compose の素の容器を出すようになった —— testTag の無い容器ばかりの画面で
    /// 「scrollFrame: を渡せ」と言っても渡せる書き方が無い。ft_drag で領域内を掴む案内に切り替える)
    func testNoteAdvisesDragWhenNoCandidateCanBeNamed() {
        let snap = snapshot([
            element(1, frame: FTRect(x: 0, y: 60, width: 400, height: 60), scrollable: true),
            element(2, frame: FTRect(x: 0, y: 120, width: 400, height: 500), scrollable: true),
        ])
        let text = ScrollFrameCandidates.note(snap) ?? ""
        XCTAssertTrue(text.contains("2 scroll areas"), text)
        XCTAssertTrue(text.contains("ft_drag"), text)
        XCTAssertFalse(text.contains("Pass scrollFrame:"), text)
    }

    /// **同名 id が並ぶ画面では添字と矩形と軸まで出す**。実測(2026-08-07・Google マップ Android):
    /// `#recycler_view / #search_list_layout / #recycler_view / #recycler_view` と並べていたので、
    /// 「どれか1つを渡せ」と言いながら渡せる書き方が無かった。
    /// 添字は**木の全要素の中の順番**(スクロールしない同名要素も番号を消費する)
    func testAmbiguousIdsAreListedWithIndexRectAndAxis() {
        let snap = snapshot([
            // 横チップ行(preorder 先頭 = 添字なしなら黙ってこれが選ばれていた)
            element(1, id: "recycler_view", frame: FTRect(x: 0, y: 300, width: 400, height: 126),
                    scrollable: true),
            element(2, id: "search_list_layout",
                    frame: FTRect(x: 0, y: 430, width: 380, height: 60), scrollable: true),
            // スクロールしない同名要素。**候補ではないが添字は消費する**
            element(3, id: "recycler_view", frame: FTRect(x: 0, y: 740, width: 400, height: 20)),
            element(4, id: "recycler_view", frame: FTRect(x: 0, y: 490, width: 200, height: 290),
                    scrollable: true),
        ])
        let text = ScrollFrameCandidates.note(snap) ?? ""
        XCTAssertTrue(text.contains("#recycler_view[0] (0,300 400x126) wide"), text)
        XCTAssertTrue(text.contains("#recycler_view[2] (0,490 200x290) tall"), text)
        // 一意なものは今までどおり名前だけ(読みやすさを落とさない)
        XCTAssertTrue(text.contains("/ #search_list_layout /"), text)
    }

    func testNoteCapsTheListing() {
        let snap = snapshot((1...6).map {
            element($0, id: "area_\($0)",
                    frame: FTRect(x: 0, y: Double($0) * 100, width: 400, height: 90),
                    scrollable: true)
        })
        let text = ScrollFrameCandidates.note(snap) ?? ""
        XCTAssertTrue(text.contains("6 scroll areas"), text)
        XCTAssertTrue(text.contains("(+2 more)"), text)
        XCTAssertFalse(text.contains("#area_5"), text)
    }

    // MARK: - selector(matching:)

    func testSelectorMatchingPicksTheOverlappingDeclaredContainer() {
        let snap = snapshot([
            element(1, id: "chips", frame: FTRect(x: 0, y: 60, width: 400, height: 60),
                    scrollable: true),
            element(2, id: "list_rows", frame: FTRect(x: 0, y: 120, width: 400, height: 500),
                    scrollable: true),
        ])
        // 推測した容器は縁が数 pt ずれる(clippingContainer は木から採るので厳密一致しない)
        let inferred = FTRect(x: 0, y: 124, width: 400, height: 492)
        XCTAssertEqual(ScrollFrameCandidates.selector(matching: inferred, in: snap), "#list_rows")
    }

    /// 重なりが浅い相手を名乗ると**別の領域を指す scrollFrame** を勧めることになる。
    /// IoU 閾値未満は nil(呼び出し側は総称の文言に留まる)
    func testSelectorMatchingRefusesAWeakOverlap() {
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 0, width: 400, height: 800),
                    scrollable: true),
        ])
        let inferred = FTRect(x: 0, y: 600, width: 400, height: 200)
        XCTAssertNil(ScrollFrameCandidates.selector(matching: inferred, in: snap))
    }

    func testSelectorMatchingIgnoresContainersThatCannotBeNamed() {
        let snap = snapshot([
            element(1, frame: FTRect(x: 0, y: 100, width: 400, height: 500), scrollable: true),
        ])
        XCTAssertNil(ScrollFrameCandidates.selector(
            matching: FTRect(x: 0, y: 100, width: 400, height: 500), in: snap))
    }
}

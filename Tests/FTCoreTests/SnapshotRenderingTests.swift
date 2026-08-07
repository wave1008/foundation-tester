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
}

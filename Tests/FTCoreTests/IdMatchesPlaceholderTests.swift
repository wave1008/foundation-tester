// `#x` は identifier で引けなければ **placeholder** を引く(2026-08-15 ユーザー指示)。
//
// 入力欄は指す手段が経路で割れる: HTML の id は XCUITest が読む a11y に出ないが placeholder は
// 出る / Android は WebView の版で id と placeholder が入れ替わる。同じ欄が**エンジンや OS 版で
// 指せたり指せなかったり**するのをセレクタ側で吸収する。
//
// **identifier が当たったらそちらだけ**を使うのが不変条件 —— 混ぜると `#x[2]` の序数と
// `countIs` が経路によって変わる(静かに別の要素を指す)。

import XCTest
@testable import FTCore

final class IdMatchesPlaceholderTests: XCTestCase {

    private func element(_ ref: Int, type: String = "textField", id: String? = nil,
                         label: String? = nil, placeholder: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: placeholder, enabled: true,
                    frame: FTRect(x: 0, y: Double(ref) * 30, width: 200, height: 24), depth: 1)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 200, height: 400),
                         elements: elements, truncatedCount: 0)
    }

    private func match(_ selector: String, _ elements: [ElementInfo]) -> ElementInfo? {
        StepExecutor.match(FlowLocator(id: String(selector.dropFirst())), in: snapshot(elements))
    }

    /// **本題**: identifier に出ない欄を placeholder で引ける
    func testIdSelectorFindsAPlaceholderOnlyField() {
        let elements = [element(1, id: "other_field", placeholder: "名前"),
                        element(2, placeholder: "WebView 入力")]
        XCTAssertEqual(match("#WebView 入力", elements)?.ref, 2,
                       "placeholder で指せていない")
    }

    /// **identifier が優先**(両方に同じ名前があっても identifier 側を返す)
    func testIdentifierWinsOverPlaceholder() {
        let elements = [element(1, placeholder: "検索"),
                        element(2, id: "検索", placeholder: "別のもの")]
        XCTAssertEqual(match("#検索", elements)?.ref, 2,
                       "placeholder が identifier を押しのけた")
    }

    /// 逆方向: identifier で引ける従来の指し方は1文字も変わらない
    func testPlainIdentifierMatchingIsUnchanged() {
        let elements = [element(1, id: "field_single"), element(2, id: "field_multiline")]
        XCTAssertEqual(match("#field_single", elements)?.ref, 1)
        XCTAssertNil(match("#field_none", elements))
    }

    /// ワイルドカード(`#*入力*`)も placeholder に効く(id と同じ規則を通ること)
    func testWildcardIdAlsoMatchesPlaceholder() {
        let elements = [element(1, placeholder: "WebView 入力")]
        let locator = FlowLocator(id: "入力", idMatch: .contains)   // `#*入力*` の解析結果
        XCTAssertEqual(StepExecutor.match(locator, in: snapshot(elements))?.ref, 1)
    }

    /// **序数と件数はどちらか片方の集合の中だけで数える** —— identifier で1件でも当たれば
    /// placeholder 側は混ざらない(混ざると `[2]` が経路で別要素を指す)
    func testOrdinalCountsWithinOneClassOnly() {
        let elements = [element(1, id: "row", placeholder: "row"),
                        element(2, placeholder: "row"),
                        element(3, placeholder: "row")]
        let candidates = StepExecutor.candidates(FlowLocator(id: "row"), elements: elements) ?? []
        XCTAssertEqual(candidates.map(\.ref), [1], "placeholder 側が混ざっている")
    }

    /// 台帳(dry-run の `#id` 実在照合)も placeholder を「指せる名前」として記録すること。
    /// 記録しないと、実在する欄を書いたシナリオが dry-run で警告される
    func testInventoryRecordsPlaceholdersAsAddressableNames() {
        let snapshot = SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 200, height: 400),
            elements: [element(1, id: "field_single"), element(2, placeholder: "WebView 入力")],
            truncatedCount: 0)
        let ids = SelectorInventory.ids(in: snapshot)
        XCTAssertTrue(ids.contains("field_single"), "\(ids)")
        XCTAssertTrue(ids.contains("WebView 入力"), "placeholder が台帳に入っていない: \(ids)")
    }
}

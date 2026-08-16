// 実データの罠(2026-08-12・Yahoo!天気の広告リンク・iOS Safari): 複数のテキストノードを
// 改行で連結した a11y ラベルが実在する(`"TOKYOチャレンジネット\n介護職に興味ありませんか？"`)。
// SnapshotRenderer.foldLineBreaks が「1要素1行」の出力契約と「セレクタとして書ける形」を守る。

import XCTest
@testable import FTCore

final class LabelLineFoldingTests: XCTestCase {

    private func element(ref: Int = 1, type: String = "link", label: String? = nil,
                         value: String? = nil, placeholder: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: value,
                    placeholder: placeholder, enabled: true,
                    frame: FTRect(x: 1, y: 146, width: 536, height: 70), depth: 1)
    }

    // MARK: - foldLineBreaks そのもの

    func testConsecutiveLineBreaksFoldToOneSpace() {
        XCTAssertEqual(SnapshotRenderer.foldLineBreaks("A\n\nB"), "A B")
    }

    func testCRLFFoldsToOneSpace() {
        XCTAssertEqual(SnapshotRenderer.foldLineBreaks("A\r\nB"), "A B")
    }

    func testTabAndUnicodeLineSeparatorsFold() {
        XCTAssertEqual(SnapshotRenderer.foldLineBreaks("A\tB"), "A B")
        XCTAssertEqual(SnapshotRenderer.foldLineBreaks("A\u{2028}B"), "A B")
        XCTAssertEqual(SnapshotRenderer.foldLineBreaks("A\u{2029}B"), "A B")
    }

    /// 陰性対照: 通常空白・全角空白(見た目が違う)は畳まない(`TextNormalization.text` と同じ意図)
    func testOrdinaryAndFullWidthSpacesAreNotFolded() {
        XCTAssertEqual(SnapshotRenderer.foldLineBreaks("A B"), "A B")
        XCTAssertEqual(SnapshotRenderer.foldLineBreaks("A\u{3000}B"), "A\u{3000}B")
    }

    // MARK: - (A) 「1要素1行」の出力契約

    /// 出力に含まれる改行の数が要素数と一致すること(= ラベルの改行が出力へ漏れていない)
    func testMultilineLabelDoesNotBreakOneLinePerElement() {
        let snapshot = SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: [
                element(ref: 1, label: "TOKYOチャレンジネット\n介護職に興味ありませんか？"),
                element(ref: 2, type: "staticText", label: "次の行"),
            ], truncatedCount: 0)
        let text = SnapshotRenderer.render(snapshot)
        // screen行 + 要素2行 = 3行。ラベルの改行が畳まれていなければ4行になる
        XCTAssertEqual(text.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(text.contains(
            "[1] link \"TOKYOチャレンジネット 介護職に興味ありませんか？\""))
    }

    func testValueAndPlaceholderAreFoldedToo() {
        let el = element(type: "textField", value: "1行目\n2行目", placeholder: "入力\nしてください")
        let line = SnapshotRenderer.renderElement(el)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("value=\"1行目 2行目\""))
        XCTAssertTrue(line.contains("ph=\"入力 してください\""))
    }

    /// 畳んでから切り詰める(逆順だと切り詰め後に改行が残る)
    func testFoldingHappensBeforeTruncation() {
        let long = String(repeating: "あ", count: 20) + "\n" + String(repeating: "い", count: 20)
        let line = SnapshotRenderer.renderElement(element(label: long))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("…"))
    }

    // MARK: - (B) 畳んだセレクタが元の要素に一致する(本丸)

    /// 畳んだラベルを label フィルタに使うと、その要素だけを一意に解決できる。
    /// `.selector` 正規化(既定)は実行時にも空白を種類問わず畳んで比較するので、
    /// 生ラベルの改行はここでも同じ形へ畳まれ、一致し続ける
    func testFoldedLabelResolvesTheOriginalElementViaResolvedCandidates() {
        let rawLabel = "TOKYOチャレンジネット\n介護職に興味ありませんか？"
        let target = element(ref: 1, label: rawLabel)
        let other = element(ref: 2, type: "staticText", label: "別の要素")

        let folded = SnapshotRenderer.foldLineBreaks(rawLabel)
        XCTAssertFalse(folded.contains("\n"), "畳み込みが恒等関数に退化していないか")

        let locator = FlowLocator(label: folded)
        let resolved = StepExecutor.resolvedCandidates(locator, elements: [target, other])
        XCTAssertEqual(resolved?.count, 1)
        XCTAssertEqual(resolved?.first?.ref, target.ref)
    }

    /// FlowMatchMode 単体でも同じことを確かめる(セレクタのフィルタ既定は `.selector` 正規化)
    func testFoldedLabelMatchesRawLabelUnderSelectorNormalization() {
        let rawLabel = "A\n\nB"
        let folded = SnapshotRenderer.foldLineBreaks(rawLabel)
        XCTAssertTrue(FlowMatchMode.exact.matches(rawLabel, folded))
    }
}

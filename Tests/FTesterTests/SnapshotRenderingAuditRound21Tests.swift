// ブラウザの画面で出た要素リスト描画の欠陥2件:
// 1) URL の先頭切りで末尾(固有部分)が読めない → 中略切り詰めへ
// 2) `link > staticText` のような同一ラベル・同一 frame の重複が interactiveOnly で残る

import XCTest
@testable import FTCore

final class SnapshotRenderingAuditRound21Tests: XCTestCase {

    private func el(_ ref: Int, type: String, label: String? = nil, value: String? = nil,
                    identifier: String? = nil, frame: FTRect = FTRect(x: 0, y: 0, width: 100, height: 20),
                    depth: Int = 1, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: identifier, label: label, value: value,
                    placeholder: nil, enabled: true, frame: frame, depth: depth, scrollable: scrollable)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    // MARK: - 修正1: URL の中略切り詰め

    /// `https://` 付き URL は中略になり、末尾のパス(いちばん固有な部分)が読める
    func testFullURLTruncatesInTheMiddleKeepingTheTail() {
        let longURL = "https://example.com/search?q=" + String(repeating: "a", count: 40)
        let line = SnapshotRenderer.renderElement(el(1, type: "staticText", label: longURL))
        XCTAssertTrue(line.contains("…"), line)
        XCTAssertTrue(line.contains(String(longURL.suffix(10))), "末尾が読めること: \(line)")
        // 先頭切りなら "…" の直後に閉じ引用符が来る。中略なら間に末尾テキストが挟まる
        XCTAssertFalse(line.contains("…\""), "先頭切りに退行していないこと: \(line)")
    }

    /// スキーム省略形(`tenki.jp/lite/...`)も中略になる —— 実測(Android Chrome アドレスバー)の形
    func testSchemelessURLTruncatesInTheMiddleKeepingTheTail() {
        let url = "tenki.jp/lite/forecast/3/16/44100/index.html"
        let line = SnapshotRenderer.renderElement(el(1, type: "textField", value: url,
                                                      identifier: "url_bar"))
        XCTAssertTrue(line.contains("…"), line)
        XCTAssertTrue(line.contains(String(url.suffix(10))), "末尾のパスが読めること: \(line)")
    }

    /// URL でない長いラベル(日本語見出し等)は従来どおり先頭切り(退行の陰性対照)
    func testNonURLLongLabelStillTruncatesAtTheStart() {
        let heading = "令和8年熊本地震　情報まとめ　" + String(repeating: "続報", count: 20)
        let line = SnapshotRenderer.renderElement(el(1, type: "staticText", label: heading))
        XCTAssertTrue(line.contains("\"" + String(heading.prefix(SnapshotRenderer.labelDisplayLimit))),
                     line)
        // 中略形ではないので先頭以外に "…" は出ない = 文字列全体でちょうど1箇所(末尾)だけ
        XCTAssertEqual(line.filter { $0 == "…" }.count, 1, line)
        XCTAssertTrue(line.contains("…\""), "先頭切りのまま末尾に \"…\" が来ること: \(line)")
    }

    /// 中略した結果の文字数は上限を超えない(label/value 両方、様々な長さで)
    func testTruncateMiddleNeverExceedsTheLimit() {
        for extra in [1, 5, 20, 100] {
            let url = "https://example.com/" + String(repeating: "x", count: extra)
            let truncated = SnapshotRenderer.truncateMiddle(url, SnapshotRenderer.labelDisplayLimit)
            XCTAssertLessThanOrEqual(truncated.count, SnapshotRenderer.labelDisplayLimit,
                                     "extra=\(extra): \(truncated)")
        }
    }

    /// isURLLike: スキーム付き/省略形どちらも拾い、URL でない文字列・数字だけのドットは拾わない
    func testIsURLLikeRecognizesBothFormsAndRejectsPlainText() {
        XCTAssertTrue(SnapshotRenderer.isURLLike("https://example.com/a"))
        XCTAssertTrue(SnapshotRenderer.isURLLike("tenki.jp/lite/forecast"))
        XCTAssertTrue(SnapshotRenderer.isURLLike("example.com"))
        XCTAssertFalse(SnapshotRenderer.isURLLike("新宿, JR JA"))
        XCTAssertFalse(SnapshotRenderer.isURLLike("v1.2.3"))
        XCTAssertFalse(SnapshotRenderer.isURLLike(""))
    }

    /// truncatedSelectorHint は末尾切り(従来形)だけでなく、中略形(URL)を貼られたときも反応する
    func testTruncatedSelectorHintDetectsAMiddleTruncatedPaste() {
        let url = "tenki.jp/lite/forecast/3/16/44100/index.html"
        let snap = snapshot([el(1, type: "textField", value: url, identifier: "url_bar")])
        let pasted = SnapshotRenderer.displayTruncate(url, SnapshotRenderer.valueDisplayLimit)
        XCTAssertTrue(pasted.contains("…"), "前提: 実際に中略される長さであること")
        let hint = SnapshotRenderer.truncatedSelectorHint(pasted, in: snap)
        XCTAssertNotNil(hint, "中略形の貼り付けを検出できること")
        XCTAssertTrue(hint?.contains("…") == true, hint ?? "<nil>")
    }

    /// 末尾切り(従来形)の検出は変わらず効く(退行の陰性対照)
    func testTruncatedSelectorHintStillDetectsAPrefixTruncatedPaste() {
        let heading = "令和8年熊本地震　情報まとめ　" + String(repeating: "続報", count: 20)
        let snap = snapshot([el(1, type: "staticText", label: heading)])
        let pasted = String(heading.prefix(SnapshotRenderer.labelDisplayLimit)) + "…"
        XCTAssertNotNil(SnapshotRenderer.truncatedSelectorHint(pasted, in: snap))
    }

    /// quotedPartialMatchExample は "…" を含む断片を渡されても、"…" を含む例を返さない
    /// (絶対に一致しない例を出さないための保険)
    func testQuotedPartialMatchExampleNeverEmitsAnEllipsis() {
        let example = SnapshotRenderer.quotedPartialMatchExample("tenki.jp/lite…orecast")
        XCTAssertFalse(example.contains("…"), example)
    }

    /// truncatedLabelNote: URL らしいラベルが切り詰められているときは、末尾側からも
    /// 部分一致が作れる旨を案内する("…" を含む例にはならない)
    func testTruncatedLabelNoteMentionsBothEndsForURLLikeLabels() {
        let url = "https://example.com/search?q=" + String(repeating: "a", count: 40)
        let note = SnapshotRenderer.truncatedLabelNote(snapshot([el(1, type: "link", label: url)]))
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("either end") == true, note ?? "<nil>")
        // 例(`(e.g. "*...*")`)の中身に "…" が混じっていないこと(絶対に一致しない例を防ぐ)
        if let egRange = note?.range(of: "(e.g. "),
           let closeParen = note?[egRange.upperBound...].firstIndex(of: ")") {
            XCTAssertFalse(note![egRange.upperBound..<closeParen].contains("…"), note!)
        } else {
            XCTFail("example segment not found: \(note ?? "<nil>")")
        }
    }

    // MARK: - 修正2: interactiveOnly の重複コンテンツ間引き

    /// link > staticText の同一ラベル・同一 frame は interactiveOnly で1行に減る
    func testInteractiveOnlyCollapsesLinkStaticTextDuplicate() {
        let frame = FTRect(x: 47, y: 237, width: 192, height: 16)
        let snap = snapshot([
            el(1, type: "link", label: "熊本地震情報", frame: frame, depth: 1),
            el(2, type: "staticText", label: "熊本地震情報", value: "熊本地震情報", frame: frame, depth: 2),
        ])
        let text = SnapshotRenderer.render(snap, interactiveOnly: true)
        XCTAssertTrue(text.contains("[1]"), text)
        XCTAssertFalse(text.contains("[2]"), text)
        XCTAssertTrue(text.contains("1 layout-only or duplicate-content line(s) hidden"), text)
    }

    /// 警告(flagging)の付いた staticText は隠れない(最優先規則)
    func testFlaggedDuplicateStaticTextIsNeverHidden() {
        let frame = FTRect(x: 47, y: 237, width: 192, height: 16)
        let snap = snapshot([
            el(1, type: "link", label: "熊本地震情報", frame: frame, depth: 1),
            el(2, type: "staticText", label: "熊本地震情報", value: "熊本地震情報", frame: frame, depth: 2),
        ])
        let text = SnapshotRenderer.render(snap, flagging: [2: "⚠️scroll-leftover"],
                                           interactiveOnly: true)
        XCTAssertTrue(text.contains("[2]"), text)
        XCTAssertTrue(text.contains("⚠️scroll-leftover"), text)
    }

    /// 祖先が操作可能でない(ただの容器)なら、同じラベル・同じ frame でも隠さない
    func testStaticTextUnderANonOperableContainerIsNotHidden() {
        let frame = FTRect(x: 47, y: 237, width: 192, height: 16)
        let snap = snapshot([
            el(1, type: "other", label: "熊本地震情報", frame: frame, depth: 1),
            el(2, type: "staticText", label: "熊本地震情報", frame: frame, depth: 2),
        ])
        let text = SnapshotRenderer.render(snap, interactiveOnly: true)
        XCTAssertTrue(text.contains("[2]"), text)
    }

    /// 祖先のラベルに自分の文字列が含まれないなら隠さない
    func testStaticTextNotContainedInAncestorLabelIsNotHidden() {
        let frame = FTRect(x: 47, y: 237, width: 192, height: 16)
        let snap = snapshot([
            el(1, type: "link", label: "メニュー", frame: frame, depth: 1),
            el(2, type: "staticText", label: "熊本地震情報", frame: frame, depth: 2),
        ])
        let text = SnapshotRenderer.render(snap, interactiveOnly: true)
        XCTAssertTrue(text.contains("[2]"), text)
    }

    /// frame が祖先からはみ出す staticText は隠さない
    func testStaticTextOverflowingTheAncestorFrameIsNotHidden() {
        let ancestorFrame = FTRect(x: 0, y: 0, width: 100, height: 20)
        let overflowFrame = FTRect(x: 0, y: 0, width: 150, height: 20)
        let snap = snapshot([
            el(1, type: "link", label: "情報", frame: ancestorFrame, depth: 1),
            el(2, type: "staticText", label: "情報", frame: overflowFrame, depth: 2),
        ])
        let text = SnapshotRenderer.render(snap, interactiveOnly: true)
        XCTAssertTrue(text.contains("[2]"), text)
    }

    /// interactiveOnly: false の出力は変更前と1バイトも変わらない(退行の陰性対照)
    func testInteractiveOnlyFalseOutputIsUnchanged() {
        let frame = FTRect(x: 47, y: 237, width: 192, height: 16)
        let snap = snapshot([
            el(1, type: "link", label: "熊本地震情報", frame: frame, depth: 1),
            el(2, type: "staticText", label: "熊本地震情報", value: "熊本地震情報", frame: frame, depth: 2),
        ])
        let text = SnapshotRenderer.render(snap)
        XCTAssertTrue(text.contains("[1] link \"熊本地震情報\" (47,237 192x16)"), text)
        XCTAssertTrue(text.contains(
            "[2] staticText \"熊本地震情報\" value=\"熊本地震情報\" (47,237 192x16)"), text)
        XCTAssertFalse(text.contains("hidden"), text)
    }

    /// 宣言した隠した件数と、実際に消えた行数が一致する
    /// (layout-only 1件 + 重複コンテンツ2組 = 3件隠れる想定)
    func testDeclaredHiddenCountMatchesActuallyHiddenLines() {
        let frameA = FTRect(x: 0, y: 100, width: 100, height: 20)
        let frameB = FTRect(x: 0, y: 200, width: 100, height: 20)
        let elements = [
            el(1, type: "button", label: "OK", depth: 1),
            el(2, type: "other", depth: 1), // layout-only(ラベルも値も無い)
            el(3, type: "link", label: "情報A", frame: frameA, depth: 1),
            el(4, type: "staticText", label: "情報A", frame: frameA, depth: 2),
            el(5, type: "link", label: "情報B", frame: frameB, depth: 1),
            el(6, type: "staticText", label: "情報B", frame: frameB, depth: 2),
        ]
        let snap = snapshot(elements)
        let full = SnapshotRenderer.render(snap)
        let filtered = SnapshotRenderer.render(snap, interactiveOnly: true)

        func elementLineCount(_ text: String) -> Int {
            text.split(separator: "\n").filter { $0.hasPrefix("[") }.count
        }
        let fullCount = elementLineCount(full)
        let filteredCount = elementLineCount(filtered)
        XCTAssertEqual(fullCount, 6, full)
        XCTAssertEqual(filteredCount, 3, filtered)

        guard let declaredRange = filtered.range(of: "interactiveOnly: "),
              let unitRange = filtered.range(of: " layout-only or duplicate-content") else {
            XCTFail("declaration line missing: \(filtered)")
            return
        }
        let declared = Int(filtered[declaredRange.upperBound..<unitRange.lowerBound])
        XCTAssertEqual(declared, fullCount - filteredCount, filtered)
        XCTAssertEqual(declared, 3, filtered)
    }
}

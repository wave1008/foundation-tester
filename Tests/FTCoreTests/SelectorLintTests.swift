import XCTest
@testable import FTCore

final class SelectorLintTests: XCTestCase {

    // MARK: - selectorsInSwiftSource

    func testExtractsSelectorWithLineNumber() {
        let source = """
        class Sample {
            func run() {
                tap("#nav_lifecycle")
            }
        }
        """
        let hits = SelectorLint.selectorsInSwiftSource(source)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, "nav_lifecycle")
        XCTAssertEqual(hits.first?.line, 3)
    }

    func testIgnoresFullLineComment() {
        let source = """
        // tap("#foo")
        tap("#real")
        """
        let hits = SelectorLint.selectorsInSwiftSource(source)
        XCTAssertEqual(hits.map(\.id), ["real"])
        XCTAssertEqual(hits.first?.line, 2)
    }

    func testIgnoresTrailingComment() {
        // 生文字列 #"..."# は内容中の "# で早期終端するため使えない(tap("#real") 等)。通常の
        // エスケープ文字列で書く
        let source = "tap(\"#real\") // #fake"
        let hits = SelectorLint.selectorsInSwiftSource(source)
        XCTAssertEqual(hits.map(\.id), ["real"])
    }

    func testExtractsMultipleSelectorsOnOneLine() {
        let source = "textIs(\"#txt_a\", \"#txt_b\")"
        let hits = SelectorLint.selectorsInSwiftSource(source)
        XCTAssertEqual(Set(hits.map(\.id)), Set(["txt_a", "txt_b"]))
        XCTAssertTrue(hits.allSatisfy { $0.line == 1 })
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(SelectorLint.selectorsInSwiftSource("").isEmpty)
        XCTAssertTrue(SelectorLint.selectorsInSwiftSource("let x = 1\ntap(\"no hash here\")").isEmpty)
    }

    // MARK: - idsInContract

    func testExtractsPlainToken() {
        let markdown = "本文中に #txt_screen_title が出てくる"
        XCTAssertEqual(SelectorLint.idsInContract(markdown), Set(["txt_screen_title"]))
    }

    func testExtractsBacktickedToken() {
        let markdown = "| `#btn_back` | Button | 戻る |"
        XCTAssertEqual(SelectorLint.idsInContract(markdown), Set(["btn_back"]))
    }

    func testHeadingIsNotExtracted() {
        let markdown = "# 見出しテキスト\n本文には #real_id がある"
        XCTAssertEqual(SelectorLint.idsInContract(markdown), Set(["real_id"]))
    }

    // MARK: - drift

    func testDriftReportsUnknownAndUnused() {
        let result = SelectorLint.drift(
            usedIDs: Set(["a", "b"]), contractIDs: Set(["a", "c"]))
        XCTAssertEqual(result.unknown, Set(["b"]))
        XCTAssertEqual(result.unusedContractIDs, Set(["c"]))
    }

    func testDriftNoMismatch() {
        let result = SelectorLint.drift(
            usedIDs: Set(["a", "b"]), contractIDs: Set(["a", "b"]))
        XCTAssertTrue(result.unknown.isEmpty)
        XCTAssertTrue(result.unusedContractIDs.isEmpty)
    }
}

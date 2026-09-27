import XCTest
@testable import FTCore

final class OCRHomoglyphsTests: XCTestCase {

    /// **witness**: Vision の英語モデルが入力欄の `ap` を `аpар`(U+0430・U+0440)と読んだ
    func testFoldsTheMeasuredCyrillicReading() {
        let measured = "\u{0430}p\u{0430}\u{0440}"
        XCTAssertFalse(RegionText.readable(expected: "apap", lines: [measured]), "前提: 畳まないと一致しない")
        XCTAssertEqual(OCRHomoglyphs.foldToLatin(measured), "apap")
        XCTAssertTrue(RegionText.readable(expected: "apap", lines: [OCRHomoglyphs.foldToLatin(measured)]))
    }

    /// 字形の違う文字は畳まない(別の文字を一致にしない)
    func testLeavesDistinctLettersAlone() {
        XCTAssertEqual(OCRHomoglyphs.foldToLatin("日本語 Жб"), "日本語 Жб")
        XCTAssertEqual(OCRHomoglyphs.foldToLatin("banana"), "banana")
    }
}

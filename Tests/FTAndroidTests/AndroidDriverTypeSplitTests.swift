// AndroidDriver.splitTrailingNewline(pressEnter 対応で追加した末尾改行の分離ロジック)の検証。
// ACTION_SET_TEXT は改行を文字として入れるだけで IME アクションにならないため、type() は
// 末尾の改行1つを分離して本文の SET_TEXT 後に Enter キーイベントを送る(このファイルは分離規則のみ検証。
// キーイベント送出はデバイス境界なので対象外)。

import XCTest
@testable import FTAndroid

final class AndroidDriverTypeSplitTests: XCTestCase {

    func testNoTrailingNewlinePassesThrough() {
        let (main, hasTrailingNewline) = AndroidDriver.splitTrailingNewline("hello")
        XCTAssertEqual(main, "hello")
        XCTAssertFalse(hasTrailingNewline)
    }

    func testTrailingNewlineIsSplitOff() {
        let (main, hasTrailingNewline) = AndroidDriver.splitTrailingNewline("hello\n")
        XCTAssertEqual(main, "hello")
        XCTAssertTrue(hasTrailingNewline)
    }

    /// text 全体が "\n" 単独のときは分離しない(本文なしの type("\n") を空文字+改行に
    /// 潰さない。呼び出し側の従来経路をそのまま通す)
    func testSoleNewlineIsNotSplit() {
        let (main, hasTrailingNewline) = AndroidDriver.splitTrailingNewline("\n")
        XCTAssertEqual(main, "\n")
        XCTAssertFalse(hasTrailingNewline)
    }

    /// 文中の改行はそのまま本文に残る(分離するのは末尾の1つだけ)
    func testInteriorNewlineStaysInMainBody() {
        let (main, hasTrailingNewline) = AndroidDriver.splitTrailingNewline("line1\nline2\n")
        XCTAssertEqual(main, "line1\nline2")
        XCTAssertTrue(hasTrailingNewline)
    }

    func testEmptyStringPassesThrough() {
        let (main, hasTrailingNewline) = AndroidDriver.splitTrailingNewline("")
        XCTAssertEqual(main, "")
        XCTAssertFalse(hasTrailingNewline)
    }
}

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

    /// **注入は必ず ref 対応表を通す**(`AndroidWebViewDOM.bridgeRefMap`)。素の ref を渡すと
    /// DOM 由来の入力欄がブリッジに存在せず 404 になる。対応表を作る側は単体テストで固めてあるが、
    /// **使う側を外す変異はそこでは落ちない**のでソースで見る(`SwipeForScrollForwardingTests` の作法)
    func testInjectionGoesThroughTheBridgeRefMap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTAndroid/AndroidDriver.swift"), encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("$0.type(ref: target"), "type が対応表を通っていない")
        XCTAssertTrue(code.contains("$0.clearInput(ref: target"), "clearInput が対応表を通っていない")
        XCTAssertTrue(code.contains("domBridgeRefs[ref] ?? ref"), "対応表の引き当てが無い")
        // **タップは写さない**(座標はホストが持っている。写すと古い a11y の中心へ撃つ)
        XCTAssertTrue(code.contains("guard let center = refCenters[ref]"),
                      "tap がホスト側の座標表から離れている")
    }
}

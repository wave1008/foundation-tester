// 読み返しが目標にする値の採り直し(`StepExecutor.readbackTarget`。2026-08-13)。
//
// witness: E2E-CMP の `#field_single` は空のとき value="単一行"(ヒント)を返し `placeholder` を
// 出さないので、`expected = 撃つ前の値 + 本文` が最初から偽になる。plan は必ず `.unverifiable` へ
// 落ち、**追送も打ち直しも走らないまま受理される**(読み返しの砦が丸ごと外れる)。
// 偽であることは自前の E2E が毎回証明していた —— 同じシナリオの次の行
// `textIs "#txt_echo_length" == "len=8"` が通るのに、注記は "単一行hello123"(11文字)を予告していた。

import XCTest
@testable import FTCore

final class TypeReadbackTargetTests: XCTestCase {

    /// **witness**: ヒントが value に載る欄。撃った文字だけが残っていたら目標を採り直す
    func testFallsBackToTypedTextWhenThePriorValueWasHintText() {
        XCTAssertEqual(
            StepExecutor.readbackTarget(expected: "単一行hello123", typedOnly: "hello123",
                                        actual: "hello123"),
            "hello123")
    }

    /// 採り直した目標で**追送が復活する**(ここが本題 —— 受理されるかどうかではなく、修復が走るか)
    func testFallbackRestoresTheResendRepair() {
        let target = StepExecutor.readbackTarget(expected: "単一行hello123", typedOnly: "hello123",
                                                 actual: "hello")
        XCTAssertEqual(target, "hello123")
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: "hello"), .resend("123"))
        // 採り直さないと諦めていたこと(退行したら落ちる)
        XCTAssertEqual(TypeReadback.plan(expected: "単一行hello123", actual: "hello"), .unverifiable)
    }

    /// 本当に値が入っていた欄では `expected` のまま(連結は正しい)
    func testKeepsExpectedWhenThePriorValueWasReal() {
        XCTAssertEqual(
            StepExecutor.readbackTarget(expected: "oldnew", typedOnly: "new", actual: "oldnew"),
            "oldnew")
    }

    /// **順序の砦**: 撃つ前の値と本文が同じ欄で、追記が届かなかった失敗を `.done` に見せない。
    /// `expected` の plan が修復可能(`.resend`)なので採り直さない
    func testDoesNotHideAFailedAppendWhenPriorEqualsTypedText() {
        let target = StepExecutor.readbackTarget(expected: "abcabc", typedOnly: "abc", actual: "abc")
        XCTAssertEqual(target, "abcabc")
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: "abc"), .resend("abc"))
    }

    /// 撃つ前が空(expected == typedOnly)なら採り直す余地が無い
    func testNoAlternativeWhenTheFieldWasEmpty() {
        XCTAssertEqual(
            StepExecutor.readbackTarget(expected: "abc", typedOnly: "abc", actual: "ab"), "abc")
    }

    /// どちらの目標でも説明できない値(自動整形など)は `expected` のまま = 今までどおり諦める
    func testKeepsExpectedWhenNeitherTargetExplainsTheValue() {
        XCTAssertEqual(
            StepExecutor.readbackTarget(expected: "単一行12345", typedOnly: "12345",
                                        actual: "1-2345"),
            "単一行12345")
    }
}

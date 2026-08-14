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

    // ---- 不可視文字の正規化(2026-08-15) ----
    // MCP 側(replaceVerificationNote/appendVerificationNote)は既に
    // FlowMatchMode.normalizeInvisibleCharacters を両辺にかけているが、DSL のこの読み返し経路だけ
    // 素の比較のままだと、見た目が同じ文字列でも不一致になり 8 秒待った末にシナリオが失敗する
    // (MCP は緑・シナリオは赤という食い違い)。readbackTarget は expected/typedOnly/actual の
    // 三者を自前で正規化するので、呼び出し側の正規化有無に関わらずここで検証できる。

    /// ゼロ幅文字が**読み返し値だけ**に混じっていても正規化後は一致として扱う
    func testTreatsInvisibleCharactersInActualAsAMatch() {
        let target = StepExecutor.readbackTarget(expected: "priorHello", typedOnly: "Hello",
                                                  actual: "priorHel\u{200B}lo")
        XCTAssertEqual(target, "priorHello")
        XCTAssertEqual(
            TypeReadback.plan(expected: target,
                              actual: FlowMatchMode.normalizeInvisibleCharacters("priorHel\u{200B}lo")),
            .done)
    }

    /// ゼロ幅文字が**期待値だけ**に混じっていても正規化後は一致として扱う
    func testTreatsInvisibleCharactersInExpectedAsAMatch() {
        let target = StepExecutor.readbackTarget(expected: "priorHel\u{200B}lo", typedOnly: "Hello",
                                                  actual: "priorHello")
        XCTAssertEqual(target, "priorHello")
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: "priorHello"), .done)
    }

    /// ゼロ幅の雑音を落としても、見える文字の欠落(=本当の resend 対象)は隠さない
    func testStillResendsVisibleCharactersAfterNormalizingNoise() {
        let target = StepExecutor.readbackTarget(expected: "priorHello", typedOnly: "Hello",
                                                  actual: "prio\u{200B}r")
        XCTAssertEqual(target, "priorHello")
        XCTAssertEqual(
            TypeReadback.plan(expected: target,
                              actual: FlowMatchMode.normalizeInvisibleCharacters("prio\u{200B}r")),
            .resend("Hello"))
    }

    /// **逆方向の変異ガード**: 正規化しても消えない見える文字の差分(o と p)は依然として一致にならない
    /// (「常に正規化して常に一致させる」実装への退化をここで検出する)
    func testGenuinelyDifferentValuesStillDoNotMatchAfterNormalizing() {
        let target = StepExecutor.readbackTarget(expected: "hello", typedOnly: "hello",
                                                  actual: "hell\u{200B}p")
        XCTAssertEqual(target, "hello")
        XCTAssertEqual(
            TypeReadback.plan(expected: target,
                              actual: FlowMatchMode.normalizeInvisibleCharacters("hell\u{200B}p")),
            .unverifiable)
    }
}

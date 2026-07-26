import XCTest
@testable import FTDSL
import FTCore

/// 型付きセレクタ(Sel)。**文字列版と同じ FlowLocator に畳まれること**が唯一の合格条件で、
/// ここが崩れると型付き経路だけ解決規則が違うという最悪の分岐になる(記法の意味は
/// FTSelectorTests が持ち、この場では「一致」だけを見る)。
final class SelTests: XCTestCase {

    /// 型付き版と文字列版が同じ主ロケータ・同じフォールバック連鎖になること
    private func assertSame(_ sel: Sel, _ expression: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let typed = sel.ftSelector
        let parsed = FTSelector.parse(expression)
        XCTAssertEqual(typed.primary, parsed.primary, expression, file: file, line: line)
        XCTAssertEqual(typed.fallbacks, parsed.fallbacks, expression, file: file, line: line)
    }

    func testFilters() {
        assertSame(.id("login_btn"), "#login_btn")
        assertSame(.text("ログイン"), "ログイン")
        assertSame(.text("ログイン", .contains), "*ログイン*")
        assertSame(.text("ログイン", .startsWith), "ログイン*")
        assertSame(.text("ログイン", .endsWith), "*ログイン")
        assertSame(.text("^ログイン.*$", .matches), "textMatches=^ログイン.*$")
        assertSame(.type(.button), ".button")
        assertSame(.type(.button).nth(2), ".button[2]")
        assertSame(.type(.switch).id("PHOTOS_UPLOAD"), ".switch#PHOTOS_UPLOAD")
        assertSame(.type(.switch).text("Resource Upload"), ".switch&&Resource Upload")
        assertSame(.type(.button).value("太郎").enabled(true), ".button&&value=太郎&&enabled=true")
        assertSame(.placeholder("メールアドレス"), "placeholder=メールアドレス")
        assertSame(.checked(), "checked=true")
        assertSame(.type(.input).checked(false), ".input&&checked=false")
    }

    /// nth は 1 オリジン(内部 index は 0 オリジン)。1 番目は「指定なし」と同じ形に畳む
    func testNthIsOneOrigin() {
        XCTAssertEqual(Sel.type(.button).nth(1).ftSelector.primary, FlowLocator(type: "button"))
        XCTAssertEqual(Sel.type(.button).nth(3).ftSelector.primary,
                       FlowLocator(type: "button", index: 2))
    }

    func testFallbackChain() {
        assertSame(.id("login_btn").or(.text("ログイン")), "#login_btn||ログイン")
        assertSame(.id("a").or(.id("b")).or(.text("c")), "#a||#b||c")
    }

    func testScope() {
        assertSame(.id("list").find(.type(.clickable).nth(2)), "#list >> .clickable[2]")
        assertSame(.id("outer").find(.id("inner")).find(.type(.button)),
                   "#outer >> #inner >> .button")
        // スコープは相対セレクタの基準・対象の双方に効く(文字列版と同じ構造になること)
        assertSame(.id("row").find(.text("数量").right(.button)), "#row >> <数量>:rightButton")
    }

    func testRelative() {
        assertSame(.text("通知").right(.switch), "通知:rightSwitch")
        assertSame(.text("通知").right(), "通知:right")
        assertSame(.text("通知").right(nth: 2), "通知:right(2)")
        assertSame(.text("通知").right(.button, nth: 2), "通知:rightButton(2)")
        assertSame(.text("通知").right().below(.button), "通知:right:belowButton")
        assertSame(.text("見出し").below(matching: .id("list").find(.type(.button))),
                   "見出し:below(#list >> .button)")
        assertSame(.text("変更").type(.button).right(matching: .text("数量")),
                   "<変更&&.button>:right(数量)")
    }

    /// フィルタ系メソッドは相対ステップの**後**なら対象(=ステップの filter)に効く
    func testFilterAfterRelativeAppliesToTarget() {
        assertSame(.text("通知").right().type(.switch), "通知:rightSwitch")
        assertSame(.text("通知").right().nth(2), "通知:right(2)")
        assertSame(.text("通知").right(.button).nth(2), "通知:rightButton(2)")
    }

    /// 表示テキストは再パース可能な正規形(レポート表示とヒールキャッシュのキーになる)
    func testTextIsReparseableCanonicalForm() {
        let cases: [Sel] = [
            .id("login_btn"),
            .type(.button).nth(2),
            .id("list").find(.type(.clickable).nth(2)),
            .text("通知").right(.switch),
            .id("a").or(.text("b")),
        ]
        for sel in cases {
            let text = sel.ftSelector.text
            XCTAssertNil(FTSelector.validationError(text), text)
            XCTAssertEqual(FTSelector.parse(text).primary, sel.ftSelector.primary, text)
            XCTAssertEqual(FTSelector.parse(text).fallbacks, sel.ftSelector.fallbacks, text)
        }
    }

    /// 型付き経路は構文検証を通さない印が立つ。記法の予約文字を含むラベルでも
    /// 「再パースしたら別物」にならないための逃げ道(FTRuntime.perform の validateSelector)
    func testStructuredSkipsValidation() {
        let sel = Sel.text("A >> B").ftSelector
        XCTAssertTrue(sel.structured)
        XCTAssertEqual(sel.primary, FlowLocator(label: "A >> B"))
        XCTAssertFalse(FTSelector.parse("A >> B").structured)
    }

    func testCustomTypeIsNormalized() {
        XCTAssertEqual(SelType.custom("Cell").name, "cell")
        XCTAssertEqual(SelType.custom("cell").name, "cell")
    }
}

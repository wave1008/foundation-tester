import XCTest
@testable import FTDSL
import FTCore

/// セレクタ式のパース/直列化。スコープ(`>>`)・近接(`:near(...)`)の追加後も
/// 既存記法が壊れていないこと、および往復(parse → serialize → parse)が保たれることを見る。
final class FTSelectorTests: XCTestCase {

    func testExistingNotationsUnchanged() {
        XCTAssertEqual(FTSelector.parse("#login_btn").primary, FlowLocator(id: "login_btn"))
        XCTAssertEqual(FTSelector.parse("ログイン").primary, FlowLocator(label: "ログイン"))
        XCTAssertEqual(FTSelector.parse(".Button[2]").primary, FlowLocator(type: "Button", index: 1))
        XCTAssertEqual(FTSelector.parse(".Switch#S1").primary, FlowLocator(id: "S1", type: "Switch"))
        XCTAssertEqual(FTSelector.parse(".Switch=名前").primary,
                       FlowLocator(label: "名前", type: "Switch"))
        XCTAssertEqual(FTSelector.parse("=#raw").primary, FlowLocator(label: "#raw"))
        let chain = FTSelector.parse("#a||ラベル")
        XCTAssertEqual(chain.primary, FlowLocator(id: "a"))
        XCTAssertEqual(chain.fallbacks, [FlowLocator(label: "ラベル")])
    }

    func testScopeParsing() {
        let scoped = FTSelector.parse("#list >> .Cell[2]").primary
        XCTAssertEqual(scoped.type, "Cell")
        XCTAssertEqual(scoped.index, 1)
        XCTAssertEqual(scoped.scope, [FlowLocator(id: "list")])
    }

    func testNestedScopeKeepsOuterToInnerOrder() {
        let scoped = FTSelector.parse("#page >> #list >> ラベル").primary
        XCTAssertEqual(scoped.label, "ラベル")
        XCTAssertEqual(scoped.scope, [FlowLocator(id: "page"), FlowLocator(id: "list")])
    }

    func testNearParsing() {
        let near = FTSelector.parse(".Button:near(氏名)").primary
        XCTAssertEqual(near.type, "Button")
        XCTAssertEqual(near.near, [FlowLocator(label: "氏名")])
    }

    func testScopeBindsTighterThanFallbackChain() {
        let selector = FTSelector.parse("#list >> .Cell || #fallback")
        XCTAssertEqual(selector.primary.scope, [FlowLocator(id: "list")])
        XCTAssertEqual(selector.primary.type, "Cell")
        XCTAssertEqual(selector.fallbacks, [FlowLocator(id: "fallback")])
    }

    func testFallbackSeparatorInsideNearIsNotSplit() {
        let selector = FTSelector.parse(".Button:near(#a||氏名)")
        XCTAssertTrue(selector.fallbacks.isEmpty)
        XCTAssertEqual(selector.primary.near?.first?.id, "a")
    }

    func testEscapeKeepsSyntaxCharactersAsLabel() {
        XCTAssertEqual(FTSelector.parse("=A >> B").primary, FlowLocator(label: "A >> B"))
        XCTAssertEqual(FTSelector.parse("=x:near(y)").primary, FlowLocator(label: "x:near(y)"))
    }

    func testMalformedNearFallsBackToLabel() {
        // 土台が空 / アンカーが空 の `:near` は構文として解釈しない(パースは失敗しない契約)
        XCTAssertEqual(FTSelector.parse(":near(氏名)").primary.label, ":near(氏名)")
        XCTAssertEqual(FTSelector.parse(".Button:near()").primary.type, "Button:near()")
    }

    func testSerializeRoundTrip() {
        for text in ["#login_btn", "ログイン", ".Button[2]", ".Switch#S1", ".Switch=名前",
                     "#list >> .Cell[2]", "#page >> #list >> ラベル", ".Button:near(氏名)",
                     "#list >> .Cell:near(合計)", "=#raw"] {
            let parsed = FTSelector.parse(text)
            let serialized = FTSelector.serialize(primary: parsed.primary,
                                                  fallbacks: parsed.fallbacks)
            XCTAssertEqual(FTSelector.parse(serialized).primary, parsed.primary,
                           "往復で壊れた: \(text) → \(serialized)")
        }
    }

    func testSerializeEscapesLabelsContainingSyntax() {
        let locator = FlowLocator(label: "A >> B")
        XCTAssertEqual(FTSelector.serialize(locator), "=A >> B")
        XCTAssertEqual(FTSelector.parse(FTSelector.serialize(locator)).primary, locator)
    }

    func testSummaryShowsScopeAndNear() {
        let locator = FTSelector.parse("#list >> .Cell:near(合計)").primary
        XCTAssertEqual(locator.summary, "id=list >> Cell:near(label=合計)")
    }
}

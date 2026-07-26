import XCTest
@testable import FTDSL
import FTCore

/// セレクタ式のパース/直列化/構文検証。スコープ(`>>`)・方向(`:right(...)` 等)の追加後も
/// 既存記法が壊れていないこと、および往復(parse → serialize → parse)が保たれることを見る。
final class FTSelectorTests: XCTestCase {

    func testExistingNotationsUnchanged() {
        XCTAssertEqual(FTSelector.parse("#login_btn").primary, FlowLocator(id: "login_btn"))
        XCTAssertEqual(FTSelector.parse("ログイン").primary, FlowLocator(label: "ログイン"))
        XCTAssertEqual(FTSelector.parse(".button[2]").primary, FlowLocator(type: "button", index: 1))
        XCTAssertEqual(FTSelector.parse(".switch#S1").primary, FlowLocator(id: "S1", type: "switch"))
        XCTAssertEqual(FTSelector.parse(".switch=名前").primary,
                       FlowLocator(label: "名前", type: "switch"))
        XCTAssertEqual(FTSelector.parse("=#raw").primary, FlowLocator(label: "#raw"))
        let chain = FTSelector.parse("#a||ラベル")
        XCTAssertEqual(chain.primary, FlowLocator(id: "a"))
        XCTAssertEqual(chain.fallbacks, [FlowLocator(label: "ラベル")])
    }

    func testScopeParsing() {
        let scoped = FTSelector.parse("#list >> .clickable[2]").primary
        XCTAssertEqual(scoped.type, "clickable")
        XCTAssertEqual(scoped.index, 1)
        XCTAssertEqual(scoped.scope, [FlowLocator(id: "list")])
    }

    func testNestedScopeKeepsOuterToInnerOrder() {
        let scoped = FTSelector.parse("#page >> #list >> ラベル").primary
        XCTAssertEqual(scoped.label, "ラベル")
        XCTAssertEqual(scoped.scope, [FlowLocator(id: "page"), FlowLocator(id: "list")])
    }

    func testDirectionParsing() {
        for (text, direction) in [(".button:right(氏名)", FlowDirection.right),
                                  (".button:left(氏名)", .left),
                                  (".button:above(氏名)", .above),
                                  (".button:below(氏名)", .below)] {
            let locator = FTSelector.parse(text).primary
            XCTAssertEqual(locator.type, "button", text)
            XCTAssertEqual(locator.direction, direction, text)
            XCTAssertEqual(locator.anchor, [FlowLocator(label: "氏名")], text)
        }
    }

    func testScopeBindsTighterThanFallbackChain() {
        let selector = FTSelector.parse("#list >> .clickable || #fallback")
        XCTAssertEqual(selector.primary.scope, [FlowLocator(id: "list")])
        XCTAssertEqual(selector.primary.type, "clickable")
        XCTAssertEqual(selector.fallbacks, [FlowLocator(id: "fallback")])
    }

    func testFallbackSeparatorInsideAnchorIsNotSplit() {
        let selector = FTSelector.parse(".button:right(#a||氏名)")
        XCTAssertTrue(selector.fallbacks.isEmpty)
        XCTAssertEqual(selector.primary.anchor?.first?.id, "a")
    }

    func testEscapeKeepsSyntaxCharactersAsLabel() {
        XCTAssertEqual(FTSelector.parse("=A >> B").primary, FlowLocator(label: "A >> B"))
        XCTAssertEqual(FTSelector.parse("=x:right(y)").primary, FlowLocator(label: "x:right(y)"))
    }

    func testMalformedDirectionFallsBackToLabel() {
        // 土台が空 / アンカーが空 は構文として解釈しない(パースは失敗しない契約。
        // 誤りとしては validationError が捕まえる = testValidationRejects... を参照)
        XCTAssertEqual(FTSelector.parse(":right(氏名)").primary.label, ":right(氏名)")
        XCTAssertEqual(FTSelector.parse(".button:right()").primary.type, "button:right()")
    }

    func testSerializeRoundTrip() {
        for text in ["#login_btn", "ログイン", ".button[2]", ".switch#S1", ".switch=名前",
                     "#list >> .clickable[2]", "#page >> #list >> ラベル", ".button:right(氏名)",
                     ".switch:left(通知)", ".button:above(合計)", ".button:below(合計)",
                     "#list >> .clickable:right(合計)", "=#raw"] {
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

    func testSummaryShowsScopeAndDirection() {
        let locator = FTSelector.parse("#list >> .clickable:right(合計)").primary
        XCTAssertEqual(locator.summary, "id=list >> clickable:right(label=合計)")
    }

    // MARK: - 構文検証(パースが黙って label に落とす誤りを実行前に落とす)

    func testValidationAcceptsValidSelectors() {
        for text in ["#login_btn", "ログイン", ".button[2]", ".switch#S1", ".switch=名前",
                     "#list >> .clickable[2]", ".button:right(氏名)", ".switch:below(#a||通知)",
                     "=x:rigth(y)", "=A >> B", "合計: 1,200円", "#a||ラベル"] {
            XCTAssertNil(FTSelector.validationError(text), "誤検出: \(text)")
        }
    }

    func testValidationRejectsUnknownMarker() {
        // Shirates 等の他ツール記法・綴り誤りが「そんなラベルは無い」で緑になるのを防ぐ
        for text in [".button:rigth(氏名)", ".button:near(氏名)", ".button:descendant(#a)",
                     "#list >> .clickable:sibling(合計)"] {
            XCTAssertNotNil(FTSelector.validationError(text), "見逃した: \(text)")
        }
    }

    func testValidationRejectsMalformedSyntax() {
        for text in [".button:right(", ".button:right(氏名))", ".button:right()", ":right(氏名)",
                     ".button:right(氏名)の右", ".button[abc]", ".button[0]"] {
            XCTAssertNotNil(FTSelector.validationError(text), "見逃した: \(text)")
        }
    }
}

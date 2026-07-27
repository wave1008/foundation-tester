import XCTest
@testable import FTDSL
import FTCore

/// セレクタ式のパース/直列化/構文検証。既存記法(`#id` / ラベル / `.型[n]` / `>>` / `||`)が
/// 壊れていないこと、`&&` 合成・部分一致記法・相対セレクタ(基準が先)が意図どおり読めること、
/// および往復(parse → serialize → parse)が保たれることを見る。
final class FTSelectorTests: XCTestCase {

    private func step(_ direction: FlowDirection, type: String? = nil,
                      filter: [FlowLocator]? = nil, ordinal: Int? = nil) -> FlowRelativeStep {
        FlowRelativeStep(direction: direction,
                         filter: filter ?? type.map { [FlowLocator(type: $0)] },
                         ordinal: ordinal)
    }

    func testExistingNotationsUnchanged() {
        XCTAssertEqual(FTSelector.parse("#login_btn").primary, FlowLocator(id: "login_btn"))
        XCTAssertEqual(FTSelector.parse("ログイン").primary, FlowLocator(label: "ログイン"))
        XCTAssertEqual(FTSelector.parse(".button[2]").primary, FlowLocator(type: "button", index: 1))
        XCTAssertEqual(FTSelector.parse(".switch#S1").primary, FlowLocator(id: "S1", type: "switch"))
        XCTAssertEqual(FTSelector.parse(".switch&&名前").primary,
                       FlowLocator(label: "名前", type: "switch"))
        XCTAssertEqual(FTSelector.parse("=#raw").primary, FlowLocator(label: "#raw"))
        let chain = FTSelector.parse("#a||ラベル")
        XCTAssertEqual(chain.primary, FlowLocator(id: "a"))
        XCTAssertEqual(chain.fallbacks, [FlowLocator(label: "ラベル")])
    }

    // MARK: - 部分一致(P1)

    func testPartialMatchShorthands() {
        XCTAssertEqual(FTSelector.parse("*許可*").primary,
                       FlowLocator(label: "許可", labelMatch: .contains))
        XCTAssertEqual(FTSelector.parse("許可*").primary,
                       FlowLocator(label: "許可", labelMatch: .startsWith))
        XCTAssertEqual(FTSelector.parse("*許可").primary,
                       FlowLocator(label: "許可", labelMatch: .endsWith))
        // 素の文字列は完全一致(labelMatch は nil = exact)
        XCTAssertNil(FTSelector.parse("許可").primary.labelMatch)
    }

    func testTextFilterFullForms() {
        XCTAssertEqual(FTSelector.parse("text=許可").primary, FlowLocator(label: "許可"))
        XCTAssertEqual(FTSelector.parse("textContains=許可").primary,
                       FlowLocator(label: "許可", labelMatch: .contains))
        XCTAssertEqual(FTSelector.parse("textMatches=^許.$").primary,
                       FlowLocator(label: "^許.$", labelMatch: .matches))
        XCTAssertEqual(FTSelector.parse(".button&&*保存*").primary,
                       FlowLocator(label: "保存", labelMatch: .contains, type: "button"))
        XCTAssertEqual(FTSelector.parse(".button#id_1").primary,
                       FlowLocator(id: "id_1", type: "button"))
    }

    // MARK: - `&&` 合成と属性フィルタ(P3)

    func testAndCompositionOfFilters() {
        XCTAssertEqual(FTSelector.parse("#save&&.button").primary,
                       FlowLocator(id: "save", type: "button"))
        XCTAssertEqual(FTSelector.parse(".textField&&value=太郎").primary,
                       FlowLocator(value: "太郎", type: "textField"))
        XCTAssertEqual(FTSelector.parse(".switch&&checked=true").primary,
                       FlowLocator(type: "switch", checked: true))
        XCTAssertEqual(FTSelector.parse("*保存*&&.button&&enabled=false").primary,
                       FlowLocator(label: "保存", labelMatch: .contains, type: "button",
                                   enabled: false))
        XCTAssertEqual(FTSelector.parse("placeholderContains=氏名").primary,
                       FlowLocator(placeholder: "氏名", placeholderMatch: .contains))
    }

    func testStandaloneOrdinalFilter() {
        XCTAssertEqual(FTSelector.parse("#list >> [3]").primary,
                       FlowLocator(index: 2, scope: [FlowLocator(id: "list")]))
        XCTAssertEqual(FTSelector.parse("pos=3").primary, FlowLocator(index: 2))
        XCTAssertEqual(FTSelector.parse("*行*&&[2]").primary,
                       FlowLocator(label: "行", labelMatch: .contains, index: 1))
    }

    /// ラベルに見える文字列は既知のフィルタ名のときだけフィルタとして読む
    func testUnknownNameBeforeEqualsStaysLabel() {
        XCTAssertEqual(FTSelector.parse("合計: 1,200円").primary, FlowLocator(label: "合計: 1,200円"))
        XCTAssertEqual(FTSelector.parse("設定=オン").primary, FlowLocator(label: "設定=オン"))
        // 既知名と紛らわしくない `名前=値`(SUT の状態表示)は素の文字列のまま
        XCTAssertEqual(FTSelector.parse("notify=off").primary, FlowLocator(label: "notify=off"))
        XCTAssertEqual(FTSelector.parse("notify=*").primary,
                       FlowLocator(label: "notify=", labelMatch: .startsWith))
    }

    // MARK: - id の部分一致(Shirates 準拠。`#` 短縮形だけワイルドカード展開)

    func testIdPartialMatchShorthands() {
        XCTAssertEqual(FTSelector.parse("#foo*").primary,
                       FlowLocator(id: "foo", idMatch: .startsWith))
        XCTAssertEqual(FTSelector.parse("#*foo*").primary,
                       FlowLocator(id: "foo", idMatch: .contains))
        XCTAssertEqual(FTSelector.parse("#*foo").primary,
                       FlowLocator(id: "foo", idMatch: .endsWith))
        // 完全一致(idMatch は nil = exact)
        XCTAssertNil(FTSelector.parse("#foo").primary.idMatch)
    }

    func testIdFilterFullForms() {
        XCTAssertEqual(FTSelector.parse("id=foo").primary, FlowLocator(id: "foo"))
        XCTAssertEqual(FTSelector.parse("idStartsWith=foo").primary,
                       FlowLocator(id: "foo", idMatch: .startsWith))
        XCTAssertEqual(FTSelector.parse("idContains=foo").primary,
                       FlowLocator(id: "foo", idMatch: .contains))
        XCTAssertEqual(FTSelector.parse("idEndsWith=foo").primary,
                       FlowLocator(id: "foo", idMatch: .endsWith))
        XCTAssertEqual(FTSelector.parse("idMatches=^p_\\d+$").primary,
                       FlowLocator(id: "^p_\\d+$", idMatch: .matches))
    }

    /// `id=` 完全形は `#` 短縮形と違いワイルドカード展開しない(text= と同じ非対称)
    func testIdFullFormDoesNotExpandWildcard() {
        XCTAssertEqual(FTSelector.parse("id=foo*").primary, FlowLocator(id: "foo*"))
        XCTAssertNil(FTSelector.parse("id=foo*").primary.idMatch)
    }

    func testIdMatchCombinesWithOtherFilters() {
        XCTAssertEqual(FTSelector.parse(".button&&idContains=save").primary,
                       FlowLocator(id: "save", idMatch: .contains, type: "button"))
    }

    /// `.型#id` 短縮形の `#` 以降も単独 `#` と同じ `*` 展開(割れると `.button#foo*` が never-match)
    func testTypeIdShorthandExpandsWildcard() {
        XCTAssertEqual(FTSelector.parse(".button#foo*").primary,
                       FlowLocator(id: "foo", idMatch: .startsWith, type: "button"))
        XCTAssertEqual(FTSelector.parse(".button#*foo*").primary,
                       FlowLocator(id: "foo", idMatch: .contains, type: "button"))
        // serialize は `#` 形に畳めるときだけ `.型#...` へ戻す(往復同一)
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "foo", idMatch: .startsWith, type: "button")),
                       ".button#foo*")
        XCTAssertEqual(FTSelector.parse(FTSelector.serialize(
            FlowLocator(id: "foo", idMatch: .startsWith, type: "button"))).primary,
                       FlowLocator(id: "foo", idMatch: .startsWith, type: "button"))
    }

    // MARK: - スコープ

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

    func testScopeBindsTighterThanFallbackChain() {
        let selector = FTSelector.parse("#list >> .clickable || #fallback")
        XCTAssertEqual(selector.primary.scope, [FlowLocator(id: "list")])
        XCTAssertEqual(selector.primary.type, "clickable")
        XCTAssertEqual(selector.fallbacks, [FlowLocator(id: "fallback")])
    }

    /// `&&` は `>>` より強く結合する(`#list >> .button&&*保存*` = スコープ内の「button かつ 保存」)
    func testAndBindsTighterThanScope() {
        let locator = FTSelector.parse("#list >> .button&&*保存*").primary
        XCTAssertEqual(locator.scope, [FlowLocator(id: "list")])
        XCTAssertEqual(locator.type, "button")
        XCTAssertEqual(locator.label, "保存")
        XCTAssertEqual(locator.labelMatch, .contains)
    }

    // MARK: - 相対セレクタ(P2・基準が先)

    func testRelativeSelectorIsAnchorFirst() {
        for (text, direction) in [("氏名:rightButton", FlowDirection.right),
                                  ("氏名:leftButton", .left),
                                  ("氏名:aboveButton", .above),
                                  ("氏名:belowButton", .below)] {
            let locator = FTSelector.parse(text).primary
            XCTAssertEqual(locator.label, "氏名", text)
            XCTAssertEqual(locator.relative, [step(direction, type: "button")], text)
        }
    }

    func testRelativeTypeShorthands() {
        XCTAssertEqual(FTSelector.parse("氏名:rightInput").primary.relative,
                       [step(.right, type: "input")])
        XCTAssertEqual(FTSelector.parse("氏名:rightLabel").primary.relative,
                       [step(.right, type: "staticText")])
        XCTAssertEqual(FTSelector.parse("通知:rightSwitch").primary.relative,
                       [step(.right, type: "switch")])
        // 接尾辞なしは既定フィルタ(.widget)= filter は nil のまま
        XCTAssertEqual(FTSelector.parse("通知:right").primary.relative, [step(.right)])
    }

    func testRelativeOrdinalAndFilterArguments() {
        XCTAssertEqual(FTSelector.parse("数量:right(2)").primary.relative,
                       [step(.right, ordinal: 2)])
        XCTAssertEqual(FTSelector.parse("数量:rightButton(2)").primary.relative,
                       [step(.right, type: "button", ordinal: 2)])
        XCTAssertEqual(FTSelector.parse("数量:right(.button)").primary.relative,
                       [step(.right, type: "button")])
        // `[n]` を引数に書いた形は序数へ正規化する(往復のため構造を1つに寄せる)
        XCTAssertEqual(FTSelector.parse("数量:right(.button[2])").primary.relative,
                       [step(.right, type: "button", ordinal: 2)])
        XCTAssertEqual(FTSelector.parse("数量:right(保存||#btn)").primary.relative,
                       [step(.right, filter: [FlowLocator(label: "保存"), FlowLocator(id: "btn")])])
    }

    /// 引数は節1本と同じ文法(スコープも書ける)。`parseSegment` だと丸ごと id になって黙って壊れる
    func testRelativeArgumentAcceptsScope() {
        let step = FTSelector.parse("見出し:below(#list >> .button)").primary.relative?.first
        XCTAssertEqual(step?.filter, [FlowLocator(type: "button", scope: [FlowLocator(id: "list")])])
        XCTAssertNil(FTSelector.validationError("見出し:below(#list >> .button)"))
        // 引数の中の綴り誤りも同じ規則で落とす
        XCTAssertNotNil(FTSelector.validationError("見出し:below(#list >> .Button)"))
        XCTAssertNotNil(FTSelector.validationError("見出し:below(x||)"))
    }

    /// Shirates の正典形 `<基準>:rightButton`。囲みは構文糖でパース結果は囲まない形と同一
    func testBracketedBaseIsSyntacticSugar() {
        XCTAssertEqual(FTSelector.parse("<通知>:rightSwitch").primary,
                       FTSelector.parse("通知:rightSwitch").primary)
        XCTAssertEqual(FTSelector.parse("<変更&&.button>:right(数量)").primary,
                       FTSelector.parse("変更&&.button:right(数量)").primary)
        let locator = FTSelector.parse("<変更&&.button>:right(数量)").primary
        XCTAssertEqual(locator.label, "変更")
        XCTAssertEqual(locator.type, "button")
        XCTAssertEqual(locator.relative, [step(.right, filter: [FlowLocator(label: "数量")])])
        XCTAssertNil(FTSelector.validationError("<変更&&.button>:right(数量)"))
        XCTAssertNil(FTSelector.validationError("#row >> <数量>:rightButton"))
    }

    func testBracketedBaseMalformedIsRejected() {
        // `<` 始まりは括弧形式の予約。読めない形を黙って生ラベルにしない(notExist の緑化防止)
        for text in ["<通知:rightSwitch", "<>:right(通知)", "<通知>rightSwitch", "<注意>",
                     "<通知>:rigthSwitch"] {
            XCTAssertNotNil(FTSelector.validationError(text), "見逃した: \(text)")
        }
        // `<` で始まる生ラベルは = エスケープで書く(serialize も同じ形を出す)
        XCTAssertEqual(FTSelector.parse("=<注意>").primary, FlowLocator(label: "<注意>"))
        XCTAssertEqual(FTSelector.serialize(FlowLocator(label: "<注意>")), "=<注意>")
        XCTAssertNil(FTSelector.validationError("=<注意>"))
    }

    /// serialize は囲みを付けない(囲みは人が読みやすくするための任意記法)
    func testSerializeDoesNotBracket() {
        var locator = FlowLocator(label: "変更", type: "button")
        locator.relative = [FlowRelativeStep(direction: .right, filter: [FlowLocator(label: "数量")])]
        let serialized = FTSelector.serialize(locator)
        XCTAssertEqual(serialized, ".button&&変更:right(数量)")
        XCTAssertEqual(FTSelector.parse(serialized).primary, locator)
        XCTAssertNil(FTSelector.validationError(serialized))
    }

    func testRelativeStepsChain() {
        XCTAssertEqual(FTSelector.parse("見出し:right:belowButton").primary.relative,
                       [step(.right), step(.below, type: "button")])
    }

    func testRelativeSelectorCombinesWithScopeAndFilters() {
        let locator = FTSelector.parse("#row >> 数量&&.staticText:rightButton").primary
        XCTAssertEqual(locator.scope, [FlowLocator(id: "row")])
        XCTAssertEqual(locator.label, "数量")
        XCTAssertEqual(locator.type, "staticText")
        XCTAssertEqual(locator.relative, [step(.right, type: "button")])
    }

    func testFallbackSeparatorInsideArgumentIsNotSplit() {
        let selector = FTSelector.parse("氏名:right(#a||保存)")
        XCTAssertTrue(selector.fallbacks.isEmpty)
        XCTAssertEqual(selector.primary.relative?.first?.filter?.first?.id, "a")
    }

    func testEscapeKeepsSyntaxCharactersAsLabel() {
        XCTAssertEqual(FTSelector.parse("=A >> B").primary, FlowLocator(label: "A >> B"))
        XCTAssertEqual(FTSelector.parse("=x:right(y)").primary, FlowLocator(label: "x:right(y)"))
        XCTAssertEqual(FTSelector.parse("=A && B").primary, FlowLocator(label: "A && B"))
        XCTAssertEqual(FTSelector.parse("=*星*").primary, FlowLocator(label: "*星*"))
    }

    func testMalformedRelativeFallsBackToLabel() {
        // 基準が空 / 引数が空 は構文として解釈しない(パースは失敗しない契約。
        // 誤りとしては validationError が捕まえる = testValidationRejects... を参照)
        XCTAssertEqual(FTSelector.parse(":rightSwitch").primary.label, ":rightSwitch")
        XCTAssertEqual(FTSelector.parse("氏名:right()").primary.label, "氏名:right()")
    }

    // MARK: - 往復

    func testSerializeRoundTrip() {
        for text in ["#login_btn", "ログイン", ".button[2]", ".switch#S1", ".switch&&名前",
                     "*許可*", "許可*", "*許可", "textMatches=^許.$", ".button&&*保存*",
                     "notify=off", "notify=*", "#a:below(.button&&項目&&[2])",
                     "#save&&.button", ".textField&&value=太郎", ".switch&&checked=true",
                     "*保存*&&.button&&enabled=false", "placeholderContains=氏名",
                     "#list >> [3]", "#list >> [1]", "*行*&&[2]",
                     "#list >> .clickable[2]", "#page >> #list >> ラベル",
                     "氏名:rightButton", "通知:rightSwitch", "通知:right", "数量:right(2)",
                     "数量:rightButton(2)", "数量:right(保存||#btn)", "見出し:right:belowButton",
                     "#row >> 数量&&.staticText:rightButton", "見出し:below(#list >> .button)",
                     "<通知>:rightSwitch", "#row >> <数量>:rightButton",
                     "=#raw", "=A >> B",
                     "#foo*", "#*foo*", "#*foo", "idStartsWith=foo", "idMatches=^p_\\d+$",
                     ".button&&idContains=save", ".button&&idContains!=save", ".button&&!#foo*"] {
            let parsed = FTSelector.parse(text)
            let serialized = FTSelector.serialize(primary: parsed.primary,
                                                  fallbacks: parsed.fallbacks)
            XCTAssertEqual(FTSelector.parse(serialized).primary, parsed.primary,
                           "往復で壊れた: \(text) → \(serialized)")
            XCTAssertNil(FTSelector.validationError(serialized),
                         "直列化したら構文エラーになった: \(text) → \(serialized)")
        }
    }

    func testSerializeKeepsShorthandForms() {
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "a")), "#a")
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "a", type: "switch")), ".switch#a")
        XCTAssertEqual(FTSelector.serialize(FlowLocator(label: "名前", type: "switch")), ".switch&&名前")
        XCTAssertEqual(FTSelector.serialize(FlowLocator(type: "button", index: 1)), ".button[2]")
        XCTAssertEqual(FTSelector.serialize(FlowLocator(label: "保存", labelMatch: .contains)),
                       "*保存*")
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "a", type: "button", enabled: true)),
                       ".button&&#a&&enabled=true")
        // id の部分一致は `#` 短縮形へ畳む(値自体が `*` を含まないとき)
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "foo", idMatch: .startsWith)), "#foo*")
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "foo", idMatch: .contains)), "#*foo*")
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "foo", idMatch: .endsWith)), "#*foo")
        // matches は正規表現なので `#` 短縮形が無い(text 系と同じ)
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "^p_\\d+$", idMatch: .matches)),
                       "idMatches=^p_\\d+$")
        // 値自体が先頭/末尾 `*` を持つ完全一致は `#` 短縮形にすると再パースでワイルドカードに
        // 化けるので完全形に落とす
        XCTAssertEqual(FTSelector.serialize(FlowLocator(id: "foo*")), "id=foo*")
        XCTAssertEqual(FTSelector.parse(FTSelector.serialize(FlowLocator(id: "foo*"))).primary,
                       FlowLocator(id: "foo*"))
    }

    func testSerializeEscapesLabelsContainingSyntax() {
        let locator = FlowLocator(label: "A >> B")
        XCTAssertEqual(FTSelector.serialize(locator), "=A >> B")
        XCTAssertEqual(FTSelector.parse(FTSelector.serialize(locator)).primary, locator)
        // 検証が拒否するパターン(未知マーカー・方向名の書き損じ)もエスケープする
        // (しないと serialize の出力=ヒール提案・生成コードがそのまま構文エラーで落ちる)
        for text in ["a:rigth(b)", "予定:AM(補足)", "高さ:righ", "x:near(y)"] {
            let escaped = FTSelector.serialize(FlowLocator(label: text))
            XCTAssertEqual(escaped, "=\(text)", text)
            XCTAssertEqual(FTSelector.parse(escaped).primary, FlowLocator(label: text), text)
            XCTAssertNil(FTSelector.validationError(escaped), text)
        }
        // 合成中は `=` エスケープが使えないので完全形 text= に落とす
        let starred = FlowLocator(label: "*星*", type: "button")
        XCTAssertEqual(FTSelector.serialize(starred), ".button&&text=*星*")
        XCTAssertEqual(FTSelector.parse(FTSelector.serialize(starred)).primary, starred)
    }

    func testSummaryShowsScopeAndRelativeSteps() {
        let locator = FTSelector.parse("#list >> 合計:rightLabel").primary
        XCTAssertEqual(locator.summary, "id=list >> text=合計:right(staticText)")
    }

    // MARK: - 構文検証(パースが黙って label に落とす誤りを実行前に落とす)

    func testValidationAcceptsValidSelectors() {
        for text in ["#login_btn", "ログイン", ".button[2]", ".switch#S1", ".switch&&名前",
                     "*許可*", "許可*", "*許可", "textContains=許可", "textMatches=^許.$",
                     "#save&&.button", ".switch&&checked=true", "value=太郎",
                     "#list >> .clickable[2]", "#list >> [3]", "#list >> pos=3",
                     "氏名:rightButton", "通知:right", "数量:right(2)", "数量:right(.button)",
                     "見出し:right:belowButton", "氏名:right(#a||保存)",
                     "=x:rigth(y)", "=A >> B", "合計: 1,200円", "設定=オン", "#a||ラベル",
                     "notify=off", "notify=*", "*qty=*",
                     "#foo*", "#*foo*", "#*foo", "idStartsWith=foo", "idContains=foo",
                     "idEndsWith=foo", "idMatches=^p_\\d+$", ".button&&idContains!=save",
                     // 既知名と紛らわしくない `名前=値` は素の文字列のまま(id と前方一致しない)
                     "identifier=5"] {
            XCTAssertNil(FTSelector.validationError(text), "誤検出: \(text)")
        }
    }

    func testValidationRejectsUnknownMarker() {
        // 他ツール記法・綴り誤りが「そんなラベルは無い」で緑になるのを防ぐ
        for text in ["氏名:rigth(合計)", "氏名:near(合計)", ".button:descendant(#a)",
                     "#list >> .clickable:sibling(合計)",
                     // 括弧が無い綴り誤りも落とす(ラベル扱いになると notExist が必ず成功する)
                     "氏名:rightFoo", "氏名:righ", "氏名:RightSwitch"] {
            XCTAssertNotNil(FTSelector.validationError(text), "見逃した: \(text)")
        }
    }

    func testValidationRejectsMalformedSyntax() {
        for text in ["氏名:right(", "氏名:right(合計))", "氏名:right()", ":rightSwitch",
                     "氏名:right(合計)の右", ".button[abc]", ".button[0]", "[2]", "pos=2", "**",
                     ".button&&", "&&.button", "pos=0", "checked=yes", "text=", "id="] {
            XCTAssertNotNil(FTSelector.validationError(text), "見逃した: \(text)")
        }
    }

    func testValidationRejectsUnknownFilterName() {
        for text in ["textContans=許可", ".button&&valu=太郎", "checkd=true",
                     // 相対セレクタの引数の中も同じ規則で見る
                     "氏名:right(textContans=保存)"] {
            XCTAssertNotNil(FTSelector.validationError(text), "見逃した: \(text)")
        }
    }

    /// 未知名が既知の基底名を接頭辞に持ち、直後が ASCII 大文字なら near-miss(規則④)。
    /// `identifier` のような小文字継続の生ラベルは巻き込まない(testValidationAcceptsValidSelectors 参照)
    func testValidationRejectsBaseNamePrefixedUppercaseContinuation() {
        for text in ["idPrefix=x", "idIs=x", "textFoo=x", "valueX=x", ".button&&idPrefix!=x"] {
            XCTAssertNotNil(FTSelector.validationError(text), "見逃した: \(text)")
        }
    }

    func testValidationRejectsDuplicateFilter() {
        XCTAssertNotNil(FTSelector.validationError("*保存*&&text=保存"))
        XCTAssertNotNil(FTSelector.validationError("#a&&id=b"))
        // idContains= 等の一致方法違いも「id」属性として重複判定に入る(text 系と同じ規律)
        XCTAssertNotNil(FTSelector.validationError("#a&&idContains=b"))
        XCTAssertNotNil(FTSelector.validationError("idStartsWith=a&&idEndsWith=b"))
    }

    /// 型名に `=` は使えない。パースは `=` 以降を型名の一部として黙って読む(never-match)ため、
    /// 実行前エラー+書き換え案で必ず落とす
    func testValidationRejectsEqualsInTypeName() {
        for (text, rewrite) in [(".switch=名前", ".switch&&名前"),
                                (".button=*保存*", ".button&&*保存*"),
                                // 先頭大文字も同じエラーで小文字化した案を出す(二段の案内をさせない)
                                (".Button=変更", ".button&&変更"),
                                // `=` が `#` より前なら id 短縮形ではなく廃止記法(`#` はラベルの一部)
                                (".button=A#B", ".button&&A#B"),
                                // 相対セレクタの基準に書いた場合も基準の検証で捕まる
                                (".button=変更:left(数量)", ".button&&変更"),
                                (".button=項目:below(#btn_allow)", ".button&&項目")] {
            let error = FTSelector.validationError(text)
            XCTAssertNotNil(error, "見逃した: \(text)")
            XCTAssertTrue(error?.contains("型名") ?? false, "案内が無い: \(text)")
            XCTAssertTrue(error?.contains(rewrite) ?? false,
                          "書き換え案 \(rewrite) が無い: \(String(describing: error))")
        }
        // `.型#id` の短縮形は存続(誤検出しない)
        XCTAssertNil(FTSelector.validationError(".button#btn_allow"))
        XCTAssertEqual(FTSelector.parse(".button&&A#B").primary,
                       FlowLocator(label: "A#B", type: "button"))
    }

    func testValidationRejectsUppercaseTypeName() {
        XCTAssertNotNil(FTSelector.validationError(".Button"))
        XCTAssertNotNil(FTSelector.validationError("#list >> .Clickable[2]"))
    }

    // MARK: - フィルタ内 OR `(a|b)`(Shirates 準拠。パース時に節へ展開する)

    func testFilterGroupExpandsToClauses() {
        let selector = FTSelector.parse("(保存|OK)")
        XCTAssertEqual(selector.primary, FlowLocator(label: "保存"))
        XCTAssertEqual(selector.fallbacks, [FlowLocator(label: "OK")])
        // `||` で書いたものと同じ構造になる(ドキュメントが「等価」と書いている形)
        XCTAssertEqual(FTSelector.parse("保存||OK").primary, selector.primary)
        XCTAssertEqual(FTSelector.parse("保存||OK").fallbacks, selector.fallbacks)
    }

    func testFilterGroupCombinesWithOtherConditions() {
        let selector = FTSelector.parse(".button&&(保存|OK)")
        XCTAssertEqual(selector.primary, FlowLocator(label: "保存", type: "button"))
        XCTAssertEqual(selector.fallbacks, [FlowLocator(label: "OK", type: "button")])
    }

    func testFilterGroupWorksForNamedFiltersAndShorthands() {
        XCTAssertEqual(FTSelector.parse("text=(a|b)").fallbacks, [FlowLocator(label: "b")])
        XCTAssertEqual(FTSelector.parse("(#a|#b)").fallbacks, [FlowLocator(id: "b")])
        // 部分一致記法とも併用できる(トークン単位の置換なので `*` が両方に付く)
        XCTAssertEqual(FTSelector.parse("*(a|b)*").primary,
                       FlowLocator(label: "a", labelMatch: .contains))
    }

    func testFilterGroupInScopeAndRelativeArgument() {
        let scoped = FTSelector.parse("(#l1|#l2) >> .cell")
        XCTAssertEqual(scoped.fallbacks.count, 1)
        XCTAssertEqual(scoped.primary.scope, [FlowLocator(id: "l1")])
        XCTAssertEqual(scoped.fallbacks[0].scope, [FlowLocator(id: "l2")])
        // 相対セレクタの引数の中では、グループの括弧を**自分で書く**
        // (`:right(...)` の括弧は引数の括弧なので、`:right(a|b)` の `|` は区切りにならない)
        let relative = FTSelector.parse("通知:right((保存|OK))")
        XCTAssertEqual(relative.primary.relative?.first?.filter,
                       [FlowLocator(label: "保存"), FlowLocator(label: "OK")])
    }

    func testGroupParenthesesWithoutPipeStayLiteral() {
        // `|` を含まない括弧はラベルの一部(展開しない)
        let selector = FTSelector.parse("保存(推奨)")
        XCTAssertEqual(selector.primary, FlowLocator(label: "保存(推奨)"))
        XCTAssertTrue(selector.fallbacks.isEmpty)
    }

    func testValidationRejectsEmptyGroupAlternative() {
        XCTAssertNotNil(FTSelector.validationError("(保存|)"))
        XCTAssertNotNil(FTSelector.validationError("(a||b)"))
        XCTAssertNil(FTSelector.validationError("(保存|OK)"))
    }

    func testGroupLabelNeedsEscapeOnSerialize() {
        // `(a|b)` そのものをラベルにしたいときは `=` エスケープ。serialize も同じ形に戻す
        let escaped = FTSelector.parse("=(a|b)")
        XCTAssertEqual(escaped.primary, FlowLocator(label: "(a|b)"))
        XCTAssertTrue(escaped.fallbacks.isEmpty)
        XCTAssertEqual(FTSelector.serialize(escaped.primary), "=(a|b)")
    }

    // MARK: - 否定フィルタ `!=`

    func testNegationFilterParsesIntoNot() {
        let locator = FTSelector.parse(".button&&text!=キャンセル").primary
        XCTAssertEqual(locator.type, "button")
        XCTAssertEqual(locator.not, [FlowLocator(label: "キャンセル")])
        XCTAssertNil(locator.label)
    }

    func testNegationSupportsMatchModesAndOtherAttributes() {
        XCTAssertEqual(FTSelector.parse(".cell&&textContains!=済").primary.not,
                       [FlowLocator(label: "済", labelMatch: .contains)])
        XCTAssertEqual(FTSelector.parse(".button&&id!=btn_x").primary.not,
                       [FlowLocator(id: "btn_x")])
        XCTAssertEqual(FTSelector.parse(".button&&idContains!=save").primary.not,
                       [FlowLocator(id: "save", idMatch: .contains)])
        XCTAssertEqual(FTSelector.parse(".button&&enabled!=false").primary.not,
                       [FlowLocator(enabled: false)])
    }

    func testNegationRoundTrips() {
        for text in [".button&&text!=キャンセル", ".cell&&textContains!=済",
                     "#list >> .cell&&text!=空", ".button&&text!=A&&text!=B"] {
            XCTAssertNil(FTSelector.validationError(text), text)
            let locator = FTSelector.parse(text).primary
            XCTAssertEqual(FTSelector.serialize(locator), text, text)
        }
    }

    func testValidationRejectsNegationOnlyClauseAndBadNames() {
        XCTAssertNotNil(FTSelector.validationError("text!=キャンセル"))     // 否定だけ
        // 綴り誤りの判定規則は肯定形と同じ(前方一致関係にある `textContans` は落ちるが、
        // `txet` のような入れ替え誤りは既知の残穴として通る = isNearMissFilterName の規律)
        XCTAssertNotNil(FTSelector.validationError(".button&&textContans!=x"))
        XCTAssertNotNil(FTSelector.validationError(".button&&pos!=2"))     // pos は否定不可
        XCTAssertNotNil(FTSelector.validationError(".button&&enabled!=yes"))
        XCTAssertNotNil(FTSelector.validationError(".button&&text!="))     // 値が空
    }

    func testPlainLabelWithBangEqualsStaysLiteral() {
        // SUT の表示に現れる `x!=y` は素の文字列(フィルタ名でなければ素通し)
        XCTAssertNil(FTSelector.validationError("count!=0"))
        XCTAssertEqual(FTSelector.parse("count!=0").primary, FlowLocator(label: "count!=0"))
    }

    // MARK: - 否定の短縮形 `!値`(Shirates 準拠)

    func testNegationShorthandMatchesFullForm() {
        for (short, full) in [(".button&&!キャンセル", ".button&&text!=キャンセル"),
                              (".cell&&!#row_1", ".cell&&id!=row_1"),
                              (".cell&&!#save*", ".cell&&idStartsWith!=save"),
                              ("#list >> .cell&&!.image", "#list >> .cell&&type!=image")] {
            XCTAssertNil(FTSelector.validationError(short), short)
            XCTAssertEqual(FTSelector.parse(short).primary,
                           FTSelector.parse(full).primary, short)
            // 表示は完全形へ正規化する(記法を1つに保つ)
            XCTAssertEqual(FTSelector.serialize(FTSelector.parse(short).primary), full, short)
        }
    }

    /// 否定は肯定と同じ属性に重ねて書ける(重複条件の検査から外す)
    func testNegationDoesNotCollideWithPositiveFilter() {
        for text in [".button&&項目&&!#btn_item_2",
                     ".button&&項目&&!#btn_item_1&&!#btn_item_2",
                     ".button&&*許可*&&!許可",
                     ".button&&項目&&id!=btn_item_2"] {
            XCTAssertNil(FTSelector.validationError(text), text)
        }
    }

    func testNegationShorthandValidation() {
        XCTAssertNotNil(FTSelector.validationError("!キャンセル"))       // 否定だけの節
        XCTAssertNotNil(FTSelector.validationError(".button&&![2]"))   // 序数は否定できない
        XCTAssertNotNil(FTSelector.validationError(".button&&!textContans=x"))
        // `=` エスケープで「!」始まりのラベルはそのまま書ける
        XCTAssertEqual(FTSelector.parse("=!注意").primary, FlowLocator(label: "!注意"))
    }
}

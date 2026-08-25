// ft_batch のステップ文法(BatchLineParser / BatchArgSpecTable / BatchStepResolver)専用のテスト。
// MCPBatchTests.swift はツール全体(server.call 経由)の契約を見るのに対し、こちらは
// パーサ・引数の妥当性判定を単体で見る(デバイス・MCPServer の状態には一切触れない)。

import XCTest
// @testable: ScenarioCodeGen.command(for:) は internal(FTCore に住む。移動前は FTDSL だった)
@testable import FTCore
@testable import ftester_mcp

final class BatchLineParserTests: XCTestCase {

    // MARK: - 文字列・日本語・エスケープ('…' のみ)

    func testQuotedStringWithJapanese() throws {
        let parsed = try BatchLineParser.parse("type '#field' 'ログイン'")
        XCTAssertEqual(parsed.name, "type")
        XCTAssertEqual(parsed.args, [
            BatchLineArg(label: nil, value: .string("#field")),
            BatchLineArg(label: nil, value: .string("ログイン")),
        ])
    }

    func testEscapedQuoteAndBackslash() throws {
        let parsed = try BatchLineParser.parse("type '#f' 'say \\'hi\\' \\\\ ok'")
        XCTAssertEqual(parsed.args.last?.value, .string("say 'hi' \\ ok"))
    }

    // "…" は '…' と等価(JSON の \" 経由で届く自然な書き方を拒まない。推奨は '…')

    func testDoubleQuotedStringEqualsSingleQuoted() throws {
        XCTAssertEqual(try BatchLineParser.parse("type \"#field\" \"ログイン\""),
                       try BatchLineParser.parse("type '#field' 'ログイン'"))
    }

    func testEachQuoteStyleMayContainTheOtherQuote() throws {
        XCTAssertEqual(try BatchLineParser.parse("type '#f' 'say \"hi\"'").args.last?.value,
                       .string("say \"hi\""))
        XCTAssertEqual(try BatchLineParser.parse("type \"#f\" \"it's\"").args.last?.value,
                       .string("it's"))
    }

    func testUnterminatedStringIsRejected() {
        for line in ["tap '#a", "tap \"#a", "tap '#a\""] {  // 3本目は引用符の混在(閉じ違い)
            XCTAssertThrowsError(try BatchLineParser.parse(line), line) { error in
                XCTAssertTrue((error as? BatchLineSyntaxError)?.reason.contains("unterminated") == true,
                              "\(error)")
            }
        }
    }

    // MARK: - 位置引数とラベル付き引数の混在

    func testPositionalAndLabeledArgsMixed() throws {
        let parsed = try BatchLineParser.parse("tap '#a' holdSeconds: 1.5 timeout: 2")
        XCTAssertEqual(parsed.args, [
            BatchLineArg(label: nil, value: .string("#a")),
            BatchLineArg(label: "holdSeconds", value: .number(1.5)),
            BatchLineArg(label: "timeout", value: .number(2)),
        ])
    }

    // MARK: - ドット形

    func testDotIdentifierValue() throws {
        let parsed = try BatchLineParser.parse("swipe .down")
        XCTAssertEqual(parsed.args, [BatchLineArg(label: nil, value: .dotIdent("down"))])
    }

    func testDotIdentifierAsLabeledValue() throws {
        let parsed = try BatchLineParser.parse("scrollTo '#a' direction: .up")
        XCTAssertEqual(parsed.args.last, BatchLineArg(label: "direction", value: .dotIdent("up")))
    }

    // MARK: - 引数なしは名前だけ

    func testBareNameWithoutArgs() throws {
        let parsed = try BatchLineParser.parse("pressEnter")
        XCTAssertEqual(parsed, BatchParsedLine(name: "pressEnter", args: []))
    }

    // MARK: - 行末 `;`・余分な空白(`;` は splitSteps が消す — normalize は trim だけ)

    func testTrailingSemicolonAndWhitespaceAreStripped() {
        XCTAssertEqual(MCPServer.flattenBatchLines("   tap '#a'  ;  "), ["tap '#a'"])
    }

    // MARK: - 引数の区切りは空白だけ(黙って連結を2引数に読まない)

    func testMissingSpaceBetweenArgumentsIsRejected() {
        XCTAssertThrowsError(try BatchLineParser.parse("type '#field''abc'")) { error in
            guard let syntax = error as? BatchLineSyntaxError else { return XCTFail("\(error)") }
            XCTAssertTrue(syntax.reason.contains("space between arguments"), syntax.reason)
        }
    }

    func testStrayClosingParenIsNamed() {
        XCTAssertThrowsError(try BatchLineParser.parse("tap '#a')")) { error in
            guard let syntax = error as? BatchLineSyntaxError else { return XCTFail("\(error)") }
            XCTAssertTrue(syntax.reason.contains("stray \")\""), syntax.reason)
        }
    }

    // MARK: - 廃止した表記(正形の括弧・カンマ)は書き換え方を添えて拒む

    func testParenthesizedCallIsRejectedWithTheRewrite() {
        XCTAssertThrowsError(try BatchLineParser.parse("type(\"#field\", \"abc\")")) { error in
            guard let syntax = error as? BatchLineSyntaxError else { return XCTFail("\(error)") }
            XCTAssertTrue(syntax.reason.contains("parentheses"), syntax.reason)
            XCTAssertTrue(syntax.reason.contains("type '#id'"), syntax.reason)
        }
    }

    func testCommaBetweenArgsIsRejectedWithTheRewrite() {
        for line in ["type '#f', 'abc'", "type '#f' , 'abc'", "type '#f' 'a',"] {
            XCTAssertThrowsError(try BatchLineParser.parse(line), line) { error in
                guard let syntax = error as? BatchLineSyntaxError else { return XCTFail("\(error)") }
                XCTAssertTrue(syntax.reason.contains("spaces, not commas"), syntax.reason)
            }
        }
    }

    // MARK: - 手の分割(splitSteps: ";" と改行。引用符の中は区切らない)

    func testSplitStepsOnSemicolonWithAndWithoutSpaces() {
        for element in [
            "type '#f' 'abc';scrollTo '#item' direction: .down",
            "type '#f' 'abc'; scrollTo '#item' direction: .down",
            "type '#f' 'abc' ;scrollTo '#item' direction: .down",
        ] {
            XCTAssertEqual(MCPServer.flattenBatchLines(element),
                           ["type '#f' 'abc'", "scrollTo '#item' direction: .down"], element)
        }
    }

    func testSplitStepsDoesNotSplitInsideQuotes() {
        XCTAssertEqual(BatchLineParser.splitSteps("type '#f' 'a;b'"), ["type '#f' 'a;b'"])
        XCTAssertEqual(BatchLineParser.splitSteps("type \"#f\" \"a;b\";swipe .up"),
                       ["type \"#f\" \"a;b\"", "swipe .up"])
    }

    // MARK: - 空行・改行分割(MCPServer.flattenBatchLines)

    func testFlattenDropsBlankLinesAndSemicolons() {
        let lines = MCPServer.flattenBatchLines("  ; tap '#a'; \n ;swipe .up")
        XCTAssertEqual(lines, ["tap '#a'", "swipe .up"])
    }

    func testFlattenSplitsOnNewlines() {
        let lines = MCPServer.flattenBatchLines("tap '#a'\nswipe .up\n\ntap '#b'")
        XCTAssertEqual(lines, ["tap '#a'", "swipe .up", "tap '#b'"])
    }

    // MARK: - 入れ子呼び出し・配列・演算子・クロージャを弾く

    func testNestedCallIsRejected() {
        XCTAssertThrowsError(try BatchLineParser.parse("tap foo('x')")) { error in
            guard let syntax = error as? BatchLineSyntaxError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(syntax.reason.contains("nested calls"), syntax.reason)
        }
    }

    func testArrayLiteralIsRejected() {
        XCTAssertThrowsError(try BatchLineParser.parse("tap ['#a' '#b']")) { error in
            guard let syntax = error as? BatchLineSyntaxError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(syntax.reason.contains("arrays"), syntax.reason)
        }
    }

    func testClosureIsRejected() {
        XCTAssertThrowsError(try BatchLineParser.parse("withScrollDown { tap '#a' }")) { error in
            XCTAssertTrue(error is BatchLineSyntaxError, "\(error)")
        }
    }

    // MARK: - 未知の名前でも構文レベルでは name が読める(呼び出し側がシグネチャの有無を判定する)

    func testSyntaxErrorStillCapturesTheCommandNameWhenReadable() {
        XCTAssertThrowsError(try BatchLineParser.parse("tap #a")) { error in
            guard let syntax = error as? BatchLineSyntaxError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(syntax.commandName, "tap")
        }
    }

    // MARK: - 引数の数が合わない場合を弾く(BatchStepResolver)

    func testTooManyPositionalArgumentsIsRejected() {
        // pressEnter はシグネチャに引数が無い
        XCTAssertThrowsError(try resolve(command: "pressEnter", line: "pressEnter '#a'")) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("does not take"), message)
        }
    }

    // MARK: - 未対応ラベルを名指しで弾く

    func testUnsupportedLabelNamesItselfAndListsWhatIsSupported() {
        XCTAssertThrowsError(
            try resolve(command: "tap", line: "tap '#a' containerInference: true")
        ) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("\"containerInference:\""), message)
            XCTAssertTrue(message.contains("does not support"), message)
            XCTAssertTrue(message.contains("selector, holdSeconds, timeout"), message)
        }
    }

    // MARK: - 未知のラベル(シグネチャにも無い)は別の文言で弾く

    func testUnknownLabelIsRejectedWithADifferentMessage() {
        XCTAssertThrowsError(try resolve(command: "tap", line: "tap '#a' bogus: 1")) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("\"bogus:\""), message)
            XCTAssertTrue(message.contains("has no"), message)
            XCTAssertFalse(message.contains("does not support"), message)
        }
    }

    // MARK: - coverage: ビルダを持つ全コマンドが「シグネチャから導出できる」か「明示表にある」

    func testEveryBatchBuilderCommandHasAResolvableArgSpec() {
        for command in MCPServer.batchStepBuilders.keys.sorted() {
            guard let info = DSLCommandIndex.all.first(where: { $0.name == command }) else {
                return XCTFail("\(command) はビルダを持つのに DSLCommandIndex に無い")
            }
            let forms = BatchArgSpecTable.forms(for: command, signature: info.signature)
            XCTAssertFalse(forms.isEmpty,
                           "\(command) はシグネチャ \"\(info.signature)\" から引数の形を導出できず、"
                            + "positionalOverrides にも無い — 明示表へ追加すること")
        }
    }

    /// 導出した位置引数(エイリアス適用後)は、必ずそのビルダの宣言キーに含まれる ——
    /// 名前が食い違うと「解決はできるが辞書キーが違ってビルダに無視される」という
    /// 一番気付きにくい壊れ方をする
    func testDerivedPositionalNamesAreAlwaysAmongTheBuilderDeclaredKeys() {
        for (command, builder) in MCPServer.batchStepBuilders {
            guard let info = DSLCommandIndex.all.first(where: { $0.name == command }) else { continue }
            for form in BatchArgSpecTable.forms(for: command, signature: info.signature) {
                for name in form.positional {
                    let dictKey = BatchArgSpecTable.dictKeyAliases[name] ?? name
                    XCTAssertTrue(builder.keys.contains(dictKey),
                                  "\(command): 位置引数 \"\(name)\" (dict key \"\(dictKey)\") が"
                                    + " 宣言キー \(builder.keys) に無い")
                }
            }
        }
    }

    // MARK: - 往復: ScenarioCodeGen が描く行(正形)を最小形へ変換してパーサへ戻し、同じ正形が再び出ること
    //
    // バッチ文法は最小形のみ(正形は受けない)なので、正形→最小形の機械変換を挟む。
    // このゲートが守るのは「executor/codegen が表せる全ステップがバッチ文法でも表せる」こと

    /// 正形 `tap("#a", holdSeconds: 1.5)` → 最小形 `tap '#a' holdSeconds: 1.5`。
    /// 引用符の中を守りながら、トップレベルの `(` `)` `,` を空白に・`"` を `'` に置き換える
    private func minimalForm(of canonical: String) -> String {
        var out = ""
        var inQuote = false
        var escaped = false
        for ch in canonical {
            if inQuote {
                if escaped { escaped = false; out.append(ch); continue }
                if ch == "\\" { escaped = true; out.append(ch); continue }
                if ch == "\"" { inQuote = false; out.append("'"); continue }
                out.append(ch)
                continue
            }
            switch ch {
            case "\"": inQuote = true; out.append("'")
            case "(", ")", ",": out.append(" ")
            default: out.append(ch)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// 往復の見本。**`testEveryBatchExecutableCommandRoundTrips` が「ft_batch が実行できる
    /// コマンドを全部覆っているか」を等号で見る**ので、ビルダを足したらここへも1本足すこと
    private static func roundTripFixtures() -> [FlowStep] {
        let selA = FTSelector.parse("#a")
        let selB = FTSelector.parse("#b")
        func fallbacks(_ sel: FTSelector) -> [FlowLocator]? {
            sel.fallbacks.isEmpty ? nil : sel.fallbacks
        }
        return [
            FlowStep(action: "tap", locator: selA.primary, fallbacks: fallbacks(selA)),
            FlowStep(action: "tap", locator: selA.primary, fallbacks: fallbacks(selA), duration: 1.5),
            FlowStep(action: "select", locator: selA.primary, fallbacks: fallbacks(selA)),
            FlowStep(action: "type", locator: selA.primary, fallbacks: fallbacks(selA), text: "hello"),
            FlowStep(action: "type", locator: nil, text: "hello"),  // フォーカス中の要素へ(セレクタ省略)
            FlowStep(action: "pressEnter"),
            FlowStep(action: "hideKeyboard"),
            FlowStep(action: "clearInput", locator: selA.primary, fallbacks: fallbacks(selA)),
            FlowStep(action: "clearInput", locator: nil),
            FlowStep(action: "swipe", direction: "up"),
            FlowStep(action: "swipe", direction: "left"),
            FlowStep(action: "doubleTap", locator: selA.primary, fallbacks: fallbacks(selA)),
            FlowStep(action: "doubleTap", locator: nil),
            FlowStep(action: "pinchOut", locator: selA.primary, fallbacks: fallbacks(selA),
                    duration: 1.0, scale: 3.0),
            FlowStep(action: "pinchIn", locator: nil, scale: 0.3),
            FlowStep(action: "swipeBy", locator: selA.primary, fallbacks: fallbacks(selA),
                    duration: 2.0, dxRatio: 0.5, dyRatio: -0.2),
            FlowStep(action: "swipeElementToElement", locator: selA.primary,
                    fallbacks: fallbacks(selA), endLocator: selB.primary),
            FlowStep(action: "scrollTo", locator: selA.primary, fallbacks: fallbacks(selA),
                    direction: "down", maxSwipes: 3,
                    scrollFrame: FTSelector.parse("#list").primary),
            FlowStep(action: "scrollTo", locator: selA.primary, fallbacks: fallbacks(selA)),
            FlowStep(action: "rotateTo", direction: "landscape"),
            // scroll / scrollToEdge は**向きごとに DSL 名が違う**(scrollDown … scrollToLeftEdge)。
            // 名前の写像も往復で確かめたいので4方向とも置く
            FlowStep(action: "scroll", direction: "up",
                     scrollFrame: FTSelector.parse("#list").primary),
            FlowStep(action: "scroll", direction: "down", maxSwipes: 3),
            FlowStep(action: "scroll", direction: "left"),
            FlowStep(action: "scroll", direction: "right"),
            FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 12,
                     scrollFrame: FTSelector.parse("#list").primary),
            FlowStep(action: "scrollToEdge", direction: "down"),
            FlowStep(action: "scrollToEdge", direction: "left"),
            FlowStep(action: "scrollToEdge", direction: "right"),
        ]
    }

    /// **ft_batch が実行できるコマンドは全部シナリオ行へ書き戻せること**。
    /// 見本を並べるだけの往復テストでは、**ビルダを足しても見本を足さなければ黙って穴が空く**
    /// —— 実際 `scrollDown/Up/Left/Right` は実行できるのに codegen に `case "scroll"` が無く、
    /// `// (unsupported step: …)` へ落ちていた(2026-08-12 に発見)。等号で照合して、
    /// ビルダを足した人が見本も足さざるを得ないようにする
    func testEveryBatchExecutableCommandRoundTrips() {
        let rendered = Self.roundTripFixtures().compactMap { ScenarioCodeGen.command(for: $0) }
        let covered = Set(rendered.map { String($0.prefix(while: { $0 != "(" })) })
        XCTAssertEqual(covered, Set(MCPServer.batchStepBuilders.keys),
                       "ft_batch が実行できるコマンドと、往復の見本が食い違っている"
                       + "(見本を足すか、ScenarioCodeGen に描き方を足すこと)")
    }

    func testRoundTripThroughScenarioCodeGen() throws {
        for step in Self.roundTripFixtures() {
            guard let line = ScenarioCodeGen.command(for: step) else {
                return XCTFail("ScenarioCodeGen が \(step) を描けなかった(fixture 側の不備)")
            }
            let parsed = try BatchLineParser.parse(minimalForm(of: line))
            guard let info = DSLCommandIndex.all.first(where: { $0.name == parsed.name }) else {
                return XCTFail("\(line): \(parsed.name) が DSLCommandIndex に無い")
            }
            guard let builder = MCPServer.batchStepBuilders[parsed.name] else {
                return XCTFail("\(line): \(parsed.name) にビルダが無い")
            }
            let raw = try BatchStepResolver.resolve(command: parsed.name, signature: info.signature,
                                                    args: parsed.args, declaredKeys: builder.keys)
            let (rebuilt, _) = try builder.build(raw)
            let roundTripLine = ScenarioCodeGen.command(for: rebuilt)
            XCTAssertEqual(line, roundTripLine, "round trip mismatch for \(line)")
        }
    }

    // MARK: - helper

    private func resolve(command: String, line: String) throws -> [String: Any] {
        let parsed = try BatchLineParser.parse(line)
        let info = DSLCommandIndex.all.first(where: { $0.name == command })!
        let builder = MCPServer.batchStepBuilders[command]!
        return try BatchStepResolver.resolve(command: command, signature: info.signature,
                                             args: parsed.args, declaredKeys: builder.keys)
    }
}

import XCTest
@testable import FTDSL

final class StepCommandParamsTests: XCTestCase {

    func testSpecsForVerbs() {
        XCTAssertEqual(StepCommandParams.specs(forVerb: "exist").map(\.name), ["timeout"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "present").map(\.name), ["timeout"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "textIs").map(\.name),
                       ["timeout", "occlusionGuard"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "valueIs").map(\.name),
                       ["timeout", "occlusionGuard"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "scrollTo").map(\.name),
                       ["direction", "maxSwipes"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "press").map(\.name),
                       ["duration", "optional", "timeout"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "type").map(\.name),
                       ["optional", "timeout"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "tap").map(\.name), ["timeout"])
    }

    func testSpecsEmptyForVerbsWithoutHiddenParams() {
        XCTAssertEqual(StepCommandParams.specs(forVerb: "swipe"), [])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "wait"), [])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "procedure"), [])
    }

    func testParseKeywordArgument() {
        XCTAssertEqual(StepCommandParams.parse(code: "exist(\"WiFi\", timeout: 15)",
                                               verb: "exist"),
                       ["timeout": "15"])
    }

    func testPresentParsesLikeExist() {
        XCTAssertEqual(StepCommandParams.parse(code: "present(\"#ok\", timeout: 3)",
                                               verb: "present"),
                       ["timeout": "3"])
        XCTAssertEqual(StepCommandParams.parse(code: "present(\"#ok\")", verb: "present"),
                       ["timeout": ""])
    }

    func testTextIsOcclusionGuardOptOut() {
        // 既定は occlusionGuard=true。オプトアウトを読み取れること
        XCTAssertEqual(
            StepCommandParams.parse(code: "textIs(\"#t\", \"hi\")", verb: "textIs"),
            ["timeout": "", "occlusionGuard": "true"])
        XCTAssertEqual(
            StepCommandParams.parse(code: "textIs(\"#t\", \"hi\", occlusionGuard: false)", verb: "textIs"),
            ["timeout": "", "occlusionGuard": "false"])
        XCTAssertEqual(
            StepCommandParams.parse(code: "valueIs(\"#v\", \"1\", timeout: 2, occlusionGuard: false)",
                                    verb: "valueIs"),
            ["timeout": "2", "occlusionGuard": "false"])
    }

    func testParseFillsOmittedArgumentsWithDefaults() {
        XCTAssertEqual(StepCommandParams.parse(code: "exist(\"WiFi\")", verb: "exist"),
                       ["timeout": ""])
        XCTAssertEqual(StepCommandParams.parse(code: "scrollTo(\"x\")", verb: "scrollTo"),
                       ["direction": "up", "maxSwipes": "8"])
        XCTAssertEqual(StepCommandParams.parse(code: "type(\"a\", \"b\")", verb: "type"),
                       ["optional": "false", "timeout": ""])
    }

    func testParseEnumAndMultipleKeywords() {
        XCTAssertEqual(
            StepCommandParams.parse(code: "scrollTo(\"x\", direction: .down, maxSwipes: 3)",
                                    verb: "scrollTo"),
            ["direction": "down", "maxSwipes": "3"])
        XCTAssertEqual(
            StepCommandParams.parse(code: "press(\"x\", duration: 0.5, optional: true)",
                                    verb: "press"),
            ["duration": "0.5", "optional": "true", "timeout": ""])
    }

    func testParseFormatsIntegralDoubleWithoutDecimalPoint() {
        XCTAssertEqual(StepCommandParams.parse(code: "press(\"x\", duration: 2.0)",
                                               verb: "press"),
                       ["duration": "2", "optional": "false", "timeout": ""])
    }

    func testParseEmptySpecsVerbReturnsEmptyValues() {
        XCTAssertEqual(StepCommandParams.parse(code: "swipe(.up)", verb: "swipe"), [:])
    }

    func testParseTapIgnoresOptionalAndReturnsTimeoutDefault() {
        // tap の optional は specList に無いが、ソースに存在しても素通しする(落とし穴対応)
        XCTAssertEqual(StepCommandParams.parse(code: "tap(\"OK\", optional: true)", verb: "tap"),
                       ["timeout": ""])
    }

    func testParseTapWithOptionalAndTimeout() {
        XCTAssertEqual(
            StepCommandParams.parse(code: "tap(\"x\", optional: true, timeout: 0)", verb: "tap"),
            ["timeout": "0"])
    }

    func testParseActionTimeoutDefaultsAndExplicit() {
        XCTAssertEqual(StepCommandParams.parse(code: "tap(\"x\")", verb: "tap"),
                       ["timeout": ""])
        XCTAssertEqual(StepCommandParams.parse(code: "tap(\"x\", timeout: 3)", verb: "tap"),
                       ["timeout": "3"])
        XCTAssertEqual(StepCommandParams.parse(code: "type(\"a\", \"b\", timeout: 0)", verb: "type"),
                       ["optional": "false", "timeout": "0"])
        XCTAssertEqual(
            StepCommandParams.parse(code: "press(\"x\", duration: 0.5, timeout: 2)", verb: "press"),
            ["duration": "0.5", "optional": "false", "timeout": "2"])
    }

    func testParseKeepsEscapedLiteral() {
        XCTAssertEqual(StepCommandParams.parse(code: #"exist("a\"b", timeout: 5)"#,
                                               verb: "exist"),
                       ["timeout": "5"])
    }

    func testParseRejectsVariableArgument() {
        // 変数セレクタ = リテラル置換も値解釈もできない行(編集不可)
        XCTAssertNil(StepCommandParams.parse(code: "exist(sel, timeout: 15)", verb: "exist"))
    }

    func testParseRejectsExpressionValue() {
        XCTAssertNil(StepCommandParams.parse(code: "exist(\"x\", timeout: 5 + 1)",
                                             verb: "exist"))
        XCTAssertNil(StepCommandParams.parse(code: "exist(\"x\", timeout: limit)",
                                             verb: "exist"))
    }

    func testParseRejectsUnknownAndDuplicateLabels() {
        XCTAssertNil(StepCommandParams.parse(code: "exist(\"x\", foo: 1)", verb: "exist"))
        XCTAssertNil(StepCommandParams.parse(code: "exist(\"x\", timeout: 1, timeout: 2)",
                                             verb: "exist"))
    }

    func testParseRejectsBlockLine() {
        XCTAssertNil(StepCommandParams.parse(code: "procedure(\"t\") {", verb: "procedure"))
    }

    func testParseRejectsFuncNameMismatch() {
        XCTAssertNil(StepCommandParams.parse(code: "exist(\"x\")", verb: "tap"))
    }

    func testApplyAddsTimeout() throws {
        XCTAssertEqual(
            try StepCommandParams.apply(display: "exist \"WiFi\"", params: ["timeout": "15"],
                                        toCode: "exist(\"WiFi\")"),
            "exist(\"WiFi\", timeout: 15)")
    }

    func testApplyClearsTimeoutWithEmptyValue() throws {
        // 空文字 = 引数を省略する(プロファイル既定に戻す)
        XCTAssertEqual(
            try StepCommandParams.apply(display: "exist \"WiFi\"", params: ["timeout": ""],
                                        toCode: "exist(\"WiFi\", timeout: 15)"),
            "exist(\"WiFi\")")
    }

    func testApplyOmitsDefaultValues() throws {
        // 既定値と等しい引数は出力しない(direction: .up / maxSwipes: 8 は省略)
        XCTAssertEqual(
            try StepCommandParams.apply(display: "scrollTo \"x\"",
                                        params: ["direction": "up", "maxSwipes": "8"],
                                        toCode: "scrollTo(\"y\", direction: .up)"),
            "scrollTo(\"x\")")
        XCTAssertEqual(
            try StepCommandParams.apply(display: "scrollTo \"x\"",
                                        params: ["direction": "down", "maxSwipes": "3"],
                                        toCode: "scrollTo(\"x\")"),
            "scrollTo(\"x\", direction: .down, maxSwipes: 3)")
    }

    func testApplyRendersPressDurationAndOptional() throws {
        XCTAssertEqual(
            try StepCommandParams.apply(display: "press \"x\"",
                                        params: ["duration": "0.5", "optional": "true"],
                                        toCode: "press(\"x\")"),
            "press(\"x\", duration: 0.5, optional: true)")
        // 整数値の duration は小数点なし・既定値 1 は省略
        XCTAssertEqual(
            try StepCommandParams.apply(display: "press \"x\"",
                                        params: ["duration": "1.0", "optional": "false"],
                                        toCode: "press(\"x\", duration: 0.5)"),
            "press(\"x\")")
    }

    func testApplyRespectsOptionalSuffixInDisplay() throws {
        // display に手でサフィックスを書いた場合も尊重する(params が false でも付ける)
        XCTAssertEqual(
            try StepCommandParams.apply(display: "type \"欄\" \"値\" (optional)",
                                        params: ["optional": "false"],
                                        toCode: "type(\"欄\", \"旧\")"),
            "type(\"欄\", \"値\", optional: true)")
    }

    func testApplyRendersTypeFocusedElementForm() throws {
        // ロケータなしの type「フォーカス中要素へ入力」の optional 反映
        XCTAssertEqual(
            try StepCommandParams.apply(display: "type \"text\"", params: ["optional": "false"],
                                        toCode: "type(\"text\")"),
            "type(\"text\")")
        XCTAssertEqual(
            try StepCommandParams.apply(display: "type \"text\"", params: ["optional": "true"],
                                        toCode: "type(\"text\")"),
            "type(\"text\", optional: true)")
    }

    func testApplyRendersTapOptionalAndTimeout() throws {
        XCTAssertEqual(
            try StepCommandParams.apply(display: "tap \"x\" (optional)", params: ["timeout": "0"],
                                        toCode: "tap(\"y\")"),
            "tap(\"x\", optional: true, timeout: 0)")
        // 省略時(空文字)は出力しない
        XCTAssertEqual(
            try StepCommandParams.apply(display: "tap \"x\"", params: ["timeout": ""],
                                        toCode: "tap(\"x\", timeout: 5)"),
            "tap(\"x\")")
    }

    func testApplyRendersTypeAndPressTimeoutAfterOptional() throws {
        // シグネチャ順(optional → timeout)で出力される
        XCTAssertEqual(
            try StepCommandParams.apply(display: "type \"欄\" \"値\"",
                                        params: ["optional": "true", "timeout": "2"],
                                        toCode: "type(\"欄\", \"値\")"),
            "type(\"欄\", \"値\", optional: true, timeout: 2)")
        XCTAssertEqual(
            try StepCommandParams.apply(display: "press \"x\"",
                                        params: ["duration": "1", "optional": "true", "timeout": "0"],
                                        toCode: "press(\"x\")"),
            "press(\"x\", optional: true, timeout: 0)")
    }

    func testApplyRegeneratesOnVerbChangeWithParams() throws {
        XCTAssertEqual(
            try StepCommandParams.apply(display: "exist \"設定\"", params: ["timeout": "20"],
                                        toCode: "tap(\"設定\")"),
            "exist(\"設定\", timeout: 20)")
    }

    func testApplyEscapesSelector() throws {
        XCTAssertEqual(
            try StepCommandParams.apply(display: #"exist "引用"符""#,
                                        params: ["timeout": "15"],
                                        toCode: "exist(\"OK\")"),
            #"exist("引用\"符", timeout: 15)"#)
    }

    func testApplyWithNilParamsDelegatesToLiteralPatch() throws {
        // StepCommandText.apply のリテラル置換パス(書式・非表示引数を保存)と同一結果になる
        XCTAssertEqual(
            try StepCommandParams.apply(display: "exist \"Internet\"", params: nil,
                                        toCode: "exist(\"WiFi\", timeout: 15)"),
            try StepCommandText.apply(display: "exist \"Internet\"",
                                      toCode: "exist(\"WiFi\", timeout: 15)"))
        XCTAssertEqual(
            try StepCommandParams.apply(display: "exist \"Internet\"", params: nil,
                                        toCode: "exist(\"WiFi\", timeout: 15)"),
            "exist(\"Internet\", timeout: 15)")
    }

    func testApplyThrowsInvalidValue() {
        XCTAssertThrowsError(try StepCommandParams.apply(
            display: "scrollTo \"x\"", params: ["direction": "up", "maxSwipes": "abc"],
            toCode: "scrollTo(\"x\")")) { error in
            XCTAssertEqual(error as? StepCommandParamsError,
                           .invalidValue(label: "maxSwipes", reason: "整数で入力してください"))
        }
    }

    func testApplyThrowsInvalidValueForActionTimeout() {
        XCTAssertThrowsError(try StepCommandParams.apply(
            display: "tap \"x\"", params: ["timeout": "abc"], toCode: "tap(\"x\")")) { error in
            XCTAssertEqual(error as? StepCommandParamsError,
                           .invalidValue(label: "timeout", reason: "整数で入力してください"))
        }
    }

    func testApplyRejectsBlockLineWithParams() {
        XCTAssertThrowsError(try StepCommandParams.apply(
            display: "tap \"x\"", params: [:], toCode: "procedure(\"前準備\") {")) {
            XCTAssertEqual($0 as? StepCommandTextError, .blockCommand)
        }
    }

    func testApplyRejectsRawSwiftLineWithParams() {
        // 生 Swift(未知の関数)の行は表からは書き換えない
        XCTAssertThrowsError(try StepCommandParams.apply(
            display: "tap \"x\"", params: [:], toCode: "customHelper(\"x\")")) {
            XCTAssertEqual($0 as? StepCommandTextError, .sourceNotRewritable("customHelper"))
        }
    }

    // MARK: - StepCommandText の scrollTo バグ修正の確認

    func testStepCommandTextRejectsScrollToOptional() {
        // scrollTo に optional 引数は無い(受理するとコンパイル不能コードを生んでいた)
        XCTAssertNil(StepCommandText.parse("scrollTo \"x\" (optional)"))
        XCTAssertEqual(StepCommandText.parse("scrollTo \"x\""),
                       .init(verb: "scrollTo", strings: ["x"], optionalFlag: false, word: nil))
    }
}

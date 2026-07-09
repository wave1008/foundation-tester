// StepCommandParamsTests.swift
// 表示表現に現れないキーワード引数(timeout: / duration: / optional: / direction: /
// maxSwipes:)の構造化編集(スキーマ・現在値の取得・適用)のテスト

import XCTest
@testable import FTDSL

final class StepCommandParamsTests: XCTestCase {

    // MARK: - specs(スキーマ)

    func testSpecsForVerbs() {
        XCTAssertEqual(StepCommandParams.specs(forVerb: "exist").map(\.name), ["timeout"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "textIs").map(\.name), ["timeout"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "valueIs").map(\.name), ["timeout"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "scrollTo").map(\.name),
                       ["direction", "maxSwipes"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "press").map(\.name),
                       ["duration", "optional"])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "type").map(\.name), ["optional"])
    }

    func testSpecsEmptyForVerbsWithoutHiddenParams() {
        // tap の optional は表示表現のサフィックスで編集するためスキーマに含めない
        XCTAssertEqual(StepCommandParams.specs(forVerb: "tap"), [])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "swipe"), [])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "wait"), [])
        XCTAssertEqual(StepCommandParams.specs(forVerb: "procedure"), [])
    }

    // MARK: - parse(ソースからの現在値の取得)

    func testParseKeywordArgument() {
        XCTAssertEqual(StepCommandParams.parse(code: "exist(\"WiFi\", timeout: 15)",
                                               verb: "exist"),
                       ["timeout": "15"])
    }

    func testParseFillsOmittedArgumentsWithDefaults() {
        XCTAssertEqual(StepCommandParams.parse(code: "exist(\"WiFi\")", verb: "exist"),
                       ["timeout": ""])
        XCTAssertEqual(StepCommandParams.parse(code: "scrollTo(\"x\")", verb: "scrollTo"),
                       ["direction": "up", "maxSwipes": "8"])
        XCTAssertEqual(StepCommandParams.parse(code: "type(\"a\", \"b\")", verb: "type"),
                       ["optional": "false"])
    }

    func testParseEnumAndMultipleKeywords() {
        XCTAssertEqual(
            StepCommandParams.parse(code: "scrollTo(\"x\", direction: .down, maxSwipes: 3)",
                                    verb: "scrollTo"),
            ["direction": "down", "maxSwipes": "3"])
        XCTAssertEqual(
            StepCommandParams.parse(code: "press(\"x\", duration: 0.5, optional: true)",
                                    verb: "press"),
            ["duration": "0.5", "optional": "true"])
    }

    func testParseFormatsIntegralDoubleWithoutDecimalPoint() {
        XCTAssertEqual(StepCommandParams.parse(code: "press(\"x\", duration: 2.0)",
                                               verb: "press"),
                       ["duration": "2", "optional": "false"])
    }

    func testParseEmptySpecsVerbReturnsEmptyValues() {
        XCTAssertEqual(StepCommandParams.parse(code: "swipe(.up)", verb: "swipe"), [:])
        XCTAssertEqual(StepCommandParams.parse(code: "tap(\"OK\", optional: true)",
                                               verb: "tap"),
                       [:])
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

    // MARK: - apply(再生成)

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

    // MARK: - apply(params nil = StepCommandText.apply への委譲)

    func testApplyWithNilParamsDelegatesToLiteralPatch() throws {
        // 従来のリテラル置換パス(書式・非表示引数を保存)と同一結果になる
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

    // MARK: - apply(エラー)

    func testApplyThrowsInvalidValue() {
        XCTAssertThrowsError(try StepCommandParams.apply(
            display: "scrollTo \"x\"", params: ["direction": "up", "maxSwipes": "abc"],
            toCode: "scrollTo(\"x\")")) { error in
            XCTAssertEqual(error as? StepCommandParamsError,
                           .invalidValue(label: "maxSwipes", reason: "整数で入力してください"))
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

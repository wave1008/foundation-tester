// StepCommandTextTests.swift
// コマンド列の表示表現 ↔ ソースコードの変換(セル内インライン編集)のテスト

import XCTest
@testable import FTDSL

final class StepCommandTextTests: XCTestCase {

    // MARK: - parse(表示表現の解釈)

    func testParseSingleStringVerbs() {
        XCTAssertEqual(StepCommandText.parse("tap \"ログイン\""),
                       .init(verb: "tap", strings: ["ログイン"], optionalFlag: false, word: nil))
        XCTAssertEqual(StepCommandText.parse("exist \"#id||ラベル\""),
                       .init(verb: "exist", strings: ["#id||ラベル"],
                             optionalFlag: false, word: nil))
        XCTAssertEqual(StepCommandText.parse("procedure \"前準備\""),
                       .init(verb: "procedure", strings: ["前準備"],
                             optionalFlag: false, word: nil))
    }

    func testParseOptionalSuffix() {
        XCTAssertEqual(StepCommandText.parse("tap \"今はしない\" (optional)"),
                       .init(verb: "tap", strings: ["今はしない"],
                             optionalFlag: true, word: nil))
        // 表示に optional が出ない検証コマンドには付けられない
        XCTAssertNil(StepCommandText.parse("exist \"x\" (optional)"))
    }

    func testParseTwoStringVerbs() {
        XCTAssertEqual(StepCommandText.parse("type \"メール\" \"a@example.com\""),
                       .init(verb: "type", strings: ["メール", "a@example.com"],
                             optionalFlag: false, word: nil))
        XCTAssertEqual(StepCommandText.parse("textIs \"#title\" == \"ようこそ\""),
                       .init(verb: "textIs", strings: ["#title", "ようこそ"],
                             optionalFlag: false, word: nil))
    }

    func testParseWordVerbs() {
        XCTAssertEqual(StepCommandText.parse("swipe up"),
                       .init(verb: "swipe", strings: [], optionalFlag: false, word: "up"))
        XCTAssertNil(StepCommandText.parse("swipe diagonal"))
        XCTAssertEqual(StepCommandText.parse("wait 2.0s"),
                       .init(verb: "wait", strings: [], optionalFlag: false, word: "2"))
        XCTAssertEqual(StepCommandText.parse("wait 0.5"),
                       .init(verb: "wait", strings: [], optionalFlag: false, word: "0.5"))
        XCTAssertEqual(StepCommandText.parse("launch com.android.settings"),
                       .init(verb: "launch", strings: ["com.android.settings"],
                             optionalFlag: false, word: nil))
        XCTAssertEqual(StepCommandText.parse("terminate"),
                       .init(verb: "terminate", strings: [], optionalFlag: false, word: nil))
    }

    func testParseRejectsUnknownAndRuntimeOnlyForms() {
        XCTAssertNil(StepCommandText.parse("ifCanSelect \"x\" → 実行"))
        XCTAssertNil(StepCommandText.parse("scene 1 本体をスキップ"))
        XCTAssertNil(StepCommandText.parse("tap ラベル"))  // クォート無し
        XCTAssertNil(StepCommandText.parse(""))
    }

    // MARK: - apply: 文字列リテラルだけの置換(その他の引数を保存)

    func testApplyPatchesSelectorKeepingOtherArguments() throws {
        XCTAssertEqual(
            try StepCommandText.apply(display: "exist \"Internet\"",
                                      toCode: "exist(\"WiFi\", timeout: 15)"),
            "exist(\"Internet\", timeout: 15)")
        XCTAssertEqual(
            try StepCommandText.apply(display: "tap \"はい\" (optional)",
                                      toCode: "tap(\"OK\", optional: true)"),
            "tap(\"はい\", optional: true)")
        XCTAssertEqual(
            try StepCommandText.apply(display: "type \"メール\" \"b@example.com\"",
                                      toCode: "type(\"メール\", \"a@example.com\", optional: true)"),
            "type(\"メール\", \"b@example.com\", optional: true)")
    }

    func testApplyPatchesProcedureTitleKeepingBlock() throws {
        XCTAssertEqual(
            try StepCommandText.apply(display: "procedure \"後始末\"",
                                      toCode: "procedure(\"前準備\") {"),
            "procedure(\"後始末\") {")
    }

    func testApplyPatchEscapesQuotes() throws {
        XCTAssertEqual(
            try StepCommandText.apply(display: #"tap "引用"符""#,
                                      toCode: "tap(\"OK\")"),
            #"tap("引用\"符")"#)
    }

    // MARK: - apply: 呼び出しの生成し直し(動詞・構成の変更)

    func testApplyRegeneratesOnVerbChange() throws {
        XCTAssertEqual(
            try StepCommandText.apply(display: "exist \"設定\"",
                                      toCode: "tap(\"設定\")"),
            "exist(\"設定\")")
        XCTAssertEqual(
            try StepCommandText.apply(display: "swipe down",
                                      toCode: "tap(\"設定\")"),
            "swipe(.down)")
        XCTAssertEqual(
            try StepCommandText.apply(display: "wait 3s", toCode: "wait(1)"),
            "wait(3)")
        XCTAssertEqual(
            try StepCommandText.apply(display: "launch com.example.app",
                                      toCode: "launchApp()"),
            "launchApp(\"com.example.app\")")
        XCTAssertEqual(
            try StepCommandText.apply(display: "terminate", toCode: "wait(1)"),
            "terminateApp()")
    }

    func testApplyRegeneratesOnTapOptionalChange() throws {
        // optional の付け外し(tap は表示に現れるため差分 = 意思表示)
        XCTAssertEqual(
            try StepCommandText.apply(display: "tap \"OK\" (optional)",
                                      toCode: "tap(\"OK\")"),
            "tap(\"OK\", optional: true)")
        XCTAssertEqual(
            try StepCommandText.apply(display: "tap \"OK\"",
                                      toCode: "tap(\"OK\", optional: true)"),
            "tap(\"OK\")")
    }

    func testApplyKeepsHiddenOptionalOnNonTapVerbs() throws {
        // type は表示に optional が出ない = サフィックス無しの編集で消してはいけない
        XCTAssertEqual(
            try StepCommandText.apply(display: "type \"欄\" \"新値\"",
                                      toCode: "type(\"欄\", \"旧値\", optional: true)"),
            "type(\"欄\", \"新値\", optional: true)")
    }

    // MARK: - apply: エラー

    func testApplyRejectsUnrecognizedDisplay() {
        XCTAssertThrowsError(try StepCommandText.apply(display: "なにか",
                                                       toCode: "tap(\"x\")")) { error in
            XCTAssertEqual(error as? StepCommandTextError, .unrecognized)
        }
    }

    func testApplyRejectsVerbChangeOnBlockLine() {
        XCTAssertThrowsError(try StepCommandText.apply(display: "tap \"x\"",
                                                       toCode: "procedure(\"前準備\") {")) {
            XCTAssertEqual($0 as? StepCommandTextError, .blockCommand)
        }
    }

    func testApplyRejectsUnknownSourceCall() {
        // 生 Swift(未知の関数)の行は表からは書き換えない
        XCTAssertThrowsError(try StepCommandText.apply(
            display: "tap \"x\"", toCode: "customHelper(\"x\")")) {
            XCTAssertEqual($0 as? StepCommandTextError, .sourceNotRewritable("customHelper"))
        }
    }
}

import XCTest
@testable import FTDSL

final class StepCommandTextTests: XCTestCase {

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

    func testParseTypeSingleStringForm() {
        // ロケータなしの type "text"(フォーカス中要素へ入力)
        XCTAssertEqual(StepCommandText.parse("type \"あいう\""),
                       .init(verb: "type", strings: ["あいう"], optionalFlag: false, word: nil))
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
        XCTAssertEqual(StepCommandText.parse("pressEnter"),
                       .init(verb: "pressEnter", strings: [], optionalFlag: false, word: nil))
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

    func testApplyPatchesTypeSingleStringForm() throws {
        // ロケータなしの type「フォーカス中要素へ入力」の文字列リテラル置換
        XCTAssertEqual(
            try StepCommandText.apply(display: "type \"新値\"", toCode: "type(\"旧値\")"),
            "type(\"新値\")")
    }

    func testApplyRegeneratesFromTwoArgToOneArgType() throws {
        // 二引数(セレクタ指定)→一引数(フォーカス中要素)への変更は呼び出し全体を生成し直す
        XCTAssertEqual(
            try StepCommandText.apply(display: "type \"text\"",
                                      toCode: "type(\"#email\", \"old\")"),
            "type(\"text\")")
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
        XCTAssertEqual(
            try StepCommandText.apply(display: "pressEnter", toCode: "wait(1)"),
            "pressEnter()")
    }

    /// "pressEnter" がソース側の動詞としても編集可能集合(renewableFuncs)に入っていること
    /// (入っていなければ sourceNotRewritable を投げる)
    func testApplyRegeneratesFromPressEnterSourceLine() throws {
        XCTAssertEqual(
            try StepCommandText.apply(display: "terminate", toCode: "pressEnter()"),
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
    func testParseNewAssertVerbs() {
        XCTAssertEqual(StepCommandText.parse("notExist \"#dialog\""),
                       .init(verb: "notExist", strings: ["#dialog"], optionalFlag: false, word: nil))
        XCTAssertEqual(StepCommandText.parse("isEnabled \"#send\""),
                       .init(verb: "isEnabled", strings: ["#send"], optionalFlag: false, word: nil))
        XCTAssertEqual(StepCommandText.parse("isDisabled \"#send\""),
                       .init(verb: "isDisabled", strings: ["#send"], optionalFlag: false, word: nil))
        XCTAssertEqual(StepCommandText.parse("countIs \"#list >> .Cell\" == 3"),
                       .init(verb: "countIs", strings: ["#list >> .Cell"],
                             optionalFlag: false, word: "3"))
        // 期待値が整数でない countIs は解釈しない(編集不可のまま扱う)
        XCTAssertNil(StepCommandText.parse("countIs \"#list\" == 三"))
    }

    func testGroupPrefixIsStrippedForEditing() {
        // group("ログイン") { } 内のステップ表示("[ログイン] tap ...")も表から編集できる
        XCTAssertEqual(StepCommandText.parse("[ログイン] tap \"#login\""),
                       .init(verb: "tap", strings: ["#login"], optionalFlag: false, word: nil))
        XCTAssertEqual(StepCommandText.parse("[外/内] tap \"#login\" (optional)"),
                       .init(verb: "tap", strings: ["#login"], optionalFlag: true, word: nil))
    }

    func testApplyNewAssertVerbs() {
        XCTAssertEqual(try StepCommandText.apply(display: "notExist \"#a\"",
                                                 toCode: "notExist(\"#b\", timeout: 2)"),
                       "notExist(\"#a\", timeout: 2)")
        // 動詞が変わる編集は呼び出しを作り直す
        XCTAssertEqual(try StepCommandText.apply(display: "countIs \"#list\" == 2",
                                                 toCode: "exist(\"#list\")"),
                       "countIs(\"#list\", 2)")
    }

    // MARK: - 対称化したアサーション・スクロール引数

    func testParsesNewTextAssertions() {
        XCTAssertEqual(StepCommandText.parse("textStartsWith \"#t\" ~ \"合計\"")?.strings,
                       ["#t", "合計"])
        XCTAssertEqual(StepCommandText.parse("textEndsWith \"#t\" ~ \"円\"")?.strings,
                       ["#t", "円"])
        XCTAssertEqual(StepCommandText.parse("textIsNot \"#t\" != \"処理中\"")?.strings,
                       ["#t", "処理中"])
        XCTAssertEqual(StepCommandText.parse("textIsEmpty \"#input\"")?.strings, ["#input"])
        XCTAssertEqual(StepCommandText.parse("textIsNotEmpty \"#input\"")?.strings, ["#input"])
    }

    func testRendersNewTextAssertionsWhenVerbChanges() throws {
        XCTAssertEqual(
            try StepCommandText.apply(display: "textStartsWith \"#t\" ~ \"合計\"",
                                      toCode: "textIs(\"#t\", \"合計 1,200円\")"),
            "textStartsWith(\"#t\", \"合計\")")
        XCTAssertEqual(
            try StepCommandText.apply(display: "textIsEmpty \"#input\"",
                                      toCode: "exist(\"#input\")"),
            "textIsEmpty(\"#input\")")
    }

    /// 表示に現れない `scroll:` は文字列リテラル置換の経路で保存される
    func testScrollArgumentIsPreservedOnLiteralEdit() throws {
        XCTAssertEqual(
            try StepCommandText.apply(display: "tap \"設定\"",
                                      toCode: "tap(\"表示\", scroll: .down)"),
            "tap(\"設定\", scroll: .down)")
    }

    /// `scroll:` は同じステップに畳んだので、表示は素の `tap "…"` のまま
    /// (合成ステップが無くなったため、探索用の特別な表示表現も無い)
    func testScrollSearchHasNoSyntheticStepDisplay() {
        XCTAssertEqual(StepCommandText.parse("tap \"設定\"")?.verb, "tap")
        XCTAssertNotNil(StepCommandText.parse("scrollTo \"設定\""))
    }

    // MARK: - Shirates 準拠で増えた動詞(2026-07-27)

    func testParsesValueAndNegativeAssertions() {
        XCTAssertEqual(StepCommandText.parse("valueContains \"#t\" ~ \"円\"")?.strings,
                       ["#t", "円"])
        XCTAssertEqual(StepCommandText.parse("textContainsNot \"#t\" != \"エラー\"")?.strings,
                       ["#t", "エラー"])
        XCTAssertEqual(StepCommandText.parse("valueIsNotEmpty \"#input\"")?.strings, ["#input"])
        XCTAssertEqual(
            StepCommandText.parse("textMatchesDateFormat \"#d\" ~ \"yyyy/MM/dd\"")?.strings,
            ["#d", "yyyy/MM/dd"])
        // 区切り記号が動詞と食い違う表示は解釈しない(== と != を取り違えない)
        XCTAssertNil(StepCommandText.parse("textIsNot \"#t\" == \"処理中\""))
    }

    func testRendersValueAndNegativeAssertions() throws {
        XCTAssertEqual(
            try StepCommandText.apply(display: "valueContainsNot \"#t\" != \"円\"",
                                      toCode: "valueIs(\"#t\", \"1,200円\")"),
            "valueContainsNot(\"#t\", \"円\")")
        XCTAssertEqual(
            try StepCommandText.apply(display: "valueIsEmpty \"#input\"",
                                      toCode: "exist(\"#input\")"),
            "valueIsEmpty(\"#input\")")
    }

    /// スクロールは引数なし(`scrollDown`)と回数つき(`scrollDown ×3`)の2表示
    func testParsesAndRendersScrollCommands() throws {
        XCTAssertEqual(StepCommandText.parse("scrollDown")?.verb, "scrollDown")
        XCTAssertEqual(StepCommandText.parse("scrollDown ×3")?.word, "3")
        XCTAssertEqual(StepCommandText.parse("scrollToBottom")?.verb, "scrollToBottom")
        // ×1 は表示に出ないので、表示としても受け付けない(往復で形が割れないように)
        XCTAssertNil(StepCommandText.parse("scrollDown ×1"))

        XCTAssertEqual(
            try StepCommandText.apply(display: "scrollUp ×2", toCode: "scrollDown()"),
            "scrollUp(repeat: 2)")
        XCTAssertEqual(
            try StepCommandText.apply(display: "scrollToTop", toCode: "scrollDown(repeat: 3)"),
            "scrollToTop()")
    }
}

import XCTest
@testable import FTCore

final class ScenarioSourceEditorTests: XCTestCase {

    /// explore/convert が生成する典型形(2 クラス、同名メソッド S0010 を両方に持つ)
    private let source = """
    import FTDSL

    @TestClass(app: "com.example.app", platform: "android")
    class ログインテスト {

        @Test("ログインとエラー表示")
        func S0010() {
            scenario {
                scene(1) {
                    condition {
                        launchApp()  // class 内コメント: func S9999() や class Dummy は拾わない
                    }
                }
            }
        }

        @Test
        func S0020() {
            scenario {}
        }
    }

    @TestClass(app: "com.example.app")
    class Network_internet_を開いて {

        @Deleted("旧仕様")
        @Test("「Network & internet」を開いて、「Internet」が表示されることを確認する")
        func S0010() {
            scenario {}
        }
    }
    """

    // MARK: - セレクタ置換(自己修復の確定反映)

    private let selectorSource = """
    import FTDSL

    @TestClass(app: "com.example.app")
    class ログインテスト {

        @Test("ログイン")
        func S0010() {
            scenario {
                scene(1) {
                    action {
                        tap("#login_btn||ログイン")
                    }.expectation {
                        exist("#welcome_text||ようこそ")
                    }
                }
            }
        }
    }
    """

    private func lineNumber(containing text: String, in source: String) -> Int {
        source.components(separatedBy: "\n").firstIndex(where: { $0.contains(text) })! + 1
    }

    func testReplaceSelectorSuccess() throws {
        let target = "#welcome_text||ようこそ"
        let line = lineNumber(containing: target, in: selectorSource)
        let result = try ScenarioSourceEditor.replaceSelector(
            inSource: selectorSource, line: line,
            oldSelector: target, newSelector: "#welcome_text2||ようこそ")
        XCTAssertTrue(result.contains("exist(\"#welcome_text2||ようこそ\")"))
        XCTAssertFalse(result.contains(target))
    }

    func testReplaceSelectorPreservesOtherLines() throws {
        let target = "#welcome_text||ようこそ"
        let line = lineNumber(containing: target, in: selectorSource)
        let result = try ScenarioSourceEditor.replaceSelector(
            inSource: selectorSource, line: line,
            oldSelector: target, newSelector: "#welcome_text2||ようこそ")
        let originalLines = selectorSource.components(separatedBy: "\n")
        let resultLines = result.components(separatedBy: "\n")
        XCTAssertEqual(resultLines.count, originalLines.count)
        for (index, original) in originalLines.enumerated() where index != line - 1 {
            XCTAssertEqual(resultLines[index], original, "行 \(index + 1) は変更されないはず")
        }
    }

    func testReplaceSelectorLineOutOfRange() {
        XCTAssertThrowsError(try ScenarioSourceEditor.replaceSelector(
            inSource: selectorSource, line: 9999,
            oldSelector: "#welcome_text||ようこそ", newSelector: "x"))
        XCTAssertThrowsError(try ScenarioSourceEditor.replaceSelector(
            inSource: selectorSource, line: 0,
            oldSelector: "#welcome_text||ようこそ", newSelector: "x"))
    }

    func testReplaceSelectorNotFound() {
        let line = lineNumber(containing: "#welcome_text||ようこそ", in: selectorSource)
        XCTAssertThrowsError(try ScenarioSourceEditor.replaceSelector(
            inSource: selectorSource, line: line,
            oldSelector: "#not_on_this_line", newSelector: "x"))
    }

    func testReplaceSelectorAmbiguousSameLineTwice() {
        let source = """
        import FTDSL
        let x = "#dup||同じ" + "#dup||同じ"
        """
        XCTAssertThrowsError(try ScenarioSourceEditor.replaceSelector(
            inSource: source, line: 2,
            oldSelector: "#dup||同じ", newSelector: "x"))
    }

    func testReplaceSelectorJapaneseSelector() throws {
        let target = "#login_btn||ログイン"
        let line = lineNumber(containing: target, in: selectorSource)
        let result = try ScenarioSourceEditor.replaceSelector(
            inSource: selectorSource, line: line,
            oldSelector: target, newSelector: "#login_btn||ログインする")
        XCTAssertTrue(result.contains("tap(\"#login_btn||ログインする\")"))
    }

    // MARK: - 行末コメントの書換(自己修復の説明見直し)

    private let commentSource = """
    import FTDSL

    @TestClass(app: "com.example.app")
    class 設定 {

        @Test
        func S0010() {
            scenario {
                scene(1) {
                    action {
                        tap("Network & internet")  // 「Network & internet」に移動する
                        tap("https://example.com//path")  // URL を開く
                        exist("#toolbar||設定")
                        tap("値//スラッシュ入り")//直後スペースなし
                    }
                }
            }
        }
    }
    """

    private let commandIndent = String(repeating: " ", count: 20)

    private func resultLine(_ result: String, _ line: Int) -> String {
        result.components(separatedBy: "\n")[line - 1]
    }

    func testSetTrailingCommentReplaces() throws {
        let line = lineNumber(containing: "Network & internet\")", in: commentSource)
        let result = try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: line,
            comment: "「ネットワークとインターネット」に移動する")
        // 「//」前の空白 2 個と「// 」のスペースが保存され、本文だけ置換される
        XCTAssertEqual(resultLine(result, line),
                       commandIndent + "tap(\"Network & internet\")  "
                       + "// 「ネットワークとインターネット」に移動する")
    }

    func testSetTrailingCommentDeletesWithEmptyString() throws {
        let line = lineNumber(containing: "Network & internet\")", in: commentSource)
        let result = try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: line, comment: "")
        // コメントと前の空白ごと削除され、行末に余分な空白が残らない
        XCTAssertEqual(resultLine(result, line),
                       commandIndent + "tap(\"Network & internet\")")
    }

    func testSetTrailingCommentIgnoresSlashesInsideString() throws {
        let line = lineNumber(containing: "https://example.com//path", in: commentSource)
        let result = try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: line, comment: "新しい説明")
        // 文字列リテラル内の // は誤認せず、行末コメントだけが書き換わる
        XCTAssertEqual(resultLine(result, line),
                       commandIndent + "tap(\"https://example.com//path\")  // 新しい説明")
    }

    func testSetTrailingCommentPreservesNoSpaceAfterSlashes() throws {
        let line = lineNumber(containing: "直後スペースなし", in: commentSource)
        let result = try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: line, comment: "X")
        // 「//」直後にスペースの無い元の形を保つ(文字列内の // も誤認しない)
        XCTAssertEqual(resultLine(result, line),
                       commandIndent + "tap(\"値//スラッシュ入り\")//X")
    }

    func testSetTrailingCommentAppendsWhenNoComment() throws {
        let line = lineNumber(containing: "#toolbar||設定", in: commentSource)
        let result = try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: line, comment: "「設定」が表示されること")
        // コメントの無い行にはスペース 2 個 + // で追記する(既存生成コードの慣習)
        XCTAssertEqual(resultLine(result, line),
                       commandIndent + "exist(\"#toolbar||設定\")  // 「設定」が表示されること")
    }

    func testSetTrailingCommentNoCommentEmptyIsNoOp() throws {
        let line = lineNumber(containing: "#toolbar||設定", in: commentSource)
        let result = try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: line, comment: "")
        XCTAssertEqual(result, commentSource)
    }

    func testSetTrailingCommentLineOutOfRange() {
        XCTAssertThrowsError(try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: 9999, comment: "説明"))
        XCTAssertThrowsError(try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: 0, comment: "説明"))
    }

    func testSetTrailingCommentRejectsMultiline() {
        let line = lineNumber(containing: "Network & internet\")", in: commentSource)
        XCTAssertThrowsError(try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: line, comment: "a\nb"))
    }

    func testSetTrailingCommentOtherLinesUnchanged() throws {
        let line = lineNumber(containing: "Network & internet\")", in: commentSource)
        let result = try ScenarioSourceEditor.setTrailingComment(
            inSource: commentSource, line: line, comment: "変更後の説明")
        let originalLines = commentSource.components(separatedBy: "\n")
        let resultLines = result.components(separatedBy: "\n")
        XCTAssertEqual(resultLines.count, originalLines.count)
        for (index, original) in originalLines.enumerated() where index != line - 1 {
            XCTAssertEqual(resultLines[index], original, "行 \(index + 1) は変更されないはず")
        }
    }

    // MARK: - removeMethod(TEST EXPLORER の関数削除。ファイルは残す)

    func testRemoveMethodKeepsSiblingAndOtherClass() throws {
        let result = try ScenarioSourceEditor.removeMethod(
            inSource: source, className: "ログインテスト", method: "S0020")
        XCTAssertFalse(result.contains("func S0020"))
        XCTAssertFalse(result.contains("@Test\n"))  // S0020 の裸 @Test 属性も除去
        // 残すメソッドと本体は保持
        XCTAssertTrue(result.contains("func S0010() {"))
        XCTAssertTrue(result.contains(#"@Test("ログインとエラー表示")"#))
        // クラス宣言・別クラスは無関係
        XCTAssertTrue(result.contains("class ログインテスト {"))
        XCTAssertTrue(result.contains("class Network_internet_を開いて {"))
        // ログインテスト側の S0010 だけ残り、別クラスの S0010 も残る(func S0010 は2箇所)
        XCTAssertEqual(result.components(separatedBy: "func S0010").count - 1, 2)
    }

    func testRemoveMethodStripsMultipleAttributeLines() throws {
        // @Deleted + @Test の複数属性行をまとめて除去する
        let result = try ScenarioSourceEditor.removeMethod(
            inSource: source, className: "Network_internet_を開いて", method: "S0010")
        XCTAssertFalse(result.contains("@Deleted(\"旧仕様\")"))
        XCTAssertFalse(result.contains("「Network & internet」を開いて"))
        // このクラスの S0010 は消え、ログインテスト側の S0010 は残る
        XCTAssertEqual(result.components(separatedBy: "func S0010").count - 1, 1)
        // 唯一のメソッドを消してもクラス宣言は残す(関数削除はファイル/クラスを消さない)
        XCTAssertTrue(result.contains("class Network_internet_を開いて {"))
    }

    func testRemoveMethodNotFound() {
        XCTAssertThrowsError(try ScenarioSourceEditor.removeMethod(
            inSource: source, className: "ログインテスト", method: "S9999"))
    }

    // MARK: - isTestClass(空クラスをツリーに残す判定)

    func testIsTestClass() {
        XCTAssertTrue(ScenarioSourceEditor.isTestClass(inSource: source, className: "ログインテスト"))
        XCTAssertTrue(ScenarioSourceEditor.isTestClass(
            inSource: source, className: "Network_internet_を開いて"))
        XCTAssertFalse(ScenarioSourceEditor.isTestClass(inSource: source, className: "存在しない"))
        // @TestClass の無い素の class は false
        XCTAssertFalse(ScenarioSourceEditor.isTestClass(
            inSource: "class ただのクラス {\n}\n", className: "ただのクラス"))
        // メソッドが無い空クラスでも @TestClass があれば true(本機能の対象)
        XCTAssertTrue(ScenarioSourceEditor.isTestClass(
            inSource: "@TestClass(app: \"a\")\nclass 空 {\n\n}\n", className: "空"))
    }
}

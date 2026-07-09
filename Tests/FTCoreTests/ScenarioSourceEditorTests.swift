// ScenarioSourceEditorTests.swift

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

    // MARK: - クラス名

    func testRenameClass() throws {
        let result = try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "ログインテスト2")
        XCTAssertTrue(result.contains("class ログインテスト2 {"))
        XCTAssertFalse(result.contains("class ログインテスト {"))
        // もう一方のクラスは無関係
        XCTAssertTrue(result.contains("class Network_internet_を開いて {"))
    }

    func testRenameClassNotFound() {
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "存在しない", to: "X"))
    }

    func testRenameClassDuplicateInFile() {
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "Network_internet_を開いて"))
    }

    func testRenameClassRejectsInvalidIdentifier() {
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "1abc"))
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "a b"))
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "class"))
    }

    // MARK: - 関数名

    func testRenameMethodScopedToClass() throws {
        // 両クラスに S0010 がある: 2 番目のクラスの方だけを変更する
        let result = try ScenarioSourceEditor.renameMethod(
            inSource: source, className: "Network_internet_を開いて",
            from: "S0010", to: "S0015")
        let first = result.range(of: "class ログインテスト")!
        let second = result.range(of: "class Network_internet_を開いて")!
        let firstBody = result[first.upperBound..<second.lowerBound]
        let secondBody = result[second.upperBound...]
        XCTAssertTrue(firstBody.contains("func S0010()"))  // 1 番目は無傷
        XCTAssertTrue(secondBody.contains("func S0015()"))
        XCTAssertFalse(secondBody.contains("func S0010()"))
    }

    func testRenameMethodDuplicateInClass() {
        XCTAssertThrowsError(try ScenarioSourceEditor.renameMethod(
            inSource: source, className: "ログインテスト", from: "S0010", to: "S0020"))
    }

    func testRenameMethodPrefixIsNotMatched() throws {
        // S0010 のリネームで S0010x のような前方一致を巻き込まない(完全一致のみ)
        let src = source.replacingOccurrences(of: "func S0020", with: "func S0010x")
        let result = try ScenarioSourceEditor.renameMethod(
            inSource: src, className: "ログインテスト", from: "S0010", to: "S0099")
        XCTAssertTrue(result.contains("func S0099()"))
        XCTAssertTrue(result.contains("func S0010x()"))
    }

    // MARK: - @Test の説明

    func testSetTestTitle() throws {
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0010",
            title: "新しい説明")
        XCTAssertTrue(result.contains("@Test(\"新しい説明\")"))
        XCTAssertFalse(result.contains("@Test(\"ログインとエラー表示\")"))
        // 他メソッド・他クラスの @Test は無傷
        XCTAssertTrue(result.contains(
            "@Test(\"「Network & internet」を開いて、「Internet」が表示されることを確認する\")"))
    }

    func testSetTestTitleOnBareTestAttribute() throws {
        // 引数なしの @Test にも説明を付けられる
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0020",
            title: "追加した説明")
        XCTAssertTrue(result.contains("@Test(\"追加した説明\")\n    func S0020()"))
    }

    func testSetTestTitleToEmptyProducesBareAttribute() throws {
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0010", title: "")
        XCTAssertTrue(result.contains("@Test\n    func S0010()"))
    }

    func testSetTestTitleEscapesQuotesAndBackslash() throws {
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0010",
            title: #"引用"符と\記号"#)
        XCTAssertTrue(result.contains(#"@Test("引用\"符と\\記号")"#))
    }

    func testSetTestTitleWithDeletedBetweenAttributeAndFunc() throws {
        // @Deleted が @Test と func の間ではなく前段にあっても、直近の @Test を書き換える
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "Network_internet_を開いて", method: "S0010",
            title: "変更後")
        XCTAssertTrue(result.contains("@Deleted(\"旧仕様\")\n    @Test(\"変更後\")"))
    }

    func testSetTestTitleRejectsMultiline() {
        XCTAssertThrowsError(try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0010",
            title: "a\nb"))
    }

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
        // コメントの無い行に空文字 = 変更なし(エラーにしない)
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

    // MARK: - コマンド行の書換(ステップ表のダブルクリック編集)

    func testCommandCodeExtractsWithoutIndentAndComment() throws {
        let line = lineNumber(containing: "Network & internet\")", in: commentSource)
        XCTAssertEqual(
            try ScenarioSourceEditor.commandCode(inSource: commentSource, line: line),
            "tap(\"Network & internet\")")
    }

    func testCommandCodeIgnoresSlashesInsideString() throws {
        let line = lineNumber(containing: "https://example.com//path", in: commentSource)
        XCTAssertEqual(
            try ScenarioSourceEditor.commandCode(inSource: commentSource, line: line),
            "tap(\"https://example.com//path\")")
    }

    func testCommandCodeErrorsOnBlankAndCommentOnlyLine() {
        let source = "tap(\"a\")\n\n    // コメントだけ"
        XCTAssertThrowsError(try ScenarioSourceEditor.commandCode(inSource: source, line: 2))
        XCTAssertThrowsError(try ScenarioSourceEditor.commandCode(inSource: source, line: 3))
        XCTAssertThrowsError(try ScenarioSourceEditor.commandCode(inSource: source, line: 99))
    }

    func testSetCommandCodePreservesIndentAndComment() throws {
        let line = lineNumber(containing: "Network & internet\")", in: commentSource)
        let result = try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: "tap(\"ネットワークとインターネット\")")
        XCTAssertEqual(resultLine(result, line),
                       commandIndent + "tap(\"ネットワークとインターネット\")  "
                       + "// 「Network & internet」に移動する")
    }

    func testSetCommandCodeOnLineWithoutComment() throws {
        let line = lineNumber(containing: "#toolbar||設定", in: commentSource)
        let result = try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: "exist(\"#toolbar||設定\", timeout: 5)")
        XCTAssertEqual(resultLine(result, line),
                       commandIndent + "exist(\"#toolbar||設定\", timeout: 5)")
    }

    func testSetCommandCodeTrimsInputWhitespace() throws {
        let line = lineNumber(containing: "#toolbar||設定", in: commentSource)
        let result = try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: "  wait(2)  ")
        XCTAssertEqual(resultLine(result, line), commandIndent + "wait(2)")
    }

    func testSetCommandCodeAllowsSlashesInsideString() throws {
        let line = lineNumber(containing: "#toolbar||設定", in: commentSource)
        let result = try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: "tap(\"https://example.com//x\")")
        XCTAssertEqual(resultLine(result, line),
                       commandIndent + "tap(\"https://example.com//x\")")
    }

    func testSetCommandCodeRejectsInvalidInput() {
        let line = lineNumber(containing: "#toolbar||設定", in: commentSource)
        // 空・空白のみ・複数行・// コメント入りは拒否
        XCTAssertThrowsError(try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: ""))
        XCTAssertThrowsError(try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: "   "))
        XCTAssertThrowsError(try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: "tap(\"a\")\ntap(\"b\")"))
        XCTAssertThrowsError(try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: "tap(\"a\")  // 説明"))
    }

    func testSetCommandCodeErrorsOnCommentOnlyLineAndOutOfRange() {
        let source = "tap(\"a\")\n    // コメントだけ"
        XCTAssertThrowsError(try ScenarioSourceEditor.setCommandCode(
            inSource: source, line: 2, code: "tap(\"b\")"))
        XCTAssertThrowsError(try ScenarioSourceEditor.setCommandCode(
            inSource: source, line: 0, code: "tap(\"b\")"))
        XCTAssertThrowsError(try ScenarioSourceEditor.setCommandCode(
            inSource: source, line: 99, code: "tap(\"b\")"))
    }

    func testSetCommandCodeOtherLinesUnchanged() throws {
        let line = lineNumber(containing: "Network & internet\")", in: commentSource)
        let result = try ScenarioSourceEditor.setCommandCode(
            inSource: commentSource, line: line, code: "wait(1)")
        let originalLines = commentSource.components(separatedBy: "\n")
        let resultLines = result.components(separatedBy: "\n")
        XCTAssertEqual(resultLines.count, originalLines.count)
        for (index, original) in originalLines.enumerated() where index != line - 1 {
            XCTAssertEqual(resultLines[index], original, "行 \(index + 1) は変更されないはず")
        }
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
}

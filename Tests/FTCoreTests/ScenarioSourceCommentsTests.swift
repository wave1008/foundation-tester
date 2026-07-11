import XCTest
@testable import FTCore

final class ScenarioSourceCommentsTests: XCTestCase {

    // MARK: - trailingComment(inLine:)

    func testBasicComment() {
        XCTAssertEqual(
            ScenarioSourceComments.trailingComment(
                inLine: "    tap(\"#login_btn||ログイン||.Button\")  // ログインボタンをタップする"),
            "ログインボタンをタップする")
    }

    func testNoComment() {
        XCTAssertNil(ScenarioSourceComments.trailingComment(
            inLine: "    type(\"#email||.TextField\", \"test@example.com\")"))
    }

    func testSlashesInsideStringIgnored() {
        XCTAssertNil(ScenarioSourceComments.trailingComment(
            inLine: "    launchApp(\"https://example.com//path\")"))
    }

    func testCommentAfterStringContainingSlashes() {
        XCTAssertEqual(
            ScenarioSourceComments.trailingComment(
                inLine: "    type(\"#url\", \"scheme://x\")  // URL を入力する"),
            "URL を入力する")
    }

    func testEscapedQuoteInsideString() {
        // \" は文字列を閉じない(エスケープ)ため後続の // もコメントにならない
        XCTAssertNil(ScenarioSourceComments.trailingComment(
            inLine: "    type(\"#memo\", \"say \\\"//not comment\\\"\")"))
    }

    func testEmptyCommentIsNil() {
        XCTAssertNil(ScenarioSourceComments.trailingComment(inLine: "    tap(\"#x\") //"))
        XCTAssertNil(ScenarioSourceComments.trailingComment(inLine: "    tap(\"#x\") //   "))
    }

    func testNoSpaceBeforeComment() {
        XCTAssertEqual(
            ScenarioSourceComments.trailingComment(inLine: "tap(\"#x\")//コメント"),
            "コメント")
    }

    func testCommentOnlyLine() {
        XCTAssertEqual(
            ScenarioSourceComments.trailingComment(inLine: "    // 行全体がコメント"),
            "行全体がコメント")
    }

    // MARK: - trailingComments(inSource:lines:)

    func testCommentsBySourceLines() {
        let source = """
        import FTDSL

        type("#email", "a@b.c")  // メールアドレスを入力
        tap("#login_btn")
        exist("#welcome")  // ようこそ表示を確認
        """
        let comments = ScenarioSourceComments.trailingComments(
            inSource: source, lines: [3, 4, 5, 99])
        XCTAssertEqual(comments, [3: "メールアドレスを入力", 5: "ようこそ表示を確認"])
    }

    func testCommentsWithEmptyLineSet() {
        XCTAssertEqual(
            ScenarioSourceComments.trailingComments(inSource: "// x", lines: []), [:])
    }
}

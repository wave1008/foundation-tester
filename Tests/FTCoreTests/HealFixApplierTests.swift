import XCTest
@testable import FTCore

final class HealFixApplierTests: XCTestCase {

    private let source = """
    import FTDSL

    @TestClass(app: "com.example.app", platform: "ios")
    class ログインテスト {

        @Test("ログイン")
        func S0010() {
            scenario {
                scene(1) {
                    condition {
                        launchApp()
                    }
                    action {
                        tap("#old_login_btn")  // ログインボタンをタップ
                        tap("#old_submit_btn")
                    }
                }
            }
        }
    }
    """

    private func fix(line: Int, old: String, new: String,
                     newComment: String? = nil, scenarioID: String = "ログインテスト.S0010",
                     file: String = "scenarios/Login.swift") -> HealFixInput {
        HealFixInput(scenarioID: scenarioID, file: file, line: line,
                    oldSelector: old, newSelector: new, newComment: newComment)
    }

    func testApplySuccess() {
        let fixes = [fix(line: 14, old: "#old_login_btn", new: "#new_login_btn")]
        let result = HealFixApplier.apply(fixes: fixes, toSource: source)

        XCTAssertTrue(result.source.contains("\"#new_login_btn\""))
        XCTAssertFalse(result.source.contains("\"#old_login_btn\""))
        XCTAssertEqual(result.applied.map(\.id), fixes.map(\.id))
        XCTAssertTrue(result.failures.isEmpty)
    }

    /// **利用者の .swift へ不正な Swift を書き込まない**。ここは
    /// `ftester api apply-heal` が**利用者のファイルを直接書き換える唯一の経路**で、
    /// 素の `"\(selector)"` で綴っていた版は `"` を含むラベルで
    /// `tap("*【速報】"特価"セール*")` を書き、**プロジェクトがコンパイルできなくなる**。
    ///
    /// 40字超のラベルに `*断片*` を勧めるようになって露出が広がった ——
    /// 長いラベルは宣伝文・見出しなので、短いボタン名より引用符を含みやすい
    func testQuotedSelectorIsWrittenAsAValidSwiftLiteral() {
        let new = "*【速報】\"特価\"セール開催中*"
        let result = HealFixApplier.apply(fixes: [fix(line: 14, old: "#old_login_btn", new: new)],
                                          toSource: source)

        XCTAssertEqual(result.failures, [])
        XCTAssertTrue(result.source.contains(#"tap("*【速報】\"特価\"セール開催中*")"#),
                      "エスケープせずに書いている: \(result.source)")
        // **リテラルの体を成しているか**を綴りではなく数で見る(行のクォートは開き閉じの2つだけ)
        let line = result.source.components(separatedBy: "\n")[13]
        let bare = line.replacingOccurrences(of: #"\""#, with: "")
        XCTAssertEqual(bare.filter { $0 == "\"" }.count, 2,
                       "エスケープされていないクォートが残っている: \(line)")
    }

    /// バックスラッシュも同じ(片方だけ直すと `\` で壊れる)
    func testBackslashInSelectorIsEscapedToo() {
        let result = HealFixApplier.apply(
            fixes: [fix(line: 14, old: "#old_login_btn", new: #"*C:\path*"#)], toSource: source)

        XCTAssertTrue(result.source.contains(#"tap("*C:\\path*")"#), result.source)
    }

    /// **探索側も同じ綴りにする**: 正しくエスケープして書かれている行を「見つからない」と
    /// 誤判定すると、修復が黙って落ちる(素の綴りだった頃から在った穴)
    func testFindsAnAlreadyEscapedSelectorInTheSource() {
        let escapedSource = source.replacingOccurrences(
            of: ##"tap("#old_login_btn")"##, with: ##"tap("*\"特価\"セール*")"##)

        let result = HealFixApplier.apply(
            fixes: [fix(line: 14, old: "*\"特価\"セール*", new: "#new_sale_btn")],
            toSource: escapedSource)

        XCTAssertEqual(result.failures, [])
        XCTAssertTrue(result.source.contains(##"tap("#new_sale_btn")"##), result.source)
    }

    func testApplyOldSelectorMismatch() {
        let fixes = [fix(line: 14, old: "#does_not_exist", new: "#new_login_btn")]
        let result = HealFixApplier.apply(fixes: fixes, toSource: source)

        XCTAssertEqual(result.source, source, "失敗時はソースを変更しない")
        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.id, fixes[0].id)
    }

    func testApplyCommentRemoval() {
        let fixes = [fix(line: 14, old: "#old_login_btn", new: "#new_login_btn", newComment: "")]
        let result = HealFixApplier.apply(fixes: fixes, toSource: source)

        XCTAssertTrue(result.source.contains("\"#new_login_btn\")\n"),
                      "コメントが削除され行末がそのまま改行になっていること")
        XCTAssertFalse(result.source.contains("// ログインボタンをタップ"))
        XCTAssertEqual(result.applied.map(\.id), fixes.map(\.id))
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testApplyCommentAddition() {
        let fixes = [fix(line: 15, old: "#old_submit_btn", new: "#new_submit_btn",
                         newComment: "送信ボタンをタップ")]
        let result = HealFixApplier.apply(fixes: fixes, toSource: source)

        XCTAssertTrue(result.source.contains(
            "tap(\"#new_submit_btn\")  // 送信ボタンをタップ"))
        XCTAssertEqual(result.applied.map(\.id), fixes.map(\.id))
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testApplyCommentUpdateFailureKeepsSelectorReplacement() {
        // setTrailingComment は複数行の comment を invalidName エラーにする
        let fixes = [fix(line: 14, old: "#old_login_btn", new: "#new_login_btn",
                         newComment: "1行目\n2行目")]
        let result = HealFixApplier.apply(fixes: fixes, toSource: source)

        XCTAssertTrue(result.source.contains("\"#new_login_btn\""),
                      "コメント更新が失敗してもセレクタ置換は反映されている")
        XCTAssertEqual(result.applied.map(\.id), fixes.map(\.id))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.id, fixes[0].id)
    }

    func testApplyMultipleFixesSameFile() {
        // 入力順(15→14)と異なる行番号順で適用されても両方成功する
        let fixes = [
            fix(line: 15, old: "#old_submit_btn", new: "#new_submit_btn"),
            fix(line: 14, old: "#old_login_btn", new: "#new_login_btn"),
        ]
        let result = HealFixApplier.apply(fixes: fixes, toSource: source)

        XCTAssertTrue(result.source.contains("\"#new_login_btn\""))
        XCTAssertTrue(result.source.contains("\"#new_submit_btn\""))
        XCTAssertEqual(result.applied.count, 2)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testRemovingAppliedKeysFromCache() {
        let dict: [String: Any] = [
            "ログインテスト.S0010|scenarios/Login.swift:14|#old_login_btn": ["newSelector": "x"],
            "他のキー": ["newSelector": "y"],
        ]
        let result = HealFixApplier.removingAppliedKeys(
            ["ログインテスト.S0010|scenarios/Login.swift:14|#old_login_btn"], from: dict)

        XCTAssertTrue(result.changed)
        XCTAssertNil(result.dict["ログインテスト.S0010|scenarios/Login.swift:14|#old_login_btn"])
        XCTAssertNotNil(result.dict["他のキー"])
    }

    func testRemovingAppliedKeysNoMatchIsNoop() {
        let dict: [String: Any] = ["既存キー": ["newSelector": "x"]]
        let result = HealFixApplier.removingAppliedKeys(["存在しないキー"], from: dict)

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.dict.count, 1)
    }
}

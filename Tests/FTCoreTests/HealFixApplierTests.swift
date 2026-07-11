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
                     file: String = "Scenarios/Login.swift") -> HealFixInput {
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
            "ログインテスト.S0010|Scenarios/Login.swift:14|#old_login_btn": ["newSelector": "x"],
            "他のキー": ["newSelector": "y"],
        ]
        let result = HealFixApplier.removingAppliedKeys(
            ["ログインテスト.S0010|Scenarios/Login.swift:14|#old_login_btn"], from: dict)

        XCTAssertTrue(result.changed)
        XCTAssertNil(result.dict["ログインテスト.S0010|Scenarios/Login.swift:14|#old_login_btn"])
        XCTAssertNotNil(result.dict["他のキー"])
    }

    func testRemovingAppliedKeysNoMatchIsNoop() {
        let dict: [String: Any] = ["既存キー": ["newSelector": "x"]]
        let result = HealFixApplier.removingAppliedKeys(["存在しないキー"], from: dict)

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.dict.count, 1)
    }
}

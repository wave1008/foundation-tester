import XCTest
@testable import FTCore

/// 自己修復の修正提案を run の終わりにシナリオへ書き戻す計画(`HealWriteBack`)。
/// 利用者の .swift を直接書き換えるので、**書いてはいけない場合**(別プロジェクト・食い違う提案・`..`)を固定する
final class HealWriteBackTests: XCTestCase {

    private let scenariosDir = "/Users/me/dev/MyApp/scenarios"
    private let existing: Set<String> = ["/Users/me/dev/MyApp/scenarios/Login/LoginTests.swift",
                                         "/Users/me/dev/MyApp/scenarios/Cart.swift",
                                         "/Users/me/dev/Other/scenarios/Cart.swift"]

    private func plan(_ suggestions: [HealWriteBack.Suggestion]) -> HealWriteBack.Plan {
        HealWriteBack.plan(suggestions, scenariosDir: scenariosDir, projectDirNames: ["MyApp", "my-app"],
                           currentDirectory: "/Users/me/dev",
                           // 本物のファイルシステムと同じく `..` を解決して答える(解決しないと `..` の門が無くても素通りする)
                           fileExists: { self.existing.contains(URL(fileURLWithPath: $0).standardized.path) })
    }

    private func suggestion(_ file: String, line: Int = 10, old: String = "#login", new: String = "#signIn",
                            id: String = "LoginTests.s1") -> HealWriteBack.Suggestion {
        HealWriteBack.Suggestion(scenarioID: id, file: file, line: line, oldSelector: old, newSelector: new)
    }

    // MARK: - suggestions

    /// 場所と旧・新がそろった提案だけを集める(欠けた提案・旧と新が同じ提案は書き戻せない)
    func testOnlyCompleteSuggestionsAreCollected() {
        let record = ScenarioRunRecord(
            scenarioID: "A.s", platform: "ios", passed: true, startedAt: "", durationMs: 0,
            steps: StepCountsRecord(total: 1, passed: 1),
            fixSuggestions: [
                FixSuggestionRecord(scene: 1, file: "/x.swift", line: 3, oldSelector: "#a", newSelector: "#b"),
                FixSuggestionRecord(scene: 1, file: nil, line: 3, oldSelector: "#a", newSelector: "#b"),
                FixSuggestionRecord(scene: 1, file: "/x.swift", line: nil, oldSelector: "#a", newSelector: "#b"),
                FixSuggestionRecord(scene: 1, file: "/x.swift", line: 4, oldSelector: "#a", newSelector: nil),
                FixSuggestionRecord(scene: 1, file: "/x.swift", line: 5, oldSelector: "#a", newSelector: "#a"),
            ])
        XCTAssertEqual(HealWriteBack.suggestions(from: [record]),
                       [HealWriteBack.Suggestion(scenarioID: "A.s", file: "/x.swift", line: 3,
                                                 oldSelector: "#a", newSelector: "#b")])
    }

    /// `ft_run_scenario` は記録を作らずイベントから集める。記録と同じ条件(場所と旧・新がそろう)
    func testEventSuggestionUsesTheSameConditions() {
        var event = ScenarioEvent(kind: "fixSuggestion")
        event.file = "a.swift"
        event.line = 3
        event.oldSelector = "#a"
        event.newSelector = "#b"
        XCTAssertEqual(HealWriteBack.suggestion(from: event, fallbackScenarioID: "C.s"),
                       HealWriteBack.Suggestion(scenarioID: "C.s", file: "a.swift", line: 3,
                                                oldSelector: "#a", newSelector: "#b"))
        var other = event
        other.kind = "step"
        XCTAssertNil(HealWriteBack.suggestion(from: other, fallbackScenarioID: "C.s"))
        var weak = event
        weak.newSelector = nil
        XCTAssertNil(HealWriteBack.suggestion(from: weak, fallbackScenarioID: "C.s"))
    }

    // MARK: - plan

    func testLocalPathIsKept() {
        let result = plan([suggestion(scenariosDir + "/Login/LoginTests.swift")])
        XCTAssertEqual(result.fixes.map(\.file), [scenariosDir + "/Login/LoginTests.swift"])
        XCTAssertEqual(result.skipped, [])
    }

    /// リモートで走った回はランナー機のパス(`TestProjects/<プロジェクト名>/scenarios/…`)。手元の同じファイルへ読み替える
    func testRunnerPathIsMappedToTheLocalScenariosFolder() {
        let runner = "/Users/ci/fleetest-runner/users/me/work/TestProjects/my-app/scenarios/Cart.swift"
        XCTAssertEqual(plan([suggestion(runner)]).fixes.map(\.file), [scenariosDir + "/Cart.swift"])
    }

    /// 実際の記録は子の cwd(= 親の cwd)からの相対パス(実データ: `TestProjects/E2E-CMP/scenarios/94_指紋照合.swift`)
    func testPathRelativeToTheCurrentDirectoryIsResolved() {
        // フォルダ名の照合に頼らない(名前を外しても cwd 基準で解決する)
        let result = HealWriteBack.plan([suggestion("MyApp/scenarios/Cart.swift")], scenariosDir: scenariosDir,
                                        projectDirNames: ["unrelated"], currentDirectory: "/Users/me/dev",
                                        fileExists: { self.existing.contains($0) })
        XCTAssertEqual(result.fixes.map(\.file), [scenariosDir + "/Cart.swift"])
    }

    /// ランナー機の cwd 基準の相対パス(clone 構成 = `TestProjects/<名前>/scenarios/…`、外部パッケージ構成 = `scenarios/…`)
    func testRunnerRelativePathsAreMapped() {
        XCTAssertEqual(plan([suggestion("TestProjects/my-app/scenarios/Login/LoginTests.swift"),
                             suggestion("scenarios/Cart.swift", line: 30)]).fixes.map(\.file),
                       [scenariosDir + "/Login/LoginTests.swift", scenariosDir + "/Cart.swift"])
    }

    /// 別のプロジェクトのファイル(実在しても)・手元に無いファイル・`..` で外へ出るパスは書かない
    func testFilesOutsideThisProjectAreNotWritten() {
        let result = plan([
            suggestion("/Users/me/dev/Other/scenarios/Cart.swift"),
            suggestion("/Users/ci/work/TestProjects/MyApp/scenarios/Missing.swift"),
            suggestion("/Users/ci/work/TestProjects/MyApp/scenarios/../../Other/scenarios/Cart.swift"),
            suggestion(scenariosDir + "/../../Other/scenarios/Cart.swift"),
        ])
        XCTAssertEqual(result.fixes, [])
        XCTAssertEqual(result.skipped.count, 4)
    }

    /// 同じ場所への同じ提案(複数デバイスで同じシナリオを回した)は1件に畳む
    func testIdenticalSuggestionsAreWrittenOnce() {
        let file = scenariosDir + "/Cart.swift"
        let result = plan([suggestion(file, id: "Cart.a"), suggestion(file, id: "Cart.a")])
        XCTAssertEqual(result.fixes.count, 1)
        XCTAssertEqual(result.skipped, [])
    }

    /// 同じ場所に違う新セレクタが提案されたら、どちらも書かない(どちらが正しいかツールには言えない)
    func testConflictingSuggestionsAreSkipped() throws {
        let file = scenariosDir + "/Cart.swift"
        let result = plan([suggestion(file, new: "#signIn"), suggestion(file, new: "#logIn"),
                           suggestion(file, line: 20, old: "#buy", new: "#purchase")])
        XCTAssertEqual(result.fixes.map(\.line), [20])
        XCTAssertEqual(result.skipped.map(\.place), [file + ":10"])
        let reason = try XCTUnwrap(result.skipped.first).reason
        XCTAssertTrue(reason.contains("\"#logIn\", \"#signIn\""), reason)
    }

    // MARK: - apply

    private func fix(line: Int, old: String, new: String) -> HealFixInput {
        HealFixInput(scenarioID: "A.s", file: "/f.swift", line: line, oldSelector: old, newSelector: new,
                     newComment: nil)
    }

    func testReplacesTheOldSelector() {
        let source = "a\n        it.tap(\"#login\")\nb"
        let result = HealWriteBack.apply(fixes: [fix(line: 2, old: "#login", new: "#signIn")], toSource: source)
        XCTAssertEqual(result.source, "a\n        it.tap(\"#signIn\")\nb")
        XCTAssertEqual(result.written.count, 1)
        XCTAssertEqual(result.alreadyApplied, [])
        XCTAssertEqual(result.failures, [])
    }

    /// 並行する run が先に書いていたら、失敗ではなく書き戻し済みと数える
    func testAlreadyWrittenLineIsNotAFailure() {
        let source = "a\n        it.tap(\"#signIn\")"
        let result = HealWriteBack.apply(fixes: [fix(line: 2, old: "#login", new: "#signIn")], toSource: source)
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.written, [])
        XCTAssertEqual(result.alreadyApplied.count, 1)
        XCTAssertEqual(result.failures, [])
    }

    /// 行が変わっていた(run の後に利用者が編集した)ら書かずに失敗として言う
    func testChangedLineIsAFailure() {
        let source = "a\n        it.tap(\"#other\")"
        let result = HealWriteBack.apply(fixes: [fix(line: 2, old: "#login", new: "#signIn")], toSource: source)
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.written, [])
        XCTAssertEqual(result.alreadyApplied, [])
        XCTAssertEqual(result.failures.count, 1)
    }
}

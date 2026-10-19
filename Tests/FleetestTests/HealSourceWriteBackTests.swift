import XCTest
import FTCore
import FTRemote
@testable import fleetest

/// run の終わりに自己修復の修正提案をシナリオの .swift へ書き戻す(`HealSourceWriteBack`)。
/// 実ファイルシステムの一時プロジェクトに書く。**緑の run では提案が出ないので、この経路はデバイス実行ではほぼ通らない**
final class HealSourceWriteBackTests: XCTestCase {
    private var root: URL!
    private var project: TestProject!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealSourceWriteBackTests-\(UUID().uuidString)", isDirectory: true)
        project = TestProject(name: "MyApp", rootURL: root.appendingPathComponent("TestProjects/MyApp"))
        try FileManager.default.createDirectory(at: project.scenariosDir.appendingPathComponent("Login"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func scenarioFile() -> URL { project.scenariosDir.appendingPathComponent("Login/LoginTests.swift") }

    private func record(file: String, line: Int = 2, old: String = "#login", new: String = "#signIn")
        -> ScenarioRunRecord {
        ScenarioRunRecord(scenarioID: "LoginTests.s1", platform: "ios", passed: true, startedAt: "",
                          durationMs: 0, steps: StepCountsRecord(total: 1, passed: 1, healed: 1),
                          fixSuggestions: [FixSuggestionRecord(scene: 1, file: file, line: line,
                                                               oldSelector: old, newSelector: new)])
    }

    func testRewritesTheScenarioAndSaysSo() throws {
        try "x\n        it.tap(\"#login\")\n".write(to: scenarioFile(), atomically: true, encoding: .utf8)
        var lines: [String] = []
        let outcome = HealSourceWriteBack.run(
            records: [record(file: scenarioFile().resolvingSymlinksInPath().path)], project: project) { lines.append($0) }
        XCTAssertEqual(try String(contentsOf: scenarioFile(), encoding: .utf8), "x\n        it.tap(\"#signIn\")\n")
        XCTAssertEqual(outcome.written.count, 1)
        XCTAssertTrue(lines.first?.contains("wrote 1 selector fix(es) back") == true, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("scenarios/Login/LoginTests.swift:2") }, lines.joined(separator: "\n"))
    }

    /// リモートで走った回の記録はランナー機のパスを持つ。発行側の回収(`writeBackHealedSelectors`)が手元のファイルを書く
    func testRemoteRecordsAreWrittenToTheLocalFile() throws {
        try "x\n        it.tap(\"#login\")\n".write(to: scenarioFile(), atomically: true, encoding: .utf8)
        let dispatcher = RemoteRunDispatcher(
            host: try RemoteHostSpec.parse("user@host"), remoteDirRaw: "~/fleetest-runner", localRepoRoot: root)
        let runnerPath = "/Users/ci/fleetest-runner/users/me/work/TestProjects/MyApp/scenarios/Login/LoginTests.swift"
        let data = try JSONEncoder().encode(record(file: runnerPath))
        dispatcher.writeBackHealedSelectors(texts: [(URL(fileURLWithPath: "/unused"), String(decoding: data, as: UTF8.self))],
                                            project: project)
        XCTAssertEqual(try String(contentsOf: scenarioFile(), encoding: .utf8), "x\n        it.tap(\"#signIn\")\n")
    }

    /// ランナー機の子 run(印あり)は書かない
    func testDispatchedChildDoesNotWrite() throws {
        let source = "x\n        it.tap(\"#login\")\n"
        try source.write(to: scenarioFile(), atomically: true, encoding: .utf8)
        setenv(HealWriteBack.dispatchedRunEnvironmentKey, "1", 1)
        defer { unsetenv(HealWriteBack.dispatchedRunEnvironmentKey) }
        var lines: [String] = []
        HealSourceWriteBack.run(records: [record(file: scenarioFile().resolvingSymlinksInPath().path)],
                                project: project) { lines.append($0) }
        XCTAssertEqual(try String(contentsOf: scenarioFile(), encoding: .utf8), source)
        XCTAssertEqual(lines, [])
    }

    /// シンボリックリンクは書かない(原子的な書き込みがリンクを普通のファイルに置き換え、実体は古いまま残る)
    func testSymbolicLinkIsNotWritten() throws {
        let target = root.appendingPathComponent("elsewhere.swift")
        let source = "x\n        it.tap(\"#login\")\n"
        try source.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: scenarioFile(), withDestinationURL: target)
        // リンク自体のパス(フォルダだけ実体に直す。リンクまで解決すると `scenarios/` の外 = 別の門で落ちる)
        let linkPath = project.scenariosDir.resolvingSymlinksInPath().appendingPathComponent("Login/LoginTests.swift").path
        var lines: [String] = []
        HealSourceWriteBack.run(records: [record(file: linkPath)],
                                project: project) { lines.append($0) }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), source)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: scenarioFile().path))
        XCTAssertTrue(lines.contains { $0.contains("symbolic link") }, lines.joined(separator: "\n"))
    }

    // MARK: - 分割した run(子は親へ渡し、親が1回だけ書く)

    /// 子として走る run(環境に受け口がある)は書かずに渡す。親の `finish` が全提案で1回だけ計画して書く
    func testSubRunsHandSuggestionsToTheParentWhichWritesOnce() throws {
        let source = "x\n        it.tap(\"#login\")\n"
        try source.write(to: scenarioFile(), atomically: true, encoding: .utf8)
        let collection = HealSourceWriteBack.Collection(directory: root)
        let path = scenarioFile().resolvingSymlinksInPath().path
        var childLines: [String] = []
        try withCollectEnvironment(collection) {
            HealSourceWriteBack.run(records: [record(file: path)], project: project) { childLines.append($0) }
            HealSourceWriteBack.run(records: [record(file: path)], project: project) { childLines.append($0) }
        }
        XCTAssertEqual(try String(contentsOf: scenarioFile(), encoding: .utf8), source, "子が自分で書いた")
        XCTAssertEqual(childLines, [])
        var parentLines: [String] = []
        let outcome = collection.finish(project: project) { parentLines.append($0) }
        XCTAssertEqual(outcome.written.count, 1, "同じ提案を2つの子から受けて1回だけ書く")
        XCTAssertEqual(try String(contentsOf: scenarioFile(), encoding: .utf8), "x\n        it.tap(\"#signIn\")\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: collection.url.path), "受け口のファイルが残った")
    }

    /// **子をまたいで食い違う提案は書かない**(この仕組みの目的。子ごとに書くと先に書いた子の提案が採られる)
    func testConflictingSuggestionsFromDifferentSubRunsAreNotWritten() throws {
        let source = "x\n        it.tap(\"#login\")\n"
        try source.write(to: scenarioFile(), atomically: true, encoding: .utf8)
        let collection = HealSourceWriteBack.Collection(directory: root)
        let path = scenarioFile().resolvingSymlinksInPath().path
        try withCollectEnvironment(collection) {
            HealSourceWriteBack.run(records: [record(file: path, new: "#signIn")], project: project) { _ in }
            HealSourceWriteBack.run(records: [record(file: path, new: "#logIn")], project: project) { _ in }
        }
        var lines: [String] = []
        let outcome = collection.finish(project: project) { lines.append($0) }
        XCTAssertEqual(outcome.written, [])
        XCTAssertEqual(try String(contentsOf: scenarioFile(), encoding: .utf8), source)
        XCTAssertTrue(lines.contains { $0.contains("different selectors were suggested") }, lines.joined(separator: "\n"))
    }

    /// 読めない行は黙って捨てずに数えて言う
    func testUnreadableHandedOverLinesAreReported() throws {
        let collection = HealSourceWriteBack.Collection(directory: root)
        try "not json\n".write(to: collection.url, atomically: true, encoding: .utf8)
        var lines: [String] = []
        collection.finish(project: project) { lines.append($0) }
        XCTAssertTrue(lines.contains { $0.contains("1 fix suggestion line(s)") }, lines.joined(separator: "\n"))
    }

    private func withCollectEnvironment(_ collection: HealSourceWriteBack.Collection, _ body: () throws -> Void) rethrows {
        setenv(collection.environment.key, collection.environment.value, 1)
        defer { unsetenv(collection.environment.key) }
        try body()
    }

    /// 書けなかった提案(行が変わっていた)は書かずに理由を言う
    func testUnwritableFixIsReported() throws {
        let source = "x\n        it.tap(\"#other\")\n"
        try source.write(to: scenarioFile(), atomically: true, encoding: .utf8)
        var lines: [String] = []
        HealSourceWriteBack.run(records: [record(file: scenarioFile().resolvingSymlinksInPath().path)],
                                project: project) { lines.append($0) }
        XCTAssertEqual(try String(contentsOf: scenarioFile(), encoding: .utf8), source)
        XCTAssertTrue(lines.first?.contains("could not write 1 selector fix(es)") == true, lines.joined(separator: "\n"))
    }
}

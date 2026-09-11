// `RemoteRunDispatcher.collectedScenarioTexts` must read only the scenario JSON files that this
// dispatch's rsync actually transferred (a full scan of results/runs/** costs ~50 s per dispatch
// and grows with history), and `writeLastResults` must turn those records into `--failed` entries
// for the right (project, profile) bucket. Reverting either to "scan everything" / "don't record
// locally" breaks the tests below.

import XCTest
import FTCore
import FTRemote
@testable import fleetest

final class RemoteDispatcherScenarioTextsTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!
    var dispatcher: RemoteRunDispatcher!
    private var savedPackageRoot: String?

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RemoteDispatcherScenarioTextsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(
            to: tempDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        setenv("FT_PACKAGE_ROOT", tempDir.path, 1)
        project = TestProject(name: "E2E", rootURL: tempDir.appendingPathComponent("TestProjects/E2E"))
        dispatcher = RemoteRunDispatcher(
            host: try RemoteHostSpec.parse("user@host"), remoteDirRaw: "~/fleetest-runner",
            localRepoRoot: tempDir)
    }

    override func tearDownWithError() throws {
        if let savedPackageRoot { setenv("FT_PACKAGE_ROOT", savedPackageRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeScenarioJSON(relativePath: String, content: String) throws {
        let url = project.rootURL.appendingPathComponent("results").appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - collectedScenarioTexts 

    /// **今回転送された一覧に無いファイルは、たとえ内容が stamp を含んでいても読まない** ——
    /// 全件走査(過去2か月分)へ退行していないことの直接の証拠。この1本は、退行すると
    /// (= 全 results/runs を再び歩くよう戻すと)無関係にも見えるが実際には壊れない、という
    /// 誤った安心を与えないよう、"stamp を含むが一覧に無いファイル" を意図的に混ぜている
    func testOnlyReadsFilesInTheTransferredList() throws {
        let stamp = "20260911-050000Z-1234"
        try writeScenarioJSON(
            relativePath: "runs/2026-09/\(stamp)/scenarios/S0010.json",
            content: "{\"scenarioID\": \"A.S0010\", \"passed\": true, \"reportPath\": \"x/\(stamp)/reports/S0010.md\"}")
        // 一覧に無い(=このディスパッチの rsync が転送しなかった)が stamp を含む古いファイル。
        // 全件走査に戻っていれば誤って拾われてしまう
        try writeScenarioJSON(
            relativePath: "runs/2026-08/other-run/scenarios/Stale.json",
            content: "{\"scenarioID\": \"Stale.one\", \"passed\": false, \"note\": \"\(stamp)\"}")

        let texts = dispatcher.collectedScenarioTexts(
            project: project, stamp: stamp,
            transferredScenarioPaths: ["runs/2026-09/\(stamp)/scenarios/S0010.json"])

        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].text.contains("A.S0010"))
    }

    /// 一覧にあっても、この stamp を含まないファイルは読まない(他の run のファイルを巻き込まない)
    func testSkipsTransferredFilesNotMatchingThisStamp() throws {
        try writeScenarioJSON(
            relativePath: "runs/2026-09/other/scenarios/S0020.json",
            content: "{\"scenarioID\": \"B.S0020\", \"passed\": true}")
        let texts = dispatcher.collectedScenarioTexts(
            project: project, stamp: "20260911-050000Z-9999",
            transferredScenarioPaths: ["runs/2026-09/other/scenarios/S0020.json"])
        XCTAssertTrue(texts.isEmpty)
    }

    // MARK: - recordedBoolField

    func testRecordedBoolFieldReadsTrueAndFalse() {
        XCTAssertEqual(RemoteRunDispatcher.recordedBoolField(in: "{\"passed\": true}", key: "passed"), true)
        XCTAssertEqual(RemoteRunDispatcher.recordedBoolField(in: "{\"passed\": false}", key: "passed"), false)
        XCTAssertNil(RemoteRunDispatcher.recordedBoolField(in: "{\"other\": true}", key: "passed"))
        XCTAssertNil(RemoteRunDispatcher.recordedBoolField(in: "{\"passed\": \"true\"}", key: "passed"))
    }

    // MARK: - writeLastResults

    /// リモートで走った分の合否が、そのシナリオの `profile` に対応する `--failed` バケットへ届く
    func testWriteLastResultsRecordsPerProfileFromRemoteScenarioJSON() {
        let texts: [(url: URL, text: String)] = [
            (tempDir.appendingPathComponent("a.json"),
             "{\"scenarioID\": \"Login.S0010\", \"passed\": false, \"profile\": \"ios-inapp\"}"),
            (tempDir.appendingPathComponent("b.json"),
             "{\"scenarioID\": \"Login.S0020\", \"passed\": true, \"profile\": \"ios-inapp\"}"),
        ]
        dispatcher.writeLastResults(texts: texts, project: project)
        XCTAssertTrue(LastResultsStore.failedIDs(project: project, profile: "ios-inapp").contains("Login.S0010"))
        XCTAssertFalse(LastResultsStore.failedIDs(project: project, profile: "ios-inapp").contains("Login.S0020"))
        // 別プロファイルのバケットは触っていない
        XCTAssertFalse(LastResultsStore.failedIDs(project: project, profile: "android").contains("Login.S0010"))
    }

    /// `profile` 欄が無い(profile-less remote run)記録は noProfileKey のバケットへ
    func testWriteLastResultsWithoutProfileFieldUsesNoProfileBucket() {
        let texts: [(url: URL, text: String)] = [
            (tempDir.appendingPathComponent("c.json"),
             "{\"scenarioID\": \"Login.S0030\", \"passed\": false}"),
        ]
        dispatcher.writeLastResults(texts: texts, project: project)
        XCTAssertTrue(LastResultsStore.failedIDs(project: project, profile: nil).contains("Login.S0030"))
    }
}

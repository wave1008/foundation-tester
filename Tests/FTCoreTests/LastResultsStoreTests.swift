import XCTest
@testable import FTCore

final class LastResultsStoreTests: XCTestCase {
    var stateDir: URL!
    private var savedPackageRoot: String?

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LastResultsStoreTests-\(UUID().uuidString)")
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
    }

    override func tearDownWithError() throws {
        if let savedPackageRoot { setenv("FT_PACKAGE_ROOT", savedPackageRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        try? FileManager.default.removeItem(at: stateDir)
    }

    func testMissingDirReturnsEmptySet() {
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), [])
    }

    func testRecordFailedAppearsInFailedIDs() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "Foo.bar", passed: false)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), ["Foo.bar"])
    }

    func testRecordPassedIsExcluded() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "Foo.bar", passed: true)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), [])
    }

    func testOverwriteFailedWithPassedRemovesFromFailedIDs() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "Foo.bar", passed: false)
        LastResultsStore.record(stateDir: stateDir, scenarioID: "Foo.bar", passed: true)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), [])
    }

    func testMultipleScenariosOnlyFailedOnesReturned() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "A.one", passed: false)
        LastResultsStore.record(stateDir: stateDir, scenarioID: "B.two", passed: true)
        LastResultsStore.record(stateDir: stateDir, scenarioID: "C.three", passed: false)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), ["A.one", "C.three"])
    }

    // MARK: - (project, profile) 単位の分離

    /// `ScenarioHost.packageRoot()` を stateDir へ固定する(FT_PACKAGE_ROOT。
    /// ScenarioHostRunnerUnavailableTests と同じ手段)。無指定だと cwd から遡って
    /// リポジトリ本体の Package.swift を掴み、実リポジトリの .fleetest/ に書いてしまう
    private func makeProject() throws -> TestProject {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(
            to: stateDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        setenv("FT_PACKAGE_ROOT", stateDir.path, 1)
        return TestProject(name: "P", rootURL: stateDir.appendingPathComponent("TestProjects/P"))
    }

    /// 別プロファイルの緑が別プロファイルの赤を上書きしない
    /// (以前は project 単位の1ファイルだけで、後勝ちの上書きが起きていた)
    func testDifferentProfilesDoNotOverwriteEachOther() throws {
        let project = try makeProject()
        LastResultsStore.record(project: project, scenarioID: "S.one", passed: false, profile: "ios-inapp")
        LastResultsStore.record(project: project, scenarioID: "S.one", passed: true, profile: "android")
        XCTAssertTrue(LastResultsStore.failedIDs(project: project, profile: "ios-inapp").contains("S.one"),
                      "ios-inapp の赤が android の緑に上書きされてはいけない")
        XCTAssertFalse(LastResultsStore.failedIDs(project: project, profile: "android").contains("S.one"))
    }

    /// profile-less(nil)は専用の区分(noProfileKey)へ記録され、named profile とは別扱い
    func testProfileLessRunUsesItsOwnBucket() throws {
        let project = try makeProject()
        LastResultsStore.record(project: project, scenarioID: "S.two", passed: false, profile: nil)
        XCTAssertTrue(LastResultsStore.failedIDs(project: project, profile: nil).contains("S.two"))
        XCTAssertFalse(LastResultsStore.failedIDs(project: project, profile: "ios-inapp").contains("S.two"))
        XCTAssertTrue(LastResultsStore.stateDir(project: project, profile: nil).path
            .hasSuffix("/\(LastResultsStore.noProfileKey)"))
    }
}

import XCTest
@testable import FTCore

final class ProjectStoreTests: XCTestCase {
    var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func makeProject(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent("Projects/\(name)/Scenarios"),
            withIntermediateDirectories: true)
    }

    func testAllAndFind() throws {
        XCTAssertTrue(ProjectStore.all(repoRoot: repoRoot).isEmpty)
        XCTAssertThrowsError(try ProjectStore.find(nil, repoRoot: repoRoot)) { error in
            guard case ProjectStoreError.noProjects = error else {
                return XCTFail("noProjects のはず: \(error)")
            }
        }

        try makeProject("Beta")
        try makeProject("Alpha")
        let all = ProjectStore.all(repoRoot: repoRoot)
        XCTAssertEqual(all.map(\.name), ["Alpha", "Beta"], "名前順")

        let beta = try ProjectStore.find("Beta", repoRoot: repoRoot)
        XCTAssertEqual(beta.productName, "ftester-scenarios-Beta")
        XCTAssertEqual(beta.scenariosDir.lastPathComponent, "Scenarios")

        let picked = try ProjectStore.find(nil, repoRoot: repoRoot, defaultProject: "Alpha")
        XCTAssertEqual(picked.name, "Alpha")

        XCTAssertThrowsError(try ProjectStore.find(nil, repoRoot: repoRoot)) { error in
            guard case ProjectStoreError.ambiguous(let available) = error else {
                return XCTFail("ambiguous のはず: \(error)")
            }
            XCTAssertEqual(available, ["Alpha", "Beta"])
        }

        XCTAssertThrowsError(try ProjectStore.find("Ghost", repoRoot: repoRoot)) { error in
            guard case ProjectStoreError.notFound = error else {
                return XCTFail("notFound のはず: \(error)")
            }
        }
    }

    func testFindSingleProjectWithoutName() throws {
        try makeProject("Only")
        let project = try ProjectStore.find(nil, repoRoot: repoRoot)
        XCTAssertEqual(project.name, "Only")
    }

    func testNameValidation() {
        XCTAssertTrue(ProjectStore.isValidName("SampleApp"))
        XCTAssertTrue(ProjectStore.isValidName("a-b_c1"))
        XCTAssertTrue(ProjectStore.isValidName("_private"))
        XCTAssertFalse(ProjectStore.isValidName("-lead"))
        XCTAssertFalse(ProjectStore.isValidName("日本語"))
        XCTAssertFalse(ProjectStore.isValidName("a b"))
        XCTAssertFalse(ProjectStore.isValidName(""))
    }
}

final class LocalConfigTests: XCTestCase {
    func testSaveLoadRoundtrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-config-\(UUID().uuidString)/ftester/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

        var config = LocalConfig()
        config.machineName = "M1 Max(64GB)"
        config.defaultProject = "SampleApp"
        try config.save(to: url)
        XCTAssertEqual(LocalConfig.load(from: url), config)

        try "not json".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(LocalConfig.load(from: url), LocalConfig())
    }

    func testCurrentMachineNamePriority() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-config-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try LocalConfig(machineName: "FromConfig").save(to: url)

        XCTAssertEqual(
            LocalConfig.currentMachineName(environment: ["FT_MACHINE": "FromEnv"], configURL: url),
            "FromEnv", "FT_MACHINE が最優先")
        XCTAssertEqual(
            LocalConfig.currentMachineName(environment: [:], configURL: url),
            "FromConfig")
        XCTAssertNil(
            LocalConfig.currentMachineName(
                environment: [:],
                configURL: url.deletingLastPathComponent().appendingPathComponent("none.json")))
    }

    func testXDGConfigHome() {
        let url = LocalConfig.url(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"])
        XCTAssertEqual(url.path, "/tmp/xdg/ftester/config.json")
    }
}

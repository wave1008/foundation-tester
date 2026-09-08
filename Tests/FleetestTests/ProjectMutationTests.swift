// verify=false: dump-package 検証(遅い)を全テストでスキップ(PackageManifestEditorTests と同じ規律)
import XCTest
import FTCore

final class ProjectMutationTests: XCTestCase {
    var repoRoot: URL!

    let manifestTemplate = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "fixture",
        targets: [
            // === fleetest projects begin(fleetest project create/sync が自動生成。手編集禁止)===
            // === fleetest projects end ===
        ]
    )
    """

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FleetestTests-project-mutation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try manifestTemplate.write(
            to: repoRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    @discardableResult
    private func makeProject(_ name: String, app: String = "com.example.myapp") throws -> TestProject {
        let project = TestProject(
            name: name, rootURL: ProjectStore.projectsDir(repoRoot: repoRoot).appendingPathComponent(name))
        try ProjectScaffold.create(project: project, app: app, platforms: ["ios"])
        return project
    }

    private func registeredNames() throws -> [String] {
        try PackageManifestEditor.registeredProjects(
            manifestURL: repoRoot.appendingPathComponent("Package.swift"))
    }

    // MARK: - copy

    func testCopyDuplicatesFilesAndRegistersInManifest() throws {
        try makeProject("Source")
        let copy = try ProjectMutation.copy(
            source: "Source", newName: "Copied", repoRoot: repoRoot, verify: false)

        XCTAssertEqual(copy.name, "Copied")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copy.scenariosDir.appendingPathComponent("_Main.swift").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copy.appsDir.appendingPathComponent("source.json").path),
            "app プロファイルは名前を追随させないので複製元のファイル名のまま複製される")
        XCTAssertEqual(try registeredNames(), ["Copied", "Source"])
    }

    func testCopyExcludesRunArtifactsAndCaches() throws {
        let source = try makeProject("Source")
        try Data("x".utf8).write(to: source.reportsDir.appendingPathComponent("x.json"))
        let fleetestStateDir = source.rootURL.appendingPathComponent(".fleetest")
        try FileManager.default.createDirectory(at: fleetestStateDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fleetestStateDir.appendingPathComponent("y.json"))
        let appsWorkspaceDir = source.rootURL.appendingPathComponent("workspace/apps")
        try FileManager.default.createDirectory(at: appsWorkspaceDir, withIntermediateDirectories: true)
        try Data().write(to: appsWorkspaceDir.appendingPathComponent("a.app"))

        let copy = try ProjectMutation.copy(
            source: "Source", newName: "Copied", repoRoot: repoRoot, verify: false)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: copy.reportsDir.appendingPathComponent("x.json").path), "reports/ は複製しない")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: copy.rootURL.appendingPathComponent(".fleetest/y.json").path), ".fleetest/ は複製しない")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: copy.rootURL.appendingPathComponent("workspace/apps/a.app").path),
            "workspace/apps/ は複製しない")
        // 除外で消えた workspace/apps/ は WorkspaceScaffold.ensureDefault で空のまま戻る
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copy.rootURL.appendingPathComponent("workspace/apps").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// 除外の判定はプロジェクトルート直下だけ。深い階層の同名ディレクトリは巻き添えにしない
    func testCopyKeepsDeeplyNestedSameNamedDirectory() throws {
        let source = try makeProject("Source")
        let nestedReports = source.scenariosDir.appendingPathComponent("sub/reports")
        try FileManager.default.createDirectory(at: nestedReports, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: nestedReports.appendingPathComponent("keep.txt"))

        let copy = try ProjectMutation.copy(
            source: "Source", newName: "Copied", repoRoot: repoRoot, verify: false)

        let copiedFile = copy.scenariosDir.appendingPathComponent("sub/reports/keep.txt")
        XCTAssertEqual(try String(contentsOf: copiedFile, encoding: .utf8), "keep")
    }

    func testCopyRejectsInvalidNewName() throws {
        try makeProject("Source")
        XCTAssertThrowsError(try ProjectMutation.copy(
            source: "Source", newName: "日本語", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectStoreError.invalidName = error else {
                return XCTFail("invalidName のはず: \(error)")
            }
        }
        XCTAssertThrowsError(try ProjectMutation.copy(
            source: "Source", newName: "a/b", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectStoreError.invalidName = error else {
                return XCTFail("invalidName のはず: \(error)")
            }
        }
    }

    func testCopyRejectsCollisionWithExistingProject() throws {
        try makeProject("Source")
        try makeProject("Existing")
        XCTAssertThrowsError(try ProjectMutation.copy(
            source: "Source", newName: "Existing", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectScaffoldError.alreadyExists = error else {
                return XCTFail("alreadyExists のはず: \(error)")
            }
        }
    }

    func testCopyMissingSourceThrowsNotFound() throws {
        XCTAssertThrowsError(try ProjectMutation.copy(
            source: "Ghost", newName: "New", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectStoreError.notFound = error else {
                return XCTFail("notFound のはず: \(error)")
            }
        }
    }

    // MARK: - rename

    func testRenameMovesDirectoryAndUpdatesManifest() throws {
        let project = try makeProject("Old")
        let marker = project.scenariosDir.appendingPathComponent("_Main.swift")
        let originalContent = try String(contentsOf: marker, encoding: .utf8)

        let renamed = try ProjectMutation.rename(
            oldName: "Old", newName: "New", repoRoot: repoRoot, verify: false)

        XCTAssertEqual(renamed.name, "New")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.path), "旧ディレクトリは消える")
        XCTAssertEqual(
            try String(contentsOf: renamed.scenariosDir.appendingPathComponent("_Main.swift"),
                       encoding: .utf8),
            originalContent)
        XCTAssertEqual(try registeredNames(), ["New"])
    }

    func testRenameRejectsSameName() throws {
        try makeProject("Same")
        XCTAssertThrowsError(try ProjectMutation.rename(
            oldName: "Same", newName: "Same", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectMutationError.sameName = error else {
                return XCTFail("sameName のはず: \(error)")
            }
        }
    }

    func testRenameRejectsInvalidNewName() throws {
        try makeProject("Old")
        XCTAssertThrowsError(try ProjectMutation.rename(
            oldName: "Old", newName: "日本語", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectStoreError.invalidName = error else {
                return XCTFail("invalidName のはず: \(error)")
            }
        }
    }

    func testRenameRejectsCollisionWithExistingProject() throws {
        try makeProject("Old")
        try makeProject("Existing")
        XCTAssertThrowsError(try ProjectMutation.rename(
            oldName: "Old", newName: "Existing", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectScaffoldError.alreadyExists = error else {
                return XCTFail("alreadyExists のはず: \(error)")
            }
        }
    }

    func testRenameMissingProjectThrowsNotFound() throws {
        XCTAssertThrowsError(try ProjectMutation.rename(
            oldName: "Ghost", newName: "New", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectStoreError.notFound = error else {
                return XCTFail("notFound のはず: \(error)")
            }
        }
    }

    // MARK: - delete

    func testDeleteMovesToTrashAndUpdatesManifest() throws {
        let project = try makeProject("Doomed")
        let trashedURL = try ProjectMutation.delete(name: "Doomed", repoRoot: repoRoot, verify: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.path),
                       "TestProjects/ から消える")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: trashedURL.appendingPathComponent("scenarios/_Main.swift").path),
            "ゴミ箱の中に中身が残っている")
        XCTAssertEqual(try registeredNames(), [])

        try? FileManager.default.removeItem(at: trashedURL)
    }

    func testDeleteMissingProjectThrowsNotFound() throws {
        XCTAssertThrowsError(try ProjectMutation.delete(
            name: "Ghost", repoRoot: repoRoot, verify: false)) { error in
            guard case ProjectStoreError.notFound = error else {
                return XCTFail("notFound のはず: \(error)")
            }
        }
    }
}

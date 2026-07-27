import XCTest
@testable import FTCore

final class ProjectScaffoldTests: XCTestCase {
    var packageRoot: URL!
    var settingsURL: URL!

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-vscode-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        packageRoot = dir
        settingsURL = dir.appendingPathComponent(".vscode/settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: packageRoot)
    }

    func testFreshGeneratesProjectAndBinaryPath() throws {
        XCTAssertTrue(try ProjectScaffold.writeVSCodeSettings(
            packageRoot: packageRoot, ftesterPath: "../foundation-tester", projectName: "MyApp"))
        let settings = try readSettings()
        XCTAssertEqual(settings["ftester.project"] as? String, "MyApp")
        XCTAssertEqual(settings["ftester.binaryPath"] as? String,
                       "../foundation-tester/.build/debug/ftester")
    }

    func testNilFtesterPathOmitsBinaryPath() throws {
        XCTAssertTrue(try ProjectScaffold.writeVSCodeSettings(
            packageRoot: packageRoot, ftesterPath: nil, projectName: "MyApp"))
        let settings = try readSettings()
        XCTAssertEqual(settings["ftester.project"] as? String, "MyApp")
        XCTAssertNil(settings["ftester.binaryPath"])
    }

    func testMergeKeepsOtherKeysAndOverwritesOwnKeys() throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        {
          "editor.fontSize": 14,
          "ftester.project": "OldProject"
        }
        """
        try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(try ProjectScaffold.writeVSCodeSettings(
            packageRoot: packageRoot, ftesterPath: "../foundation-tester", projectName: "NewProject"))
        let settings = try readSettings()
        XCTAssertEqual(settings["editor.fontSize"] as? Int, 14, "他キーは温存")
        XCTAssertEqual(settings["ftester.project"] as? String, "NewProject", "自キーは上書き")
        XCTAssertEqual(settings["ftester.binaryPath"] as? String,
                       "../foundation-tester/.build/debug/ftester")
    }

    func testInvalidJSONLeavesFileUntouched() throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = """
        {
          // JSONC コメントは JSONSerialization ではパースできない
          "editor.fontSize": 14,
        }
        """
        try invalid.write(to: settingsURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(try ProjectScaffold.writeVSCodeSettings(
            packageRoot: packageRoot, ftesterPath: "../foundation-tester", projectName: "MyApp"))

        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), invalid,
                       "パース不能なら触らない")
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - ensureGitignore

    private var gitignoreURL: URL {
        packageRoot.appendingPathComponent(".gitignore")
    }

    func testGitignoreFreshCreatesBothEntries() throws {
        let added = try ProjectScaffold.ensureGitignore(packageRoot: packageRoot)
        XCTAssertEqual(added, [".build/", "Projects/*/reports/"])
        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertTrue(content.contains(".build/"))
        XCTAssertTrue(content.contains("Projects/*/reports/"))
        XCTAssertTrue(content.hasSuffix("\n"))
    }

    func testGitignoreSecondCallIsIdempotent() throws {
        _ = try ProjectScaffold.ensureGitignore(packageRoot: packageRoot)
        let before = try String(contentsOf: gitignoreURL, encoding: .utf8)

        let added = try ProjectScaffold.ensureGitignore(packageRoot: packageRoot)
        XCTAssertEqual(added, [])
        let after = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertEqual(before, after, "既に揃っていればファイルは不変")
    }

    func testGitignoreAppendsOnlyMissingEntry() throws {
        let existing = "*.log\n.build\n"
        try existing.write(to: gitignoreURL, atomically: true, encoding: .utf8)

        let added = try ProjectScaffold.ensureGitignore(packageRoot: packageRoot)
        XCTAssertEqual(added, ["Projects/*/reports/"])

        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertTrue(content.contains("*.log"), "既存行は保持")
        XCTAssertTrue(content.contains(".build"), "既存行は保持")
        XCTAssertTrue(content.contains("# ftester"))
        XCTAssertTrue(content.contains("Projects/*/reports/"))
    }

    func testGitignoreAppendDoesNotMergeWithMissingTrailingNewline() throws {
        let existing = "*.log"
        try existing.write(to: gitignoreURL, atomically: true, encoding: .utf8)

        _ = try ProjectScaffold.ensureGitignore(packageRoot: packageRoot)

        let lines = try String(contentsOf: gitignoreURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "*.log", "元の最終行が追記と連結されない")
    }

    func testGitignoreRecognizesAlternateSpellingsAsPresent() throws {
        let existing = "/.build/\n./Projects/*/reports\n"
        try existing.write(to: gitignoreURL, atomically: true, encoding: .utf8)

        let added = try ProjectScaffold.ensureGitignore(packageRoot: packageRoot)
        XCTAssertEqual(added, [])
        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertEqual(content, existing, "変則表記でも既にあると判定し不変")
    }
}

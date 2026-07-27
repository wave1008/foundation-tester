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
}

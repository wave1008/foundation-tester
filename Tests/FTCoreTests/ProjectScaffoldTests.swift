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

    // MARK: - create(生成する run とマシンプロファイル)

    private func makeProject() -> TestProject {
        TestProject(name: "MyApp", rootURL: packageRoot.appendingPathComponent("Projects/MyApp"))
    }

    private func runNames(_ project: TestProject) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: project.runsDir.path).sorted()
    }

    /// iOS だけ指示したのに android/all の run が残ると、マシンプロファイルに無いデバイスを
    /// 参照して profile list が赤くなる(受け手の環境で実際に起きた)
    func testOnlyRequestedPlatformRunsAreCreated() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp", platforms: ["ios"])
        XCTAssertEqual(try runNames(project), ["ios.json"])
    }

    /// all は両方作ったときだけ(片方しか無い all は解決できない)
    func testAllProfileOnlyWhenBothPlatforms() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp",
                                   platforms: ["ios", "android"])
        XCTAssertEqual(try runNames(project), ["all.json", "android.json", "ios.json"])
    }

    /// マシンプロファイルは**ユーザーが名前を決めたときだけ**作る(scaffold が登録済みの名前で
    /// 勝手に作り、あとから別名でも作られて machines/ に2つ並ぶ事故があった)
    func testMachineProfileIsNotCreated() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp", platforms: ["ios"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.machinesDir.path),
                       ["README.md"], "雛形の説明だけで、実体の .json は作らない")
    }

    /// run の devices は ProfileWriter の既定論理名を参照する(片方だけ変えると解決できなくなる)
    func testRunProfileReferencesDefaultDeviceNames() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp",
                                   platforms: ["ios", "android"])
        func devices(_ file: String) throws -> [String] {
            let data = try Data(contentsOf: project.runsDir.appendingPathComponent(file))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (object["devices"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        XCTAssertEqual(try devices("ios.json"), [ProfileWriter.defaultDeviceName(platform: "ios")])
        XCTAssertEqual(try devices("android.json"),
                       [ProfileWriter.defaultDeviceName(platform: "android")])
    }

    // MARK: - .claude/settings.json(Bash 承認を減らす許可リスト)

    private var claudeSettingsURL: URL {
        packageRoot.appendingPathComponent(".claude/settings.json")
    }

    /// 許可するのは ftester 由来のコマンドだけ。汎用の全許可を書かない
    func testClaudeSettingsAddsOnlyFtesterEntries() throws {
        let added = try ProjectScaffold.writeClaudeSettings(packageRoot: packageRoot,
                                                            toolRoot: "/tools/ft")
        XCTAssertFalse(added.isEmpty)
        for entry in added {
            XCTAssertTrue(entry.hasPrefix("Bash("), "許可するのは Bash のみ: \(entry)")
            XCTAssertNotEqual(entry, "Bash(*)")
            // 許可範囲はツールのクローン配下か ftester CLI か読み取り専用の simctl list に限る
            XCTAssertTrue(entry.contains("/tools/ft") || entry.contains("ftester")
                          || entry.contains("xcrun simctl list"),
                          "ftester 由来のコマンドだけを許可する: \(entry)")
        }
    }

    func testClaudeSettingsMergesWithExistingSettings() throws {
        try FileManager.default.createDirectory(
            at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Bash(git status:*)"],"deny":["Bash(rm:*)"]},"model":"opus"}"#
            .write(to: claudeSettingsURL, atomically: true, encoding: .utf8)

        _ = try ProjectScaffold.writeClaudeSettings(packageRoot: packageRoot, toolRoot: "/tools/ft")

        let data = try Data(contentsOf: claudeSettingsURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try XCTUnwrap(object["permissions"] as? [String: Any])
        let allow = try XCTUnwrap(permissions["allow"] as? [String])
        XCTAssertTrue(allow.contains("Bash(git status:*)"), "既存の許可を消さない")
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(rm:*)"], "deny を消さない")
        XCTAssertEqual(object["model"] as? String, "opus", "無関係なキーを消さない")
    }

    func testClaudeSettingsIsIdempotent() throws {
        _ = try ProjectScaffold.writeClaudeSettings(packageRoot: packageRoot, toolRoot: "/tools/ft")
        let second = try ProjectScaffold.writeClaudeSettings(packageRoot: packageRoot,
                                                             toolRoot: "/tools/ft")
        XCTAssertTrue(second.isEmpty, "2回目は追加なし(再実行で増えない)")
    }

    /// JSONC 等で解析できないファイルは触らない(壊すより何もしない。VSCode 設定と同方針)
    func testClaudeSettingsSkipsUnparsableFile() throws {
        try FileManager.default.createDirectory(
            at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = "// comment\n{}"
        try invalid.write(to: claudeSettingsURL, atomically: true, encoding: .utf8)

        let added = try ProjectScaffold.writeClaudeSettings(packageRoot: packageRoot,
                                                            toolRoot: "/tools/ft")
        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(try String(contentsOf: claudeSettingsURL, encoding: .utf8), invalid)
    }
}

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
            packageRoot: packageRoot, fleetestPath: "../foundation-tester", projectName: "MyApp"))
        let settings = try readSettings()
        XCTAssertEqual(settings["fleetest.project"] as? String, "MyApp")
        XCTAssertEqual(settings["fleetest.binaryPath"] as? String,
                       "../foundation-tester/.build/debug/fleetest")
    }

    func testNilFleetestPathOmitsBinaryPath() throws {
        XCTAssertTrue(try ProjectScaffold.writeVSCodeSettings(
            packageRoot: packageRoot, fleetestPath: nil, projectName: "MyApp"))
        let settings = try readSettings()
        XCTAssertEqual(settings["fleetest.project"] as? String, "MyApp")
        XCTAssertNil(settings["fleetest.binaryPath"])
    }

    func testMergeKeepsOtherKeysAndOverwritesOwnKeys() throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        {
          "editor.fontSize": 14,
          "fleetest.project": "OldProject"
        }
        """
        try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(try ProjectScaffold.writeVSCodeSettings(
            packageRoot: packageRoot, fleetestPath: "../foundation-tester", projectName: "NewProject"))
        let settings = try readSettings()
        XCTAssertEqual(settings["editor.fontSize"] as? Int, 14, "他キーは温存")
        XCTAssertEqual(settings["fleetest.project"] as? String, "NewProject", "自キーは上書き")
        XCTAssertEqual(settings["fleetest.binaryPath"] as? String,
                       "../foundation-tester/.build/debug/fleetest")
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
            packageRoot: packageRoot, fleetestPath: "../foundation-tester", projectName: "MyApp"))

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
        XCTAssertEqual(added, [".build/", ".fleetest/", "TestProjects/*/reports/"])
        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertTrue(content.contains(".build/"))
        XCTAssertTrue(content.contains("TestProjects/*/reports/"))
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
        XCTAssertEqual(added, [".fleetest/", "TestProjects/*/reports/"])

        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertTrue(content.contains("*.log"), "既存行は保持")
        XCTAssertTrue(content.contains(".build"), "既存行は保持")
        XCTAssertTrue(content.contains("# fleetest"))
        XCTAssertTrue(content.contains("TestProjects/*/reports/"))
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
        let existing = "/.build/\n.fleetest\n./TestProjects/*/reports\n"
        try existing.write(to: gitignoreURL, atomically: true, encoding: .utf8)

        let added = try ProjectScaffold.ensureGitignore(packageRoot: packageRoot)
        XCTAssertEqual(added, [])
        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        XCTAssertEqual(content, existing, "変則表記でも既にあると判定し不変")
    }

    // MARK: - create(生成する run とマシンプロファイル)

    private func makeProject() -> TestProject {
        TestProject(name: "MyApp", rootURL: packageRoot.appendingPathComponent("TestProjects/MyApp"))
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

    /// 両方指示しても run はプラットフォームごとの2本だけ(横断の all は作らない。ユーザー決定)
    func testBothPlatformsCreateOnlyPerPlatformRuns() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp",
                                   platforms: ["ios", "android"])
        XCTAssertEqual(try runNames(project), ["android.json", "ios.json"])
    }

    /// マシンプロファイルは固定名 local.json を空で作る(ユーザー決定)。**登録済みのマシン名では
    /// 作らない** —— 以前それをやって、あとから別名でも作られ machines/ に2つ並ぶ事故があった。
    /// 固定名なら run が machine で名指しできるので、2つ目が増えても解決は揺れない
    func testMachineProfileIsScaffoldedAsEmptyLocal() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp", platforms: ["ios"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: project.machinesDir.path).sorted(),
            ["README.md", "local.json"])
        let data = try Data(contentsOf: project.machinesDir.appendingPathComponent("local.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object.isEmpty, "中身は空(デバイスは受け手が足す)")
    }

    /// run の machine は雛形のマシンプロファイル名を指す(片方だけ変えると解決できなくなる)
    func testRunProfilesReferenceTheScaffoldedMachine() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp",
                                   platforms: ["ios", "android"])
        for file in ["ios.json", "android.json"] {
            let data = try Data(contentsOf: project.runsDir.appendingPathComponent(file))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["machine"] as? String, "local", file)
        }
    }

    /// run の devices は空(ユーザー決定)。雛形のマシンプロファイルも空なので、論理名を置くと
    /// 最初の `profile list` が「そのデバイスが解決できない」で赤くなり、本当にやるべきこと
    /// (デバイスの登録)が読み取りにくくなる
    func testRunProfileDevicesAreEmpty() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp",
                                   platforms: ["ios", "android"])
        for file in ["ios.json", "android.json"] {
            let data = try Data(contentsOf: project.runsDir.appendingPathComponent(file))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let devices = try XCTUnwrap(object["devices"] as? [Any], file)
            XCTAssertTrue(devices.isEmpty, file)
        }
    }

    /// 雛形はデモシナリオを1本置く。**コンパイルできることと dry-run を通ることが要件**なので、
    /// 実セレクタを使う操作は書かない(対象アプリの画面を知らない)。ここで固定するのは
    /// 「置かれること」「対象アプリの ID が埋まること」「推測のセレクタが混ざらないこと」
    func testDemoScenarioIsScaffolded() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.demo", platforms: ["ios"])
        // **リテラルで書く**(production の定数で組むと、改名の変異をテストが追随して素通しする)
        let url = project.scenariosDir.appendingPathComponent("sample_test.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains(#"@TestClass(app: "com.example.demo")"#), source)
        XCTAssertTrue(source.contains(#"appIs("com.example.demo")"#), source)
        // 実行されるコードにセレクタは無い(書き方の例はコメントの中だけ)
        let live = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(live.contains("#"), "実行されるコードに #id セレクタを書かない")
        XCTAssertFalse(live.contains("tap("), "実行されるコードに操作を書かない")
    }

    /// 空のディレクトリは雛形を置いてよい(受け手・拡張が先に mkdir しただけの器)。
    /// 中身が1つでもあれば不可(上書きは資産を消す側)。`.DS_Store` は中身に数えない
    func testCanScaffoldOnlyIntoAbsentOrEmptyDirectory() throws {
        let fm = FileManager.default
        let absent = packageRoot.appendingPathComponent("TestProjects/Absent")
        XCTAssertTrue(ProjectScaffold.canScaffold(into: absent))

        let empty = packageRoot.appendingPathComponent("TestProjects/Empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertTrue(ProjectScaffold.canScaffold(into: empty))
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        XCTAssertTrue(ProjectScaffold.canScaffold(into: empty), ".DS_Store だけなら空扱い")

        let occupied = packageRoot.appendingPathComponent("TestProjects/Occupied")
        try fm.createDirectory(at: occupied.appendingPathComponent("scenarios"),
                               withIntermediateDirectories: true)
        XCTAssertFalse(ProjectScaffold.canScaffold(into: occupied))

        let file = packageRoot.appendingPathComponent("TestProjects/File")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        XCTAssertFalse(ProjectScaffold.canScaffold(into: file), "同名のファイルは不可")

        // 空の器へ create が通り、通常の雛形が揃う
        let project = TestProject(name: "Empty", rootURL: empty)
        try ProjectScaffold.create(project: project, app: "com.example.myapp", platforms: ["ios"])
        XCTAssertTrue(fm.fileExists(atPath: project.scenariosDir.appendingPathComponent("_Main.swift").path))
    }

    /// 導入時から既定ワークスペースの規約フォルダを置く(run 時の ensure だけに任せると、
    /// 初回実行まで scripts/ = setup.sh の置き場所が見えない)。名前の正は WorkspaceScaffold
    func testCreatePlacesDefaultWorkspaceFolders() throws {
        let project = makeProject()
        try ProjectScaffold.create(project: project, app: "com.example.myapp", platforms: ["ios"])
        let workspace = project.rootURL
            .appendingPathComponent(WorkspaceScaffold.defaultRootName)
        for name in WorkspaceScaffold.directoryNames {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent(name).path, isDirectory: &isDirectory)
            XCTAssertTrue(exists && isDirectory.boolValue, "workspace/\(name) が無い")
        }
    }

    /// 既定ワークスペースの root 名はリゾルバと同じ1箇所から来る(ズレると scaffold が
    /// 作ったフォルダと run が使う場所が別になり、規約フォルダが二重にできる)
    func testDefaultWorkspaceNameMatchesResolver() {
        let projectRoot = URL(fileURLWithPath: "/tmp/p")
        XCTAssertEqual(
            ProfileResolver.resolveWorkspaceRoot(
                declared: nil, override: nil, projectRoot: projectRoot,
                repoRoot: URL(fileURLWithPath: "/tmp")).lastPathComponent,
            WorkspaceScaffold.defaultRootName)
    }

    // MARK: - 受け手のセットアップスキル(規約位置)

    /// 置き場所は `AgentIntegration.skillsDirectory` の1箇所。**規約位置を直書きしない**
    func testRecipientSkillGoesToTheConventionalLocation() throws {
        let written = try ProjectScaffold.writeRecipientSkill(
            packageRoot: packageRoot, projectName: "Demo")
        XCTAssertEqual(written, ["\(AgentIntegration.skillsDirectory)/fleetest-setup/SKILL.md"])
        let body = try String(contentsOf: packageRoot.appendingPathComponent(written[0]),
                              encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("---\nname: fleetest-setup\n"),
                      "frontmatter が SKILL.md の形になっていない")
    }

    // MARK: - .claude/settings.json(Bash 承認を減らす許可リスト)

    private var claudeSettingsURL: URL {
        packageRoot.appendingPathComponent(".claude/settings.json")
    }

    /// 許可するのは fleetest 由来のコマンドだけ。汎用の全許可を書かない
    func testClaudeSettingsAddsOnlyFleetestEntries() throws {
        let added = try ProjectScaffold.writeClaudeSettings(packageRoot: packageRoot,
                                                            toolRoot: "/tools/ft")
        XCTAssertFalse(added.isEmpty)
        for entry in added {
            XCTAssertTrue(entry.hasPrefix("Bash("), "許可するのは Bash のみ: \(entry)")
            XCTAssertNotEqual(entry, "Bash(*)")
            // 許可範囲はツールのクローン配下か fleetest CLI か読み取り専用の simctl list に限る
            XCTAssertTrue(entry.contains("/tools/ft") || entry.contains("fleetest")
                          || entry.contains("xcrun simctl list"),
                          "fleetest 由来のコマンドだけを許可する: \(entry)")
        }
    }

    /// 更新系スクリプトも許可対象に入れる(入っていないと更新のたびに承認が増える。
    /// 既存の受け手には `fleetest api ensure-settings` = install.sh 経由で後から届く)
    func testClaudeSettingsAllowsUpdateScripts() throws {
        let added = try ProjectScaffold.writeClaudeSettings(packageRoot: packageRoot,
                                                            toolRoot: "/tools/ft")
        for script in ["preflight.sh", "install.sh", "update.sh", "update-check.sh"] {
            XCTAssertTrue(added.contains("Bash(bash /tools/ft/Scripts/\(script):*)"),
                          "\(script) が許可リストに無い")
        }
    }

    /// 既に一部だけ入っている受け手(旧版で init した)に、足りないものだけが追加される
    func testClaudeSettingsAddsOnlyMissingEntries() throws {
        try FileManager.default.createDirectory(
            at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Bash(bash /tools/ft/Scripts/install.sh:*)"]}}"#
            .write(to: claudeSettingsURL, atomically: true, encoding: .utf8)

        let added = try ProjectScaffold.writeClaudeSettings(packageRoot: packageRoot,
                                                            toolRoot: "/tools/ft")
        XCTAssertFalse(added.contains("Bash(bash /tools/ft/Scripts/install.sh:*)"), "既存は再追加しない")
        XCTAssertTrue(added.contains("Bash(bash /tools/ft/Scripts/update.sh:*)"))

        let data = try Data(contentsOf: claudeSettingsURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try XCTUnwrap(object["permissions"] as? [String: Any])
        let allow = try XCTUnwrap(permissions["allow"] as? [String])
        XCTAssertEqual(allow.filter { $0.contains("install.sh") }.count, 1, "重複しない")
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

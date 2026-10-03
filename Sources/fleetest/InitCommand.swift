// fleetest init: 受け手のパッケージを scaffold する(外部パッケージ構成)。
// カレントディレクトリに、fleetest を SPM 依存として引く Package.swift(空マーカー区間つき)を書き、
// 直後に最初のテストプロジェクトを createAndRegister(external 自動判定で .product 参照スタンザ)する。
// --no-project ではプロジェクトを作らず空の TestProjects/ だけ置く(プロジェクトは /fleetest-profiles か
// VSCode 拡張が `default` で後から作る)。
// 対向: Sources/FTCore/ProjectScaffold.externalManifest / PackageManifestEditor(external モード)。

import ArgumentParser
import Foundation
import FTCore

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create the consumer package"
            + " (a Package.swift that depends on fleetest via SPM, plus a first test project)")

    @Flag(name: .customLong("no-project"),
          help: "Do not create a test project (only the package and an empty TestProjects/; the project is created later, e.g. by /fleetest-profiles)")
    var noProject = false

    @Option(help: "Project name (becomes an SPM target name; defaults to one derived from the current directory)")
    var name: String?

    @Option(name: .customLong("app-id"), help: "Bundle ID / package name of the app under test")
    var appID: String?

    @Option(name: .customLong("fleetest-path"),
            help: "Path to a local foundation-tester (depends via .package(path:); for PoCs)")
    var fleetestPath: String?

    @Option(name: .customLong("fleetest-url"),
            help: "git URL of foundation-tester (depends via .package(url:branch:); mutually exclusive with --fleetest-path)")
    var fleetestURL: String?

    // 配布口は main の1本(docs/releasing.md)。タグを指す `from:` 依存は案内しない導線だったので
    // 落とし、git 依存はブランチ追従だけにしてある
    @Option(name: .customLong("fleetest-branch"),
            help: "Branch to track for the git dependency (used with --fleetest-url; default main)")
    var fleetestBranch: String = "main"

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifest = cwd.appendingPathComponent("Package.swift")
        guard !FileManager.default.fileExists(atPath: manifest.path) else {
            throw ValidationError("Package.swift already exists: \(manifest.path)"
                + " (run this in an empty directory)")
        }

        if noProject {
            let conflicting = [name != nil ? "--name" : nil,
                               appID != nil ? "--app-id" : nil].compactMap { $0 }
            guard conflicting.isEmpty else {
                throw ValidationError("--no-project cannot be combined with "
                    + conflicting.joined(separator: " / "))
            }
        }

        let packageName = cwd.lastPathComponent
        let projectName = name ?? Self.sanitizedName(packageName)
        guard noProject || ProjectStore.isValidName(projectName) else {
            throw ValidationError("invalid project name: \(projectName)"
                + " (letters, digits, _ and - only; specify one with --name)")
        }
        let resolvedAppID = appID ?? ProjectScaffold.placeholderAppID
        guard Self.isValidAppID(resolvedAppID) else {
            throw ValidationError("invalid --app-id: \(resolvedAppID)"
                + " (bundle ID / package name: letters, digits, '.', '_' and '-' only)")
        }

        let dependencyLine: String
        if let fleetestPath {
            let abs = URL(fileURLWithPath: fleetestPath, relativeTo: cwd).standardizedFileURL.path
            dependencyLine = #".package(path: "\#(abs)"),"#
        } else if let fleetestURL {
            dependencyLine = #".package(url: "\#(fleetestURL)", branch: "\#(fleetestBranch)"),"#
        } else {
            throw ValidationError("specify either --fleetest-path or --fleetest-url")
        }

        try ProjectScaffold.externalManifest(packageName: packageName, dependencyLine: dependencyLine)
            .write(to: manifest, atomically: true, encoding: .utf8)

        do {
            var project: TestProject?
            if noProject {
                try ProjectScaffold.ensureEmptyProjectsDirectory(repoRoot: cwd)
            } else {
                project = try ProjectScaffold.createAndRegister(
                    name: projectName, app: resolvedAppID, repoRoot: cwd)
            }
            let scaffoldedProjectName: String? = noProject ? nil : projectName
            // 受け手が自分のプロジェクトをエージェントで開いて fleetest-setup で残りを駆動できるように
            try ProjectScaffold.writeRecipientSkill(
                packageRoot: cwd, projectName: scaffoldedProjectName)
            // VSCode 拡張が fleetest.project/fleetest.binaryPath を手動設定なしで解決できるように
            let wroteVSCodeSettings = try ProjectScaffold.writeVSCodeSettings(
                packageRoot: cwd, fleetestPath: fleetestPath, projectName: scaffoldedProjectName)
            // fleetest のコマンドを毎回 Bash 承認させないための許可リスト(fleetest 由来のみ)。
            // 失敗しても init は続行する
            var addedClaudeAllows: [String] = []
            do {
                addedClaudeAllows = try ProjectScaffold.writeClaudeSettings(
                    packageRoot: cwd, toolRoot: fleetestPath.map {
                        URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL.path
                    })
            } catch {
                ConsoleOut.err("⚠️ Failed to prepare .claude/settings.json: "
                    + "\(error.localizedDescription)")
            }
            // .build/(~1.7GB)等が git status の未追跡ノイズにならないように。失敗しても init は続行
            var addedGitignoreEntries: [String] = []
            do {
                addedGitignoreEntries = try ProjectScaffold.ensureGitignore(packageRoot: cwd)
            } catch {
                let warning = "⚠️ Failed to prepare .gitignore automatically (add .build/ etc. by hand): "
                    + "\(error.localizedDescription)"
                ConsoleOut.err(warning)
            }
            ConsoleOut.out("✅ Created the consumer package: \(packageName)")
            ConsoleOut.out("   Dependency: \(dependencyLine)")
            if let project {
                ConsoleOut.out("   Project:    TestProjects/\(projectName)/ (add .swift files with @TestClass under scenarios/)")
                ConsoleOut.out("   Profiles:   none yet; create them with /fleetest-profiles (`fleetest profile setup`)")
                ConsoleOut.out("   Build:      swift build --product \(project.productName)")
            } else {
                ConsoleOut.out("   Project:    none yet (empty TestProjects/); create one later with /fleetest-profiles"
                    + " or `fleetest project create default`")
            }
            if wroteVSCodeSettings {
                ConsoleOut.out(project == nil
                    ? "   VSCode ext: set fleetest.binaryPath in .vscode/settings.json automatically"
                    : "   VSCode ext: set fleetest.project/fleetest.binaryPath in .vscode/settings.json automatically")
            }
            if !addedClaudeAllows.isEmpty {
                ConsoleOut.out("   Claude Code: added fleetest command permissions to .claude/settings.json"
                      + " (to reduce approval prompts; delete them if unwanted)")
            }
            if !addedGitignoreEntries.isEmpty {
                ConsoleOut.out("   .gitignore: appended \(addedGitignoreEntries.joined(separator: " ")) (to keep .build/ etc. out of git noise)")
            }
            ConsoleOut.out("   \(AgentIntegration.displayName): open this folder and "
                  + "\(AgentIntegration.skillInvocationPrefix)fleetest-setup drives device setup "
                  + "through the first run")
        } catch {
            // マニフェストだけ書いて scaffold に失敗したら、中途半端な Package.swift を残さない
            try? FileManager.default.removeItem(at: manifest)
            throw error
        }
    }

    /// bundle ID / package name として妥当な文字だけを許す(`AndroidWebViewDOM.probeCommand` と
    /// 同じ許容集合)。値は install/launch や profiles/apps/*.json・雛形シナリオの `@TestClass(app:)` /
    /// `appIs(...)` へそのまま入るので、注入にはならなくても分かりにくい後段の失敗になる前に弾く
    static func isValidAppID(_ value: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !value.isEmpty && value.allSatisfy { allowed.contains($0) }
    }

    /// ディレクトリ名を SPM ターゲット名(`^[A-Za-z0-9_][A-Za-z0-9_-]*$`)へ寄せる
    static func sanitizedName(_ raw: String) -> String {
        var s = String(raw.map { ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        if let first = s.first, !(first.isLetter || first.isNumber || first == "_") {
            s = "_" + s
        }
        return s.isEmpty ? "App" : s
    }
}

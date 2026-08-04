// ftester init: 受け手のパッケージを scaffold する(外部パッケージ構成)。
// カレントディレクトリに、ftester を SPM 依存として引く Package.swift(空マーカー区間つき)を書き、
// 直後に最初のテストプロジェクトを createAndRegister(external 自動判定で .product 参照スタンザ)する。
// 対向: Sources/FTCore/ProjectScaffold.externalManifest / PackageManifestEditor(external モード)。

import ArgumentParser
import Foundation
import FTCore

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create the consumer package"
            + " (a Package.swift that depends on ftester via SPM, plus a first test project)")

    @Option(help: "Project name (becomes an SPM target name; defaults to one derived from the current directory)")
    var name: String?

    @Option(help: "Bundle ID / package name of the app under test")
    var app: String = "com.example.myapp"

    @Option(help: "Which run profiles to scaffold: ios / android / both (default both)")
    var platform: String = "both"

    @Option(name: .customLong("ftester-path"),
            help: "Path to a local foundation-tester (depends via .package(path:); for PoCs)")
    var ftesterPath: String?

    @Option(name: .customLong("ftester-url"),
            help: "git URL of foundation-tester (depends via .package(url:from:); mutually exclusive with --ftester-path)")
    var ftesterURL: String?

    @Option(name: .customLong("ftester-version"),
            help: "Minimum version for the git dependency (used with --ftester-url; ignored when --ftester-branch is given)")
    var ftesterVersion: String = "0.0.1"

    @Option(name: .customLong("ftester-branch"),
            help: "Track a branch instead of a tag for the git dependency (used with --ftester-url; for testing before a tag exists)")
    var ftesterBranch: String?

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifest = cwd.appendingPathComponent("Package.swift")
        guard !FileManager.default.fileExists(atPath: manifest.path) else {
            throw ValidationError("Package.swift already exists: \(manifest.path)"
                + " (run this in an empty directory)")
        }

        let packageName = cwd.lastPathComponent
        let projectName = name ?? Self.sanitizedName(packageName)
        guard ProjectStore.isValidName(projectName) else {
            throw ValidationError("invalid project name: \(projectName)"
                + " (letters, digits, _ and - only; specify one with --name)")
        }

        let dependencyLine: String
        if let ftesterPath {
            let abs = URL(fileURLWithPath: ftesterPath, relativeTo: cwd).standardizedFileURL.path
            dependencyLine = #".package(path: "\#(abs)"),"#
        } else if let ftesterURL {
            dependencyLine = ftesterBranch.map {
                #".package(url: "\#(ftesterURL)", branch: "\#($0)"),"#
            } ?? #".package(url: "\#(ftesterURL)", from: "\#(ftesterVersion)"),"#
        } else {
            throw ValidationError("specify either --ftester-path or --ftester-url")
        }

        try ProjectScaffold.externalManifest(packageName: packageName, dependencyLine: dependencyLine)
            .write(to: manifest, atomically: true, encoding: .utf8)

        do {
            let project = try ProjectScaffold.createAndRegister(
                name: projectName, app: app, repoRoot: cwd,
                platforms: try Self.platforms(from: platform))
            // 受け手が自分のプロジェクトを Claude Code で開いて /ftester-setup で残りを駆動できるように
            try ProjectScaffold.writeRecipientSkill(packageRoot: cwd, projectName: projectName)
            // VSCode 拡張が ftester.project/ftester.binaryPath を手動設定なしで解決できるように
            let wroteVSCodeSettings = try ProjectScaffold.writeVSCodeSettings(
                packageRoot: cwd, ftesterPath: ftesterPath, projectName: projectName)
            // ftester のコマンドを毎回 Bash 承認させないための許可リスト(ftester 由来のみ)。
            // 失敗しても init は続行する
            var addedClaudeAllows: [String] = []
            do {
                addedClaudeAllows = try ProjectScaffold.writeClaudeSettings(
                    packageRoot: cwd, toolRoot: ftesterPath.map {
                        URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL.path
                    })
            } catch {
                FileHandle.standardError.write(Data(("⚠️ Failed to prepare .claude/settings.json: "
                    + "\(error.localizedDescription)\n").utf8))
            }
            // .build/(~1.7GB)等が git status の未追跡ノイズにならないように。失敗しても init は続行
            var addedGitignoreEntries: [String] = []
            do {
                addedGitignoreEntries = try ProjectScaffold.ensureGitignore(packageRoot: cwd)
            } catch {
                let warning = "⚠️ Failed to prepare .gitignore automatically (add .build/ etc. by hand): "
                    + "\(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
            print("✅ Created the consumer package: \(packageName)")
            print("   Dependency: \(dependencyLine)")
            print("   Project:    TestProjects/\(projectName)/ (add .swift files with @TestClass under scenarios/)")
            print("   App config: point appPath in TestProjects/\(projectName)/profiles/apps/ at your own build")
            print("   Build:      swift build --product \(project.productName)")
            print("   Run:        ftester run --project \(projectName) --profile ios")
            if wroteVSCodeSettings {
                print("   VSCode ext: set ftester.project/ftester.binaryPath in .vscode/settings.json automatically")
            }
            if !addedClaudeAllows.isEmpty {
                print("   Claude Code: added ftester command permissions to .claude/settings.json"
                      + " (to reduce approval prompts; delete them if unwanted)")
            }
            if !addedGitignoreEntries.isEmpty {
                print("   .gitignore: appended \(addedGitignoreEntries.joined(separator: " ")) (to keep .build/ etc. out of git noise)")
            }
            print("   Claude Code: open this folder and /ftester-setup drives device setup through the first run")
        } catch {
            // マニフェストだけ書いて scaffold に失敗したら、中途半端な Package.swift を残さない
            try? FileManager.default.removeItem(at: manifest)
            throw error
        }
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

extension InitCommand {
    /// --platform の値を scaffold へ渡す配列にする(both = 両方)
    static func platforms(from value: String) throws -> [String] {
        switch value {
        case "both": return ["ios", "android"]
        case "ios", "android": return [value]
        default: throw ValidationError("--platform must be one of ios / android / both: \(value)")
        }
    }
}

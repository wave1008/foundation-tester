// テストプロジェクト・マシン名・実行プロファイルの管理 CLI。
//   ftester project create/list/sync … TestProjects/<name>/ と Package.swift マーカー区間の管理
//   ftester machine set/show         … このマシンの名前(~/.config/ftester/config.json)
//   ftester profile list             … 実行プロファイルと部品プロファイルの一覧・整合チェック

import ArgumentParser
import Foundation
import FTCore

/// リポジトリルート(Package.swift を持つディレクトリ)
func ftesterRepoRoot() throws -> URL {
    guard let root = ScenarioHost.packageRoot() else {
        throw ValidationError("Package.swift not found (run this inside the repository)")
    }
    return root
}

// MARK: - project

struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Manage test projects (TestProjects/<name>/)",
        subcommands: [Create.self, List.self, Sync.self, LintSelectors.self])

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scaffold a test project and register it in Package.swift")

        @Argument(help: "Project name (becomes an SPM target name, so only letters, digits, _ and -)")
        var name: String

        @Option(help: "Bundle ID / package name of the app under test")
        var app: String = "com.example.myapp"

        @Option(help: "Which run profiles to scaffold: ios / android / both (default both)")
        var platform: String = "both"

        func run() async throws {
            let root = try ftesterRepoRoot()
            let project = try ProjectScaffold.createAndRegister(
                name: name, app: app, repoRoot: root,
                platforms: try InitCommand.platforms(from: platform))

            print("✅ Created the project: TestProjects/\(name)/")
            print("   Scenarios:  TestProjects/\(name)/scenarios/ (add .swift files with @TestClass)")
            print("   Profiles:   TestProjects/\(name)/profiles/{apps,machines,runs}/")
            print("   Build:      swift build --product \(project.productName)")
            print("   Run:        ftester run --project \(name) --profile ios")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List test projects and whether they are registered in Package.swift")

        func run() async throws {
            let root = try ftesterRepoRoot()
            let projects = ProjectStore.all(repoRoot: root)
            guard !projects.isEmpty else {
                print("No projects (create one with: ftester project create <name>)")
                return
            }
            let registered = (try? PackageManifestEditor.registeredProjects(
                manifestURL: root.appendingPathComponent("Package.swift"))) ?? []
            let defaultName = LocalConfig.load().defaultProject
            for project in projects {
                var notes: [String] = []
                if !registered.contains(project.name) {
                    notes.append("⚠️ not registered in Package.swift (run: ftester project sync)")
                }
                if project.name == defaultName { notes.append("default") }
                let runs = ProfileResolver.runProfileNames(project: project)
                let runsText = runs.isEmpty ? "no run profiles"
                                            : "runs: \(runs.joined(separator: ", "))"
                print("・ \(project.name)(\(runsText))"
                      + (notes.isEmpty ? "" : " — \(notes.joined(separator: " / "))"))
            }
            for name in registered where !projects.contains(where: { $0.name == name }) {
                print("・ \(name) — ⚠️ registered in Package.swift but TestProjects/\(name)/ does not exist"
                      + " (remove it with: ftester project sync)")
            }
        }
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Regenerate the marker section of Package.swift from a scan of TestProjects/"
                + " (to resync after a manual copy or a git pull)")

        func run() async throws {
            let root = try ftesterRepoRoot()
            try syncManifest(repoRoot: root, verbose: true)
        }
    }

    struct LintSelectors: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "lint-selectors",
            abstract: "Check for drift between the #id selectors in scenarios and the contract (ui-contract.md)"
                + " (only #id; labels are excluded because localisation makes them vary)")

        @Option(help: "Test project name (resolved the same way as in the other commands)")
        var project: String?

        @Option(help: "Path to the contract markdown (defaults to TestProjects/<name>/docs/ui-contract.md; an error if missing)")
        var contract: String?

        func run() async throws {
            let testProject = try ScenarioHost.project(named: project)

            let contractURL = contract.map { URL(fileURLWithPath: $0) }
                ?? testProject.docsDir.appendingPathComponent("ui-contract.md")
            guard FileManager.default.fileExists(atPath: contractURL.path) else {
                throw ValidationError(
                    "contract file not found (\(contractURL.path)). "
                    + "Point at the contract markdown with --contract")
            }
            guard let contractText = try? String(contentsOf: contractURL, encoding: .utf8) else {
                throw ValidationError("failed to read the contract file: \(contractURL.path)")
            }

            let files = ScenarioFolders.swiftFiles(under: testProject.scenariosDir)
            var occurrences: [(file: URL, id: String, line: Int)] = []
            for file in files {
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for hit in SelectorLint.selectorsInSwiftSource(source) {
                    occurrences.append((file: file, id: hit.id, line: hit.line))
                }
            }

            let usedIDs = Set(occurrences.map(\.id))
            let contractIDs = SelectorLint.idsInContract(contractText)
            let (unknown, unusedContractIDs) = SelectorLint.drift(
                usedIDs: usedIDs, contractIDs: contractIDs)

            let scenariosBase = testProject.scenariosDir.standardizedFileURL.path + "/"
            func relativePath(_ url: URL) -> String {
                let path = url.standardizedFileURL.path
                return path.hasPrefix(scenariosBase) ? String(path.dropFirst(scenariosBase.count))
                                                       : path
            }

            if !unknown.isEmpty {
                print("❌ Found #id selectors that are not in the contract:")
                let hits = occurrences
                    .filter { unknown.contains($0.id) }
                    .sorted { $0.file.path != $1.file.path ? $0.file.path < $1.file.path
                                                             : $0.line < $1.line }
                for hit in hits {
                    print("   \(relativePath(hit.file)):\(hit.line) #\(hit.id)")
                }
            }

            if !unusedContractIDs.isEmpty {
                let sorted = unusedContractIDs.sorted()
                print("ℹ️ #ids in the contract but unused by scenarios (\(sorted.count)): "
                      + sorted.map { "#\($0)" }.joined(separator: ", "))
            }

            guard unknown.isEmpty else {
                throw ExitCode(1)
            }
            print("✅ No selector drift (\(files.count) file(s) / \(usedIDs.count) selector(s)"
                  + " / \(contractIDs.count) contract id(s))")
        }
    }

    /// TestProjects/ の走査結果でマーカー区間を全置換する
    fileprivate static func syncManifest(repoRoot: URL, verbose: Bool = false) throws {
        let manifest = repoRoot.appendingPathComponent("Package.swift")
        let names = ProjectStore.all(repoRoot: repoRoot).map(\.name)
        let before = (try? PackageManifestEditor.registeredProjects(manifestURL: manifest)) ?? []
        try PackageManifestEditor.updateProjects(
            manifestURL: manifest, projectNames: names,
            external: ProjectScaffold.isExternalPackage(repoRoot: repoRoot))
        if verbose {
            let added = names.filter { !before.contains($0) }
            let removed = before.filter { !names.contains($0) }
            if added.isEmpty && removed.isEmpty {
                print("✅ Package.swift is up to date (\(names.count) project(s))")
            } else {
                if !added.isEmpty { print("✅ Registered: \(added.joined(separator: ", "))") }
                if !removed.isEmpty { print("✅ Removed: \(removed.joined(separator: ", "))") }
            }
        }
    }
}

// MARK: - machine

struct MachineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machine",
        abstract: "Manage this machine's name (the key that selects profiles/machines/<name>.json)",
        subcommands: [SetName.self, Show.self])

    struct SetName: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Register this machine's name")

        @Argument(help: "Machine name (e.g. \"M2 Ultra(192GB)\")")
        var name: String

        func run() async throws {
            var config = LocalConfig.load()
            config.machineName = name
            try config.save()
            print("✅ Registered this machine's name: \(name)")
            print("   Stored at: \(LocalConfig.url().path)")
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show", abstract: "Show the current machine name and how it resolves")

        @Option(help: "Test project name (used to check whether a machine profile exists)")
        var project: String?

        func run() async throws {
            let env = ProcessInfo.processInfo.environment["FT_MACHINE"]
            let config = LocalConfig.load()
            if let env, !env.isEmpty {
                print("Machine name: \(env) (from the FT_MACHINE environment variable)")
            } else if let name = config.machineName {
                print("Machine name: \(name)")
            } else {
                print("Machine name: unregistered (register with: ftester machine set \"<name>\")")
            }
            print("Config file: \(LocalConfig.url().path)")

            guard let testProject = try? ScenarioHost.project(named: project) else { return }
            let machines = ProfileResolver.machineNames(project: testProject)
            let current = LocalConfig.currentMachineName()
            print("Machine profiles of project \(testProject.name): "
                  + (machines.isEmpty ? "none" : machines.joined(separator: ", ")))
            if let current {
                print(machines.contains(current)
                      ? "→ The \(current) profile applies"
                      : "→ ⚠️ No profile for \(current)"
                        + " (create profiles/machines/\(current).json)")
            }
        }
    }
}

// MARK: - profile

struct ProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Create, list and validate profiles (apps/machines/runs)",
        subcommands: [ProfileSetupCommand.self, List.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List run profiles and their component profiles, and show how they resolve on this machine")

        @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        func run() async throws {
            let testProject = try ScenarioHost.project(named: project)
            print("Project: \(testProject.name)")
            print("Apps:     \(list(ProfileResolver.appProfileNames(project: testProject)))")
            print("Machines: \(list(ProfileResolver.machineNames(project: testProject)))")

            let runs = ProfileResolver.runProfileNames(project: testProject)
            guard !runs.isEmpty else {
                print("No run profiles (add .json files under profiles/runs/)")
                return
            }

            let ambientMachine = try? ProfileResolver.determineMachine(
                project: testProject, registered: LocalConfig.currentMachineName())
            if let ambientMachine {
                print("Machine name: \(ambientMachine.name)\(ambientMachine.auto ? " (picked automatically)" : "")")
            } else {
                print("Machine name: undecided (resolution checks are skipped for run profiles without an "
                    + "explicit machine. Register one with ftester machine set, or set machine "
                    + "in the run profile)")
            }

            print("Run profiles:")
            for run in runs {
                do {
                    // 実行プロファイル自身の machine 指定があれば最優先する(determineMachine の
                    // runProfileName 引数。ambientMachine が未決定でもこちらは解決できることがある)
                    let machine = try ProfileResolver.determineMachine(
                        project: testProject, registered: LocalConfig.currentMachineName(),
                        runProfileName: run)
                    let resolved = try ProfileResolver.resolve(
                        project: testProject, runName: run, machineName: machine.name)
                    let devices = resolved.devices
                        .map { "\($0.name)(\($0.platform))" }
                        .joined(separator: ", ")
                    // マシンプロファイルの host はローカルのときだけ黙る(2026-08-17。ユーザー決定:
                    // マシンプロファイルで実行プロファイル経由のリモートホスト指定を表せるようにした)
                    let hostSuffix = resolved.machineHost.map { " (\($0))" } ?? ""
                    print("・ \(run) — \(resolved.appName) / \(devices) @ \(resolved.machineName)\(hostSuffix)")
                    for warning in resolved.warnings { print("    ⚠️ \(warning)") }
                } catch ProfileError.machineUndetermined {
                    print("・ \(run) — skipped the resolution check because the machine name is undecided")
                } catch {
                    print("・ \(run) — ❌ \(error.localizedDescription)")
                }
            }
        }

        private func list(_ names: [String]) -> String {
            names.isEmpty ? "none" : names.joined(separator: ", ")
        }
    }
}

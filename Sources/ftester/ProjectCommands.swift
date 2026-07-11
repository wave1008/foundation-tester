// テストプロジェクト・マシン名・実行プロファイルの管理 CLI。
//   ftester project create/list/sync … Projects/<name>/ と Package.swift マーカー区間の管理
//   ftester machine set/show         … このマシンの名前(~/.config/ftester/config.json)
//   ftester profile list             … 実行プロファイルと部品プロファイルの一覧・整合チェック

import ArgumentParser
import Foundation
import FTCore

/// リポジトリルート(Package.swift を持つディレクトリ)
func ftesterRepoRoot() throws -> URL {
    guard let root = ScenarioHost.packageRoot() else {
        throw ValidationError("Package.swift が見つかりません(リポジトリ内で実行してください)")
    }
    return root
}

// MARK: - project

struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "テストプロジェクト(Projects/<name>/)の管理",
        subcommands: [Create.self, List.self, Sync.self])

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "テストプロジェクトの雛形を作成して Package.swift に登録する")

        @Argument(help: "プロジェクト名(SPM ターゲット名になるため英数字・_・- のみ)")
        var name: String

        @Option(help: "対象アプリの bundle ID / パッケージ名")
        var app: String = "com.example.myapp"

        func run() async throws {
            let root = try ftesterRepoRoot()
            let project = try ProjectScaffold.createAndRegister(
                name: name, app: app, repoRoot: root,
                machineName: LocalConfig.currentMachineName())

            print("✅ プロジェクトを作成しました: Projects/\(name)/")
            print("   シナリオ置き場: Projects/\(name)/Scenarios/(@TestClass の .swift を追加)")
            print("   プロファイル:   Projects/\(name)/profiles/{apps,machines,runs}/")
            print("   ビルド:         swift build --product \(project.productName)")
            print("   実行:           ftester run --project \(name) --profile ios")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "テストプロジェクトの一覧と Package.swift 登録状態を表示する")

        func run() async throws {
            let root = try ftesterRepoRoot()
            let projects = ProjectStore.all(repoRoot: root)
            guard !projects.isEmpty else {
                print("プロジェクトがありません(ftester project create <name> で作成)")
                return
            }
            let registered = (try? PackageManifestEditor.registeredProjects(
                manifestURL: root.appendingPathComponent("Package.swift"))) ?? []
            let defaultName = LocalConfig.load().defaultProject
            for project in projects {
                var notes: [String] = []
                if !registered.contains(project.name) {
                    notes.append("⚠️ Package.swift 未登録(ftester project sync を実行)")
                }
                if project.name == defaultName { notes.append("既定") }
                let runs = ProfileResolver.runProfileNames(project: project)
                let runsText = runs.isEmpty ? "実行プロファイルなし"
                                            : "runs: \(runs.joined(separator: ", "))"
                print("・ \(project.name)(\(runsText))"
                      + (notes.isEmpty ? "" : " — \(notes.joined(separator: " / "))"))
            }
            for name in registered where !projects.contains(where: { $0.name == name }) {
                print("・ \(name) — ⚠️ Package.swift に登録済みだが Projects/\(name)/ がありません"
                      + "(ftester project sync で除去)")
            }
        }
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Projects/ の走査結果で Package.swift のマーカー区間を再生成する"
                + "(手動コピーや git pull 後の整合用)")

        func run() async throws {
            let root = try ftesterRepoRoot()
            try syncManifest(repoRoot: root, verbose: true)
        }
    }

    /// Projects/ の走査結果でマーカー区間を全置換する
    fileprivate static func syncManifest(repoRoot: URL, verbose: Bool = false) throws {
        let manifest = repoRoot.appendingPathComponent("Package.swift")
        let names = ProjectStore.all(repoRoot: repoRoot).map(\.name)
        let before = (try? PackageManifestEditor.registeredProjects(manifestURL: manifest)) ?? []
        try PackageManifestEditor.updateProjects(manifestURL: manifest, projectNames: names)
        if verbose {
            let added = names.filter { !before.contains($0) }
            let removed = before.filter { !names.contains($0) }
            if added.isEmpty && removed.isEmpty {
                print("✅ Package.swift は最新です(\(names.count) プロジェクト)")
            } else {
                if !added.isEmpty { print("✅ 登録: \(added.joined(separator: ", "))") }
                if !removed.isEmpty { print("✅ 除去: \(removed.joined(separator: ", "))") }
            }
        }
    }
}

// MARK: - machine

struct MachineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machine",
        abstract: "このマシンの名前(profiles/machines/<マシン名>.json の選択キー)を管理する",
        subcommands: [SetName.self, Show.self])

    struct SetName: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "このマシンの名前を登録する")

        @Argument(help: "マシン名(例: \"M1 Max(64GB)\")")
        var name: String

        func run() async throws {
            var config = LocalConfig.load()
            config.machineName = name
            try config.save()
            print("✅ マシン名を登録しました: \(name)")
            print("   保存先: \(LocalConfig.url().path)")
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show", abstract: "現在のマシン名と適用状態を表示する")

        @Option(help: "テストプロジェクト名(マシンプロファイルの有無の確認用)")
        var project: String?

        func run() async throws {
            let env = ProcessInfo.processInfo.environment["FT_MACHINE"]
            let config = LocalConfig.load()
            if let env, !env.isEmpty {
                print("マシン名: \(env)(FT_MACHINE 環境変数)")
            } else if let name = config.machineName {
                print("マシン名: \(name)")
            } else {
                print("マシン名: 未登録(ftester machine set \"<マシン名>\" で登録)")
            }
            print("設定ファイル: \(LocalConfig.url().path)")

            guard let testProject = try? ScenarioHost.project(named: project) else { return }
            let machines = ProfileResolver.machineNames(project: testProject)
            let current = LocalConfig.currentMachineName()
            print("プロジェクト \(testProject.name) のマシンプロファイル: "
                  + (machines.isEmpty ? "なし" : machines.joined(separator: ", ")))
            if let current {
                print(machines.contains(current)
                      ? "→ \(current) のプロファイルが適用されます"
                      : "→ ⚠️ \(current) のプロファイルがありません"
                        + "(profiles/machines/\(current).json を作成してください)")
            }
        }
    }
}

// MARK: - profile

struct ProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "実行プロファイル(profiles/runs/)の一覧と整合チェック",
        subcommands: [List.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "実行プロファイルと部品プロファイルを一覧し、現在マシンでの解決結果を表示する")

        @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
        var project: String?

        func run() async throws {
            let testProject = try ScenarioHost.project(named: project)
            print("プロジェクト: \(testProject.name)")
            print("アプリ:   \(list(ProfileResolver.appProfileNames(project: testProject)))")
            print("マシン:   \(list(ProfileResolver.machineNames(project: testProject)))")

            let runs = ProfileResolver.runProfileNames(project: testProject)
            guard !runs.isEmpty else {
                print("実行プロファイルがありません(profiles/runs/ に .json を追加)")
                return
            }

            let ambientMachine = try? ProfileResolver.determineMachine(
                project: testProject, registered: LocalConfig.currentMachineName())
            if let ambientMachine {
                print("マシン名: \(ambientMachine.name)\(ambientMachine.auto ? "(自動採用)" : "")")
            } else {
                print("マシン名: 未決定(machine を明示指定していない実行プロファイルは解決チェック"
                    + "をスキップ。ftester machine set で登録するか、実行プロファイルに machine "
                    + "を指定してください)")
            }

            print("実行プロファイル:")
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
                    print("・ \(run) — \(resolved.appName) / \(devices) @ \(resolved.machineName)")
                    for warning in resolved.warnings { print("    ⚠️ \(warning)") }
                } catch ProfileError.machineUndetermined {
                    print("・ \(run) — マシン名が未決定のため解決チェックをスキップしました")
                } catch {
                    print("・ \(run) — ❌ \(error.localizedDescription)")
                }
            }
        }

        private func list(_ names: [String]) -> String {
            names.isEmpty ? "なし" : names.joined(separator: ", ")
        }
    }
}

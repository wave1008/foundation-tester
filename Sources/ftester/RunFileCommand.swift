// ftester run-file: Package.swift への登録(ftester project create/sync)なしに .swift シナリオを
// 1 本だけ実行する。実行エンジンは通常の run と完全に同一 —
// 対象プロジェクトの scenarios/_runfile/ へコピーして SPM ターゲットに混ぜ、
// あとは RunScenarios にそのまま委譲する(ビルド・プロファイル・レポート・ヒールを再利用)。
//
// _runfile/ は実行の前後で必ず消す。SIGKILL 等で残骸が出た場合、次の run-file の開始時掃除で
// 消えるまではそのプロジェクトの通常 run にも混ざる(残骸は .gitignore 済み)。

import ArgumentParser
import Foundation
import FTBridgeClient
import FTCore

struct RunFileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-file",
        abstract: "Run an unregistered .swift scenario as-is (profiles are borrowed from an existing project)")

    /// ステージ先。scenarios/ 直下のサブフォルダは SPM ターゲットに含まれる(_disabled のみ除外)
    static let stageDirName = "_runfile"

    @Argument(help: "Scenario .swift file (pass several and they are compiled together as helpers)")
    var files: [String]

    @Option(help: "Test project to borrow profiles, reports and the heal cache from (defaults to the default project)")
    var project: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json)")
    var profile: String?

    @Option(name: .customLong("scenario"), parsing: .upToNextOption,
            help: "Scenario IDs to run (defaults to every @TestClass in the files)")
    var scenarios: [String] = []

    @Flag(help: "Allow FM-based locator self-healing")
    var heal = false

    @Option(name: .customLong("report-dir"), help: "Directory to write reports to")
    var reportDir: String?

    @Option(help: "Comma-separated bridge ports for running iOS scenarios in parallel")
    var ports: String?

    /// `@TestClass(app:)` を書かないシナリオを --profile 無しで回すときの逃げ道
    /// (--profile があればアプリプロファイルから解決されるので不要)
    @Option(name: .customLong("app"),
            help: "Default app (bundle ID / package name) for scenarios that declare no @TestClass(app:). Only needed without --profile")
    var app: String?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let urls = try files.map { path -> URL in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("file not found: \(url.path)")
            }
            guard url.pathExtension == "swift" else {
                throw ValidationError("scenarios must be .swift files: \(url.path)")
            }
            return url
        }
        guard !urls.isEmpty else { throw ValidationError("specify at least one file to run") }

        let repoRoot = try RepoRoot.find()
        let target: TestProject
        var stagedDir: URL?
        if let owner = Self.owningProject(of: urls, repoRoot: repoRoot),
           project == nil || project == owner.name {
            // 既に登録済みターゲットの中にあるファイルはコピーしない(重複クラス定義になる)
            target = owner
            print("→ Running as a registered scenario of \(owner.name)")
        } else {
            target = try ScenarioHost.project(named: project)
            stagedDir = try Self.stage(urls, into: target)
            print("→ Staging temporarily into \(target.name): "
                + urls.map(\.lastPathComponent).joined(separator: ", "))
        }
        defer {
            if let stagedDir { try? FileManager.default.removeItem(at: stagedDir) }
        }

        var selected = scenarios
        if selected.isEmpty {
            selected = try urls.flatMap { try Self.testClassNames(in: $0) }
            guard !selected.isEmpty else {
                throw ValidationError(
                    "no @TestClass found: "
                    + urls.map(\.lastPathComponent).joined(separator: ", "))
            }
        }

        // RunScenarios は引数の直接代入では組み立てられない(ArgumentParser のプロパティラッパは
        // parse を通らないと読み出しで落ちる)。引数列を作って parse させる
        var arguments = ["--project", target.name, "--scenario"] + selected
        if let profile { arguments += ["--profile", profile] }
        if heal { arguments.append("--heal") }
        if let reportDir { arguments += ["--report-dir", reportDir] }
        if let ports { arguments += ["--ports", ports] }
        if let app { arguments += ["--app", app] }
        arguments += ["--platform", driverOptions.platform, "--port", String(driverOptions.port)]
        if let serial = driverOptions.serial { arguments += ["--serial", serial] }
        let command = try RunScenarios.parse(arguments)
        try await command.run()
    }

    // MARK: - ステージング

    /// 全ファイルが同じプロジェクトの**コンパイル対象**に入っているならそのプロジェクト。
    /// _disabled/ は SPM ターゲットから除外されているので対象外(= ステージして実行できる)
    static func owningProject(of urls: [URL], repoRoot: URL) -> TestProject? {
        ProjectStore.all(repoRoot: repoRoot).first { project in
            urls.allSatisfy {
                isDescendant($0, of: project.scenariosDir)
                    && !isDescendant($0, of: project.disabledDir)
            }
        }
    }

    static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    @discardableResult
    static func stage(_ urls: [URL], into project: TestProject) throws -> URL {
        let dir = project.scenariosDir.appendingPathComponent(stageDirName)
        try? FileManager.default.removeItem(at: dir)  // 前回の残骸を掃除してから作る
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in urls {
            let destination = dir.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ValidationError("files with the same name cannot be run together: \(url.lastPathComponent)")
            }
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return dir
    }

    /// `@TestClass` が付いたクラス名を拾う(そのクラスの全 @Test が実行対象になる)。
    /// 属性とクラス宣言は行が離れることがあるので、@TestClass 以降の最初の class 宣言を対にする
    static func testClassNames(in url: URL) throws -> [String] {
        let source = try String(contentsOf: url, encoding: .utf8)
        var names: [String] = []
        var pendingAttribute = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            if line.contains("@TestClass") { pendingAttribute = true }
            guard pendingAttribute, let name = className(in: line) else { continue }
            names.append(name)
            pendingAttribute = false
        }
        return names
    }

    static func className(in line: String) -> String? {
        var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let classIndex = tokens.firstIndex(of: "class"), classIndex + 1 < tokens.count else {
            return nil
        }
        tokens = Array(tokens[(classIndex + 1)...])
        let name = tokens[0].prefix { $0 != ":" && $0 != "{" }
        return name.isEmpty ? nil : String(name)
    }
}

// fleetest run-file: Package.swift への登録(fleetest project create/sync)なしに .swift シナリオを
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

    /// `fleetest run` の `--set` をそのまま下流(RunScenarios.parse)へ中継する
    /// (キー・値の検証は RunScenarios.validate() に委ねる。二重に検証しない)
    @Option(name: .customLong("set"), help: "Override one field of the run profile document (repeatable): <key>=<value>, matching that key's type")
    var setOverrides: [String] = []

    @Option(name: .customLong("report-dir"), help: "Directory to write reports to")
    var reportDir: String?

    @Option(name: .customLong("port"), help: "Bridge port for running iOS scenarios in parallel. Repeatable (--port 8123 --port 8124)")
    var ports: [UInt16] = []

    /// `@TestClass(app:)` を書かないシナリオを --profile 無しで回すときの逃げ道
    /// (--profile があればアプリプロファイルから解決されるので不要)
    @Option(name: .customLong("app-id"),
            help: "Default app ID (bundle ID / package name) for scenarios that declare no @TestClass(app:). Only needed without --profile")
    var appID: String?

    // DriverOptions を @OptionGroup にすると --port が(上の repeatable --port と)二重宣言になるため、
    // platform/serial を自前で持つ(fleetest run 側と同じ形)
    @Option(help: "Target platform: ios / android (default ios)")
    var platform: String?

    @Option(help: "Android device serial (adb -s; defaults to the only connected device)")
    var serial: String?

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
            ConsoleOut.out("→ Running as a registered scenario of \(owner.name)")
        } else {
            target = try ScenarioHost.project(named: project)
            stagedDir = try Self.stage(urls, into: target)
            ConsoleOut.out("→ Staging temporarily into \(target.name): "
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
        for token in setOverrides { arguments += ["--set", token] }
        if let reportDir { arguments += ["--report-dir", reportDir] }
        for port in ports { arguments += ["--port", String(port)] }
        if let appID { arguments += ["--app-id", appID] }
        if let platform { arguments += ["--platform", platform] }
        if let serial { arguments += ["--serial", serial] }
        // RunScenarios.parse(arguments) は `run`(RunScenarios)自身の Usage を焼き込んだ形で
        // validate() の失敗を投げる(--profile/--port の併用等)。素通しすると「Usage: run <options> /
        // See 'run --help'」が出て run-file の呼び手を誤誘導する。メッセージ本文だけを
        // run-file 自身の throw として持ち直す(Fleetest.swift/ApiRunCommand.swift の
        // RunProfileSetOverride.parse 呼び出しと同じ規律)
        let command: RunScenarios
        do {
            command = try RunScenarios.parse(arguments)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
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

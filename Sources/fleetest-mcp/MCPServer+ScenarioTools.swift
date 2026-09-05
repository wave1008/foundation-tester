// MCPServer+ScenarioTools.swift
// シナリオ/プロジェクト系ツール(一覧・dry-run・実行・DSL索引)の実装。本体は MCPServer.swift

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// シナリオ一覧(自動ビルド込み。コンパイルエラーはそのまま返す=エージェントが直せる)
    func listScenarios(_ args: [String: Any]) throws -> [[String: Any]] {
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let scenarios = try ScenarioHost.list(project: project)
        let lines = scenarios.map { info in
            "\(info.id)"
                + (info.title.isEmpty ? "" : " — \(info.title)")
                + " (\(info.platform ?? "ios/android"), app: \(info.app ?? "from the run profile"))"
                + (info.deleted ? " [deleted @Deleted — excluded from bulk runs]"
                   : (info.draft ? " [draft @Draft — excluded from bulk runs]" : ""))
        }
        return text(lines.isEmpty
                    ? "No scenarios (add a @TestClass under TestProjects/\(project.name)/scenarios/)"
                    : "Project: \(project.name)\n" + lines.joined(separator: "\n"))
    }

    func listProjects() throws -> [[String: Any]] {
        guard let root = ScenarioHost.packageRoot() else {
            throw MCPError("Package.swift not found (run this inside the repository)")
        }
        let projects = ProjectStore.all(repoRoot: root)
        guard !projects.isEmpty else {
            return text("No projects (create one with: fleetest project create <name>)")
        }
        // 「この機械の登録名」は持たないので出さない(ProfileResolver.determineMachine の宣言)。
        // 使うマシンプロファイルは実行プロファイルの machine が決めるため、下の一覧で足りる
        var lines: [String] = []
        for project in projects {
            let runs = ProfileResolver.runProfileNames(project: project)
            let machines = ProfileResolver.machineNames(project: project)
            lines.append("\(project.name)"
                + " — run profiles: \(runs.isEmpty ? "none" : runs.joined(separator: ", "))"
                + " / machines: \(machines.isEmpty ? "none" : machines.joined(separator: ", "))")
        }
        return text(lines.joined(separator: "\n"))
    }

    /// dry-run(**デバイス不要**)。コンパイルの次・デバイス実行の前に挟む検証で、デバイスを
    /// 使わずにセレクタ構文エラー・到達しない scene・アサーション0の expectation を落とす。
    /// デバイスに触れないのでロケータが実在するかは分からない(それは ft_run_scenario の仕事)
    func dryRun(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let id = args["id"] as? String else { throw MCPError("id is required") }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let all = try ScenarioHost.list(project: project)
        guard let info = all.first(where: { $0.id == id })
            ?? all.first(where: { $0.id.hasPrefix(id + ".") }) else {
            throw MCPError(ScenarioFolders.notFoundMessage(
                id: id, available: all.map(\.id), scenariosDir: project.scenariosDir))
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-mcp-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var lines: [String] = []
        // dry-run は NullDriver 固定なので接続情報は使われない(platform だけが ios { } / android { } を分ける)
        let passed = await ScenarioHost.run(
            project: project, scenarioID: info.id,
            connection: DriverConnection(platform: info.platform ?? "ios"),
            // **`enabled: false`(= 子へ --no-fm)**。heal だけ切ると失敗のたびに triage が走り、
            // デバイスも画面も無いのに FM の直列化待ちを数秒払う(2026-08-12 実測)
            fm: FMConfig(enabled: false, heal: false), reportDir: tempDir.path,
            dryRun: true) { event in
                lines.append(contentsOf: ScenarioLogFormatter.lines(for: event))
            }
        // レポートは一時ディレクトリに書かれ、この関数を抜けると消える。
        // 案内すると開けないパスを渡すことになるので落とす(dry-run に証跡は要らない)
        lines.removeAll { $0.contains("→ report:") }
        lines.append(passed
            ? "✅ dry-run passed (no device was touched — selectors were only syntax-checked)"
            : "❌ dry-run failed")
        return text(lines.joined(separator: "\n"))
    }

    /// シナリオ実行(自動ビルド込み)。サブプロセス(fleetest-scenarios)に委譲する
    func runScenario(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let id = args["id"] as? String else { throw MCPError("id is required") }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let all = try ScenarioHost.list(project: project)
        guard let info = all.first(where: { $0.id == id })
            ?? all.first(where: { $0.id.hasPrefix(id + ".") }) else {
            throw MCPError(ScenarioFolders.notFoundMessage(
                id: id, available: all.map(\.id), scenariosDir: project.scenariosDir))
        }

        var fm = FMConfig(heal: args["heal"] as? Bool ?? false)
        var reportDir = project.reportsDir.path
        var defaultTimeout: Double?
        var connection: DriverConnection
        var prologue: [String] = []

        if let profileName = args["profile"] as? String {
            // 接続先はシナリオの platform に合う先頭デバイス。プロファイル自身の machine 指定が最優先
            let (_, resolved, target) = try await resolveProfileTarget(
                project: project, profileName: profileName,
                platformArg: info.platform, prologue: &prologue)
            fm = resolved.fm
            // heal 引数は master(fm.enabled)が有効な場合のみ ON にする override(未指定は resolved のまま)
            if let healArg = args["heal"] as? Bool {
                fm.heal = healArg && fm.enabled
            }
            reportDir = resolved.reportDir.path
            defaultTimeout = resolved.defaultTimeout
            switch target {
            case .ios(let provisioned, let iosApp):
                connection = ProfileWorkerFactory.iosConnection(device: provisioned, iosApp: iosApp)
            case .android(let serial, let deviceName):
                connection = DriverConnection(platform: "android", serial: serial, deviceName: deviceName)
            }
        } else {
            let platform = info.platform ?? (args["platform"] as? String ?? "ios")
            // **宛先の決め方は探索系(driver(_:))と同じにする**。片方だけ賢いと
            // 「ft_snapshot は繋がるのに ft_run_scenario だけ既定ポートで落ちる」になる
            connection = DriverConnection(
                platform: platform,
                port: platform == "ios"
                    ? try await Self.resolveIOSPort(explicit: (args["port"] as? Int).map(UInt16.init))
                    : nil,
                serial: platform == "android"
                    ? try Self.resolveAndroidSerial(explicit: args["serial"] as? String)
                    : nil)
        }

        var lines: [String] = prologue
        _ = await ScenarioHost.run(project: project, scenarioID: info.id,
                                   connection: connection,
                                   fm: fm, reportDir: reportDir,
                                   defaultTimeout: defaultTimeout) { event in
            lines.append(contentsOf: ScenarioLogFormatter.lines(for: event))
        }
        return text(lines.joined(separator: "\n"))
    }

    /// DSL コマンド索引(`fleetest api dsl-commands` と同じ出典 = Sources/FTCore/CommandIndex.swift)。
    /// **既定は名前と署名だけ**にする: 全 136 件の要約まで返すと 15KB 級になり、
    /// 「どのコマンドがあるか」を知りたいだけの呼び出しでコンテキストを食う。
    /// 要約が要るときは name / category で絞る
    func dslCommands(_ args: [String: Any]) -> [[String: Any]] {
        let category = args["category"] as? String
        let name = args["name"] as? String
        var commands = DSLCommandIndex.all
        if let category { commands = commands.filter { $0.category == category } }
        if let name { commands = commands.filter { $0.name == name } }
        guard !commands.isEmpty else {
            let categories = Set(DSLCommandIndex.all.map(\.category)).sorted()
            return text("no command matched. Categories: \(categories.joined(separator: ", "))."
                + " A name that is not in this index does not exist (it will not compile)")
        }
        let detailed = name != nil || category != nil
        let lines = commands.map { command in
            detailed ? "\(command.signature) — \(command.summary)" : command.signature
        }
        let header = detailed
            ? "\(commands.count) command(s)"
            : "\(commands.count) commands (pass category: or name: for summaries)."
                + " Chain-only: \(DSLCommandIndex.chainOnlyNames.sorted().joined(separator: ", "))"
        return text(([header] + lines).joined(separator: "\n"))
    }
}

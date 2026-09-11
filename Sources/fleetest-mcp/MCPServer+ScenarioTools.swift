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
    /// デバイスに触れないのでロケータが実在するかは分からない(それは ft_run_scenario の仕事)。
    /// クラス名なら CLI(`fleetest run`)と同じく非削除・非ドラフトの全シナリオを順に流す
    /// (`FTCore.ScenarioSelection.resolve` が唯一の定義元。`fleetest run` と共有する)
    func dryRun(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let id = args["id"] as? String else { throw MCPError("id is required") }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let all = try ScenarioHost.list(project: project)
        let infos: [ScenarioInfo]
        do {
            infos = try ScenarioSelection.resolve([id], from: all, scenariosDir: project.scenariosDir)
        } catch {
            throw MCPError(error.localizedDescription)
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-mcp-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // `#id` 台帳の照合は platform 別なので、宣言の無いシナリオは呼び出し側の platform 引数で
        // 決める(既定 ios)。宣言があるシナリオは常にそちらを使う(クラス展開で platform の
        // 混在する束を渡された場合でも、個々の宣言を尊重する)
        let fallbackPlatform = args["platform"] as? String ?? "ios"
        var lines: [String] = []
        var passedCount = 0
        var failedCount = 0
        for info in infos {
            // dry-run は NullDriver 固定なので接続情報は使われない(platform だけが ios { } / android { } を分ける)
            let passed = await ScenarioHost.run(
                project: project, scenarioID: info.id,
                connection: DriverConnection(platform: info.platform ?? fallbackPlatform),
                // **`enabled: false`(= 子へ --no-fm)**。heal だけ切ると失敗のたびに triage が走り、
                // デバイスも画面も無いのに FM の直列化待ちを数秒払う(2026-08-12 実測)
                settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false, heal: false)),
                reportDir: tempDir.path,
                dryRun: true) { event in
                    lines.append(contentsOf: ScenarioLogFormatter.lines(for: event))
                }
            if passed { passedCount += 1 } else { failedCount += 1 }
        }
        // レポートは一時ディレクトリに書かれ、この関数を抜けると消える。
        // 案内すると開けないパスを渡すことになるので落とす(dry-run に証跡は要らない)
        lines.removeAll { $0.contains("→ report:") }
        if infos.count > 1 {
            lines.append("\(passedCount) passed / \(failedCount) failed")
        } else {
            lines.append(passedCount == 1
                ? "✅ dry-run passed (no device was touched — selectors were only syntax-checked)"
                : "❌ dry-run failed")
        }
        return text(lines.joined(separator: "\n"))
    }

    /// `profile` と platform/port/serial/udid の併用を拒否する(profile がデバイスを決めるため。
    /// CLI の `--profile` + `--platform/--port/--serial` 併用エラーと同じ規律)。
    /// **args だけを見る純粋関数**(runScenario の先頭で呼ぶ)。udid は入口の
    /// `foldingUDIDIntoPort` が port へ畳むが、profile があっても畳み自体は起きる
    /// (`foldInRememberedDevice` だけが profile 有りで注入を止める)ので、畳まれた後も
    /// 元の "udid" キーは args に残っており、ここでも拾える
    static func profileConflict(_ args: [String: Any]) -> String? {
        guard args["profile"] != nil,
              args["platform"] != nil || args["port"] != nil
                || args["serial"] != nil || args["udid"] != nil
        else { return nil }
        return "profile cannot be combined with platform/port/serial/udid (the profile picks the device)"
    }

    /// シナリオ実行(自動ビルド込み)。サブプロセス(fleetest-scenarios)に委譲する。
    /// クラス名なら CLI(`fleetest run`)と同じく非削除・非ドラフトの全シナリオを1本の接続で
    /// 順に流す(`ScenarioSelection.resolve`)。**この run が行わないこと**は末尾の説明文参照
    /// (ft_run_scenario のツール定義。ProfileRunner.run/ApiRunCommand と違い setup/teardown
    /// スクリプト・アプリの install/update・home()・results/ への記録は無い)
    func runScenario(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let id = args["id"] as? String else { throw MCPError("id is required") }
        if let conflict = Self.profileConflict(args) { throw MCPError(conflict) }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let all = try ScenarioHost.list(project: project)
        let infos: [ScenarioInfo]
        do {
            infos = try ScenarioSelection.resolve([id], from: all, scenariosDir: project.scenariosDir)
        } catch {
            throw MCPError(error.localizedDescription)
        }

        var exec = ScenarioExecutionSettings(fm: FMConfig(heal: args["heal"] as? Bool ?? false))
        var reportDir = project.reportsDir.path
        var connection: DriverConnection
        var prologue: [String] = []
        // @TestClass(app:) 省略時の既定アプリ解決(FTCore.ScenarioAppResolution)に必要な3つ。
        // installHandler は渡さない(MCP の run はホスト install の RPC を持たない —
        // ft_install で入れ済みという前提。appPath は installApp() の引数省略時のフォールバックにも
        // 使われるが、install を呼ばないこの経路では uiFrameworkHint の判定材料としてのみ働く)
        var appPath: String?
        var appName: String?
        var appBundleID: String?

        if let profileName = args["profile"] as? String {
            // 接続先はシナリオ(クラス展開時は先頭本)の platform に合う先頭デバイス。
            // プロファイル自身の machine 指定が最優先。クラスが複数 platform に跨る束は
            // 想定していない(1回の ft_run_scenario 呼び出し = 1接続)
            let (platform, resolved, target) = try await resolveProfileTarget(
                project: project, profileName: profileName,
                platformArg: infos.first?.platform, prologue: &prologue)
            // **プロファイルの実行設定は丸ごと通す**(欄ごとに拾うと、足した欄が黙って落ちる)
            exec = ScenarioExecutionSettings(resolved)
            // heal 引数は master(fm.enabled)が有効な場合のみ ON にする override(未指定は resolved のまま)
            if let healArg = args["heal"] as? Bool {
                exec.fm.heal = healArg && exec.fm.enabled
            }
            reportDir = resolved.reportDir.path
            switch target {
            case .ios(let provisioned, let iosApp):
                connection = ProfileWorkerFactory.iosConnection(device: provisioned, iosApp: iosApp)
            case .android(let serial, let deviceName):
                connection = DriverConnection(platform: "android", serial: serial, deviceName: deviceName)
            }
            appBundleID = resolved.apps[platform]?.bundleID
            appName = resolved.appName
            appPath = resolved.apps[platform]?.packagePath(physical: connection.physical)
        } else {
            // CLI の profile 無し経路(`RunScenarios`/`ApiRunCommand`)と同じ基底
            // (`DeviceIndependentRunSettings.profileLessBase`)を環境へ適用する。resolveProfileTarget
            // 経由(profile あり)はそちらが `RunEnvironment.apply(resolved)` を呼ぶので、ここは
            // profile 無しのときだけ要る
            RunEnvironment.apply(DeviceIndependentRunSettings.resolve(DeviceIndependentRunSettings.profileLessBase))
            let platform = infos.first?.platform ?? (args["platform"] as? String ?? "ios")
            // **宛先の決め方は探索系(driver(_:))と同じにする**。片方だけ賢いと
            // 「ft_snapshot は繋がるのに ft_run_scenario だけ既定ポートで落ちる」になる。
            // **iOS の接続は CLI の `--port` 直指定と同じ PortDirectIOSTarget から作る** —— ポートだけ
            // 渡すと子プロセスは 127.0.0.1・physical=false で走り、LAN の実機は接続拒否、usb トンネルの
            // 実機は token 無しの 401 になる(2026-09-11 物理 iPhone 13 で 3/3。「クラッシュ」と誤帰属)
            if platform == "ios" {
                connection = PortDirectIOSTarget(
                    port: try await Self.resolveIOSPort(explicit: try Self.portArgument(args)))
                    .connection(simulatorUDID: (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            } else {
                connection = DriverConnection(
                    platform: platform,
                    serial: try Self.resolveAndroidSerial(explicit: args["serial"] as? String))
            }
        }

        var lines: [String] = prologue
        var passedCount = 0
        var failedCount = 0
        for info in infos {
            let passed = await ScenarioHost.run(project: project, scenarioID: info.id,
                                       connection: connection,
                                       settings: exec, reportDir: reportDir,
                                       appPath: appPath, appName: appName,
                                       appBundleID: appBundleID) { event in
                lines.append(contentsOf: ScenarioLogFormatter.lines(for: event))
            }
            if passed { passedCount += 1 } else { failedCount += 1 }
        }
        if infos.count > 1 {
            lines.append("\(passedCount) passed / \(failedCount) failed")
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

// ftester の MCP サーバ(stdio / JSON-RPC 2.0、依存ゼロの自前実装)。
// Claude Code などの MCP クライアントに、シミュレータ/エミュレータの操作と
// フロー実行をツールとして公開する。
//
// 役割分担の思想:
// - エージェント(クライアント側)が「知能」: 探索・判断・テスト作成
// - このサーバと Flow DSL が「決定性」: 操作・再生・検証
// explore 相当はツールとして提供しない — スナップショットと操作プリミティブがあれば
// クライアントのエージェント自身が探索できるため。

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore

@main
struct FTesterMCP {
    static func main() async {
        let server = MCPServer()
        await server.run()
    }
}

final class MCPServer {

    private var drivers: [String: AppDriver] = [:]
    /// 応答の書き出し口。**stdout は JSON-RPC 専用**(診断を混ぜるとクライアントのパースが壊れる)
    private let write: (Data) -> Void
    /// ドライバ生成の差し替え口。nil = 実デバイスを解決する(既定)
    private let makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)?

    init(write: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) },
         makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)? = nil) {
        self.write = write
        self.makeDriver = makeDriver
    }

    // MARK: - メインループ(stdio: 改行区切り JSON-RPC)

    func run() async {
        while let line = readLine(strippingNewline: true) {
            // **壊れた行でループを抜けない**: 1行の不正でサーバが死ぬとセッションごと落ちる
            guard let message = Self.parseMessage(line) else { continue }
            await handle(message)
        }
    }

    /// 1行を JSON-RPC メッセージとして解釈する。空行・非 JSON・JSON オブジェクトでないものは nil
    static func parseMessage(_ line: String) -> [String: Any]? {
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func handle(_ message: [String: Any]) async {
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        // id なしは notification(initialized 等)— 応答しない
        guard id != nil else { return }

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": (message["params"] as? [String: Any])?["protocolVersion"] ?? "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "ftester", "version": "0.1.0"],
            ])
        case "ping":
            reply(id: id, result: [String: Any]())
        case "tools/list":
            reply(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await call(tool: name, args: args)
                reply(id: id, result: ["content": content, "isError": false])
            } catch {
                reply(id: id, result: [
                    "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                    "isError": true,
                ])
            }
        default:
            reply(id: id, error: ["code": -32601, "message": "method not found: \(method)"])
        }
    }

    private func reply(id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func reply(id: Any?, error: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        write(data)
    }

    // MARK: - ドライバ

    // ft_* は home/appSwitcher/drag/座標 press を含むため in-app ブリッジは使わない
    // (XCUIBridgeResolver: in-app を掴んだら同じデバイスの XCUITest ブリッジへ振り替え、無ければ起動)。
    // profile 指定時は resolveProfileTarget が ft_run_scenario と同じデバイスを解決し、iOS は
    // provision 後のポートを XCUIBridgeResolver へ渡して同じ振り替えを通す
    private func driver(_ args: [String: Any]) async throws -> AppDriver {
        if let makeDriver { return try await makeDriver(args) }
        if let profileName = args["profile"] as? String {
            let key = Self.driverCacheKey(profile: profileName, project: args["project"] as? String,
                                          platform: args["platform"] as? String)
            if let cached = drivers[key] { return cached }
            let project = try ScenarioHost.project(named: args["project"] as? String)
            var prologue: [String] = []
            // profile 指定の初回はブリッジ provision を伴い、コールドスタートは分単位かかりうる
            // (既存ブリッジ再利用時は数秒。進捗は stderr に出る)
            let (_, _, target) = try await resolveProfileTarget(
                project: project, profileName: profileName,
                platformArg: args["platform"] as? String, prologue: &prologue)
            prologue.forEach(Self.logStderr)
            let created: AppDriver
            switch target {
            case .ios(let provisioned, _):
                let resolution = await XCUIBridgeResolver.resolve(
                    preferred: provisioned.port, repoRoot: try? RepoRoot.find(),
                    logger: { Self.logStderr($0) })
                created = BridgeClient(port: resolution.endpoint.port, host: resolution.endpoint.host)
            case .android(let serial, _):
                created = try AndroidDriver(serial: serial)
            }
            drivers[key] = created
            return created
        }

        let platform = (args["platform"] as? String)
            ?? ProcessInfo.processInfo.environment["FTESTER_PLATFORM"]
            ?? "ios"
        let key = Self.driverCacheKey(platform: platform, port: args["port"] as? Int, serial: args["serial"] as? String)
        if let cached = drivers[key] { return cached }
        let created: AppDriver
        switch platform {
        case "ios":
            let port = (args["port"] as? Int).map(UInt16.init) ?? BridgeAPI.defaultPort
            let resolution = await XCUIBridgeResolver.resolve(
                preferred: port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            created = BridgeClient(port: resolution.endpoint.port, host: resolution.endpoint.host)
        case "android":
            created = try AndroidDriver(serial: args["serial"] as? String)
        default:
            throw MCPError("platform must be ios or android: \(platform)")
        }
        drivers[key] = created
        return created
    }

    /// drivers キャッシュのキー生成。profile / project / port / serial の違いを別ドライバとして扱う
    static func driverCacheKey(profile: String, project: String?, platform: String?) -> String {
        "profile:\(project ?? ""):\(profile):\(platform ?? "")"
    }

    static func driverCacheKey(platform: String, port: Int?, serial: String?) -> String {
        "direct:\(platform):\(port ?? 0):\(serial ?? "")"
    }

    private enum ResolvedDriverTarget {
        case ios(ProvisionedIOSDevice, iosApp: ResolvedAppTarget?)
        case android(serial: String, deviceName: String)
    }

    /// profile からデバイスを解決する(ft_run_scenario と直接操作系で共通)。iOS は
    /// BridgeProvisioner.provision を伴うため、初回コールドスタートは分単位かかりうる
    private func resolveProfileTarget(
        project: TestProject, profileName: String, platformArg: String?, prologue: inout [String]
    ) async throws -> (platform: String, resolved: ResolvedProfile, target: ResolvedDriverTarget) {
        let machine = try ProfileResolver.determineMachine(
            project: project, registered: LocalConfig.currentMachineName(),
            runProfileName: profileName)
        let resolved = try ProfileResolver.resolve(
            project: project, runName: profileName, machineName: machine.name)
        prologue.append(contentsOf: resolved.warnings.map { "⚠️ \($0)" })
        let platform = platformArg ?? resolved.devices.first?.platform ?? "ios"
        guard let device = resolved.devices.first(where: { $0.platform == platform }) else {
            throw MCPError("profile \(profileName) has no \(platform) device")
        }
        if platform == "ios" {
            // ブリッジ資産(InAppBridge/・Runner/)を持つ**ツール本体**のルート。受け手パッケージの
            // ルート(root(of:))を渡してはいけない — 外部パッケージ構成では別ディレクトリで、
            // InAppBridge/build.sh が無く provision が必ず落ちる(.ftester の状態も CLI と食い違う)
            let provisioner = BridgeProvisioner(repoRoot: try RepoRoot.find())
            // bundleID/preinstallAppPath は inapp ブリッジのコールドスタートに必須。
            // 稼働中ブリッジ再利用時は使われないため、欠落しても露見しにくい(実際に欠落バグが起きた)
            let iosApp = resolved.apps["ios"]
            // provision の進捗クロージャは @escaping のため inout の prologue を直接キャプチャできない
            var provisionLog: [String] = []
            let provisioned = try await provisioner.provision(
                devices: [(device.name, device.spec)],
                bundleID: iosApp?.bundleID,
                preinstallAppPath: iosApp?.autoInstall == true ? iosApp?.appPath : nil) { provisionLog.append($0) }
            prologue.append(contentsOf: provisionLog)
            return (platform, resolved, .ios(provisioned[0], iosApp: iosApp))
        } else {
            let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
            return (platform, resolved, .android(serial: serial, deviceName: device.name))
        }
    }

    // MARK: - ツール実装

    func call(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        switch tool {
        case "ft_status":
            let status = try await driver(args).status()
            return text("ready: \(status.ready) / \(status.device) (\(status.osVersion)) / session: \(status.sessionBundleID ?? "none")")

        case "ft_install":
            guard let packagePath = args["packagePath"] as? String else {
                throw MCPError("packagePath is required")
            }
            try await driver(args).install(packagePath: packagePath)
            return text("Installed: \(packagePath)")

        case "ft_launch":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId is required") }
            try await driver(args).launch(bundleID: bundleID)
            return text("Launched: \(bundleID)")

        case "ft_snapshot":
            let snapshot = try await driver(args).snapshot()
            return text(SnapshotRenderer.render(snapshot))

        case "ft_tap":
            let d = try await driver(args)
            if let ref = args["ref"] as? Int {
                try await d.tap(ref: ref)
                return text("tap [\(ref)] done. The screen may have changed — take a fresh ft_snapshot")
            }
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                try await d.tap(x: x, y: y)
                return text("tap (\(x), \(y)) done")
            }
            throw MCPError("ref or x/y is required")

        case "ft_type":
            guard let content = args["text"] as? String else { throw MCPError("text is required") }
            try await driver(args).type(ref: args["ref"] as? Int, text: content)
            return text("Typed: \"\(content)\"")

        case "ft_swipe":
            guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
                throw MCPError("direction must be one of up/down/left/right")
            }
            try await driver(args).swipe(direction)
            return text("swipe \(direction.rawValue) done")

        case "ft_press":
            guard let ref = args["ref"] as? Int else { throw MCPError("ref is required") }
            try await driver(args).press(ref: ref, duration: args["duration"] as? Double ?? 1.0)
            return text("press [\(ref)] done")

        case "ft_screenshot":
            let png = try await driver(args).screenshot()
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]

        case "ft_terminate":
            try await driver(args).terminate()
            return text("Terminated the app")

        case "ft_list_scenarios":
            return try listScenarios(args)

        case "ft_run_scenario":
            return try await runScenario(args)

        case "ft_list_projects":
            return try listProjects()

        case "ft_doctor":
            let fm = await FMDoctor.checkLive()
            let vision = FMDoctor.visionReport
            return text((fm.available ? "✅ " : "❌ ") + fm.detail
                + "\n" + (vision.available ? "✅ " : "⚠️ ") + vision.detail)

        default:
            throw MCPError("unknown tool: \(tool)")
        }
    }

    private func text(_ string: String) -> [[String: Any]] {
        [["type": "text", "text": string]]
    }

    /// stdout は JSON-RPC 専用(混ぜるとクライアントのパースが壊れる)。診断は必ず stderr へ
    private static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data(("[ftester-mcp] " + message + "\n").utf8))
    }

    /// シナリオ一覧(自動ビルド込み。コンパイルエラーはそのまま返す=エージェントが直せる)
    private func listScenarios(_ args: [String: Any]) throws -> [[String: Any]] {
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let scenarios = try ScenarioHost.list(project: project)
        let lines = scenarios.map { info in
            "\(info.id)"
                + (info.title.isEmpty ? "" : " — \(info.title)")
                + " (\(info.platform ?? "ios/android"), app: \(info.app))"
                + (info.deleted ? " [deleted @Deleted — excluded from bulk runs]" : "")
        }
        return text(lines.isEmpty
                    ? "No scenarios (add a @TestClass under Projects/\(project.name)/Scenarios/)"
                    : "Project: \(project.name)\n" + lines.joined(separator: "\n"))
    }

    private func listProjects() throws -> [[String: Any]] {
        guard let root = ScenarioHost.packageRoot() else {
            throw MCPError("Package.swift not found (run this inside the repository)")
        }
        let projects = ProjectStore.all(repoRoot: root)
        guard !projects.isEmpty else {
            return text("No projects (create one with: ftester project create <name>)")
        }
        let machineName = LocalConfig.currentMachineName() ?? "unregistered"
        var lines = ["This machine: \(machineName)"]
        for project in projects {
            let runs = ProfileResolver.runProfileNames(project: project)
            let machines = ProfileResolver.machineNames(project: project)
            lines.append("\(project.name)"
                + " — run profiles: \(runs.isEmpty ? "none" : runs.joined(separator: ", "))"
                + " / machines: \(machines.isEmpty ? "none" : machines.joined(separator: ", "))")
        }
        return text(lines.joined(separator: "\n"))
    }

    /// シナリオ実行(自動ビルド込み)。サブプロセス(ftester-scenarios)に委譲する
    private func runScenario(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let id = args["id"] as? String else { throw MCPError("id is required") }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let all = try ScenarioHost.list(project: project)
        guard let info = all.first(where: { $0.id == id })
            ?? all.first(where: { $0.id.hasPrefix(id + ".") }) else {
            throw MCPError("scenario not found: \(id) (available: \(all.map(\.id).joined(separator: ", ")))")
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
            connection = DriverConnection(
                platform: platform,
                port: (args["port"] as? Int).map(UInt16.init),
                serial: args["serial"] as? String)
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

    // MARK: - ツール定義

    static let platformProperty: [String: Any] = [
        "type": "string", "enum": ["ios", "android"],
        "description": "Target platform (default ios)",
    ]
    static let portProperty: [String: Any] = [
        "type": "integer", "description": "iOS bridge port (default 8123)",
    ]
    static let serialProperty: [String: Any] = [
        "type": "string", "description": "Android device serial",
    ]
    static let profileProperty: [String: Any] = [
        "type": "string",
        "description": "Run profile name. When given, connects to the same device as ft_run_scenario (profiles/runs/)",
    ]
    static let projectProperty: [String: Any] = [
        "type": "string", "description": "Test project name (defaults to the default project)",
    ]
    /// 全ツール共通のデバイス選択プロパティ。tool() が無条件で足す
    static let commonDeviceProperties: [(String, [String: Any])] = [
        ("platform", platformProperty),
        ("port", portProperty),
        ("serial", serialProperty),
        ("profile", profileProperty),
        ("project", projectProperty),
    ]

    static let toolDefinitions: [[String: Any]] = [
        tool("ft_status", "Check the device/bridge connection state", [:]),
        tool("ft_install", "Install an app from a package file (iOS: .app bundle / Android: .apk)", [
            "packagePath": ["type": "string", "description": "Absolute path of the package file"],
        ], required: ["packagePath"]),
        tool("ft_launch", "Launch the app (if already running, restarts from the first screen)", [
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (Android)"],
        ], required: ["bundleId"]),
        tool("ft_snapshot", "Get the element list of the current screen. Each line: [ref] Type \"label\" id=... (x,y WxH). Use these refs for tap/type", [:]),
        tool("ft_tap", "Tap an element (ref) or a coordinate (x,y). x/y use the same coordinate system as the ft_snapshot frames (iOS = points pt / Android = device pixels px) — NOT screenshot pixels. "
            + "[Known iOS limitation] On dense, vertically scrolling screens (e.g. Compose Multiplatform), frames of elements below the fold can be reported clamped to the bottom edge, so tapping that coordinate/ref misses. Bring the target into view with ft_swipe, take a fresh ft_snapshot, then tap.", [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
        ]),
        tool("ft_type", "Type text (with ref, taps that field first)", [
            "text": ["type": "string"],
            "ref": ["type": "integer", "description": "Reference number of the input field (defaults to the focused element)"],
        ], required: ["text"]),
        tool("ft_swipe", "Swipe (up = scroll down the content)", [
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
        ], required: ["direction"]),
        tool("ft_press", "Long-press an element", [
            "ref": ["type": "integer"],
            "duration": ["type": "number", "description": "Seconds (default 1.0)"],
        ], required: ["ref"]),
        tool("ft_screenshot", "Take a screenshot (returns an image). Use it for visual verification", [:]),
        tool("ft_terminate", "Terminate the running app", [:]),
        tool("ft_list_scenarios", "List the Swift DSL scenarios (Projects/<name>/Scenarios/). Builds automatically; compile errors are returned as-is", [
            "project": ["type": "string", "description": "Test project name (defaults to the default project)"],
            "skipBuild": ["type": "boolean", "description": "Skip the swift build (default false)"],
        ]),
        tool("ft_run_scenario", "Run a scenario deterministically. On failure, returns the triage and the report path. Builds automatically", [
            "id": ["type": "string", "description": "Scenario ID (Class.method; see ft_list_scenarios)"],
            "project": ["type": "string", "description": "Test project name (defaults to the default project)"],
            "profile": ["type": "string", "description": "Run profile name (profiles/runs/; resolves the connection, heal and report destination)"],
            "heal": ["type": "boolean", "description": "Override for locator self-healing (defaults to the profile setting, or false without a profile; ineffective when the profile has fm:false)"],
            "port": ["type": "integer", "description": "iOS bridge port (default 8123)"],
            "serial": ["type": "string", "description": "Android device serial"],
        ], required: ["id"]),
        tool("ft_list_projects", "List the test projects (Projects/) and their run profiles", [:]),
        tool("ft_doctor", "Check Foundation Models availability", [:]),
    ]

    static func tool(_ name: String, _ description: String,
                     _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var props = properties
        // デバイス選択は全ツール共通。個別宣言があればそちらを優先する
        // (ft_run_scenario は profile/port/serial/project により詳細な説明文を持つ)
        for (key, value) in commonDeviceProperties where props[key] == nil {
            props[key] = value
        }
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}

struct MCPError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

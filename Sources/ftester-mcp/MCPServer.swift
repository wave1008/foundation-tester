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
    private let out = FileHandle.standardOutput

    // MARK: - メインループ(stdio: 改行区切り JSON-RPC)

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            await handle(message)
        }
    }

    private func handle(_ message: [String: Any]) async {
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
                    "content": [["type": "text", "text": "エラー: \(error.localizedDescription)"]],
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
        out.write(data)
    }

    // MARK: - ドライバ

    // ft_* は home/appSwitcher/drag/座標 press を含むため in-app ブリッジは使わない
    // (XCUIBridgeResolver: in-app を掴んだら同じデバイスの XCUITest ブリッジへ振り替え、無ければ起動)。
    // profile 指定時は resolveProfileTarget が ft_run_scenario と同じデバイスを解決し、iOS は
    // provision 後のポートを XCUIBridgeResolver へ渡して同じ振り替えを通す
    private func driver(_ args: [String: Any]) async throws -> AppDriver {
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
            throw MCPError("platform は ios / android のいずれかです: \(platform)")
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
            throw MCPError("プロファイル \(profileName) に \(platform) のデバイスがありません")
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

    private func call(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        switch tool {
        case "ft_status":
            let status = try await driver(args).status()
            return text("ready: \(status.ready) / \(status.device) (\(status.osVersion)) / session: \(status.sessionBundleID ?? "なし")")

        case "ft_install":
            guard let packagePath = args["packagePath"] as? String else {
                throw MCPError("packagePath が必要です")
            }
            try await driver(args).install(packagePath: packagePath)
            return text("インストールしました: \(packagePath)")

        case "ft_launch":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId が必要です") }
            try await driver(args).launch(bundleID: bundleID)
            return text("起動しました: \(bundleID)")

        case "ft_snapshot":
            let snapshot = try await driver(args).snapshot()
            return text(SnapshotRenderer.render(snapshot))

        case "ft_tap":
            let d = try await driver(args)
            if let ref = args["ref"] as? Int {
                try await d.tap(ref: ref)
                return text("tap [\(ref)] 完了。画面が変わった可能性があるため ft_snapshot で再取得してください")
            }
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                try await d.tap(x: x, y: y)
                return text("tap (\(x), \(y)) 完了")
            }
            throw MCPError("ref か x/y が必要です")

        case "ft_type":
            guard let content = args["text"] as? String else { throw MCPError("text が必要です") }
            try await driver(args).type(ref: args["ref"] as? Int, text: content)
            return text("入力しました: \"\(content)\"")

        case "ft_swipe":
            guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
                throw MCPError("direction は up/down/left/right のいずれかです")
            }
            try await driver(args).swipe(direction)
            return text("swipe \(direction.rawValue) 完了")

        case "ft_press":
            guard let ref = args["ref"] as? Int else { throw MCPError("ref が必要です") }
            try await driver(args).press(ref: ref, duration: args["duration"] as? Double ?? 1.0)
            return text("press [\(ref)] 完了")

        case "ft_screenshot":
            let png = try await driver(args).screenshot()
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]

        case "ft_terminate":
            try await driver(args).terminate()
            return text("アプリを終了しました")

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
            throw MCPError("未知のツール: \(tool)")
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
                + (info.deleted ? "【削除済み @Deleted。一括実行から除外】" : "")
        }
        return text(lines.isEmpty
                    ? "シナリオがありません(Projects/\(project.name)/Scenarios/ に @TestClass を追加してください)"
                    : "プロジェクト: \(project.name)\n" + lines.joined(separator: "\n"))
    }

    private func listProjects() throws -> [[String: Any]] {
        guard let root = ScenarioHost.packageRoot() else {
            throw MCPError("Package.swift が見つかりません(リポジトリ内で実行してください)")
        }
        let projects = ProjectStore.all(repoRoot: root)
        guard !projects.isEmpty else {
            return text("プロジェクトがありません(ftester project create <name> で作成)")
        }
        let machineName = LocalConfig.currentMachineName() ?? "未登録"
        var lines = ["このマシン: \(machineName)"]
        for project in projects {
            let runs = ProfileResolver.runProfileNames(project: project)
            let machines = ProfileResolver.machineNames(project: project)
            lines.append("\(project.name)"
                + " — 実行プロファイル: \(runs.isEmpty ? "なし" : runs.joined(separator: ", "))"
                + " / マシン: \(machines.isEmpty ? "なし" : machines.joined(separator: ", "))")
        }
        return text(lines.joined(separator: "\n"))
    }

    /// シナリオ実行(自動ビルド込み)。サブプロセス(ftester-scenarios)に委譲する
    private func runScenario(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let id = args["id"] as? String else { throw MCPError("id が必要です") }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let all = try ScenarioHost.list(project: project)
        guard let info = all.first(where: { $0.id == id })
            ?? all.first(where: { $0.id.hasPrefix(id + ".") }) else {
            throw MCPError("シナリオが見つかりません: \(id)(利用可能: \(all.map(\.id).joined(separator: ", ")))")
        }

        var fm = FMConfig(heal: args["heal"] as? Bool ?? false)
        var reportDir = project.reportsDir.path
        var defaultTimeout: Int?
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
        "description": "対象プラットフォーム(省略時 ios)",
    ]
    static let portProperty: [String: Any] = [
        "type": "integer", "description": "iOS ブリッジのポート(既定 8123)",
    ]
    static let serialProperty: [String: Any] = [
        "type": "string", "description": "Android デバイスのシリアル",
    ]
    static let profileProperty: [String: Any] = [
        "type": "string",
        "description": "実行プロファイル名。指定すると ft_run_scenario と同じデバイスへ接続する(profiles/runs/)",
    ]
    static let projectProperty: [String: Any] = [
        "type": "string", "description": "テストプロジェクト名(省略時は既定プロジェクト)",
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
        tool("ft_status", "デバイス/ブリッジの接続状態を確認する", [:]),
        tool("ft_install", "パッケージファイルからアプリをインストールする(iOS: .app バンドル / Android: .apk)", [
            "packagePath": ["type": "string", "description": "パッケージファイルの絶対パス"],
        ], required: ["packagePath"]),
        tool("ft_launch", "アプリを起動する(起動済みなら先頭画面から再起動)", [
            "bundleId": ["type": "string", "description": "bundle ID(iOS)/ パッケージ名(Android)"],
        ], required: ["bundleId"]),
        tool("ft_snapshot", "現在画面の要素一覧を取得する。各行 [ref] Type \"label\" id=... (x,y WxH)。tap/type はこの ref を使う", [:]),
        tool("ft_tap", "要素(ref)または座標(x,y)をタップする。x/y は ft_snapshot の frame と同一座標系(iOS=ポイント pt / Android=デバイスピクセル px)。スクリーンショットのピクセルではない。"
            + "【iOS の既知の制約】Compose Multiplatform 等の高密度・縦スクロール画面では、ビューポート外(フォールド下)の要素の frame が画面下端に丸められて報告されることがあり、その座標/ref をタップしても当たらない。対象を ft_swipe で可視領域に入れてから ft_snapshot し直してタップする。", [
            "ref": ["type": "integer", "description": "ft_snapshot の参照番号"],
            "x": ["type": "number", "description": "iOS=pt / Android=px(snapshot の frame と同一座標系)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px(snapshot の frame と同一座標系)"],
        ]),
        tool("ft_type", "テキストを入力する(ref 指定時はその入力欄をタップしてから入力)", [
            "text": ["type": "string"],
            "ref": ["type": "integer", "description": "入力欄の参照番号(省略時はフォーカス中の要素)"],
        ], required: ["text"]),
        tool("ft_swipe", "スワイプする(up=下へスクロール)", [
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
        ], required: ["direction"]),
        tool("ft_press", "要素を長押しする", [
            "ref": ["type": "integer"],
            "duration": ["type": "number", "description": "秒(既定 1.0)"],
        ], required: ["ref"]),
        tool("ft_screenshot", "スクリーンショットを撮る(画像を返す)。視覚検証に使う", [:]),
        tool("ft_terminate", "起動中のアプリを終了する", [:]),
        tool("ft_list_scenarios", "Swift DSL シナリオ(Projects/<name>/Scenarios/)の一覧を返す(自動ビルド込み。コンパイルエラーはそのまま返る)", [
            "project": ["type": "string", "description": "テストプロジェクト名(省略時は既定プロジェクト)"],
            "skipBuild": ["type": "boolean", "description": "swift build をスキップ(既定 false)"],
        ]),
        tool("ft_run_scenario", "シナリオを決定的に実行する。失敗時はトリアージとレポートパスを返す(自動ビルド込み)", [
            "id": ["type": "string", "description": "シナリオ ID(クラス名.メソッド名。ft_list_scenarios で確認)"],
            "project": ["type": "string", "description": "テストプロジェクト名(省略時は既定プロジェクト)"],
            "profile": ["type": "string", "description": "実行プロファイル名(profiles/runs/。接続先・heal・レポート先を解決)"],
            "heal": ["type": "boolean", "description": "ロケータ自己修復の上書き(省略時: profile 指定ならその設定、無指定なら false。profile の fm:false 時は true でも無効)"],
            "port": ["type": "integer", "description": "iOS ブリッジのポート(既定 8123)"],
            "serial": ["type": "string", "description": "Android デバイスのシリアル"],
        ], required: ["id"]),
        tool("ft_list_projects", "テストプロジェクト(Projects/)と実行プロファイルの一覧を返す", [:]),
        tool("ft_doctor", "Foundation Models の可用性を確認する", [:]),
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

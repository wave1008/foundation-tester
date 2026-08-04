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
import FTDSL

@main
struct FTesterMCP {
    static func main() async {
        let server = MCPServer()
        await server.run()
    }
}

final class MCPServer {

    private var drivers: [String: AppDriver] = [:]
    /// drivers と同じキーで「実際に主となったエンジン」を覚える。iosEngineHint がこれで
    /// 助言を出し分ける(引数からは決まらない: profile 無しでも in-app を掴めば hybrid)
    var engines: [String: String] = [:]
    /// 応答の書き出し口。**stdout は JSON-RPC 専用**(診断を混ぜるとクライアントのパースが壊れる)
    private let write: (Data) -> Void
    /// ドライバ生成の差し替え口。nil = 実デバイスを解決する(既定)
    private let makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)?
    /// スナップショットの `#id` を台帳へ落とす口。**テストは必ず差し替える**
    /// (既定は実プロジェクトの `.ftester/` へ書くので、テストが利用者の資産を汚す)
    private let recordSnapshot: (_ snapshot: SnapshotResponse, _ platform: String,
                                 _ args: [String: Any]) -> Void

    init(write: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) },
         makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)? = nil,
         recordSnapshot: ((_ snapshot: SnapshotResponse, _ platform: String,
                           _ args: [String: Any]) -> Void)? = nil) {
        self.write = write
        self.makeDriver = makeDriver
        self.recordSnapshot = recordSnapshot ?? MCPServer.recordSelectors
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

    // **実行と同じエンジンで探索する**のが原則(揃えないと snapshot もジェスチャの成否も食い違う)。
    // profile 指定時は resolveProfileTarget が ft_run_scenario と同じデバイスを解決し、iosDriver が
    // プロファイルのエンジンに追従する。profile 無しの iOS は ExploreDriverResolver が
    // 稼働中ブリッジを見て決める(in-app が居れば hybrid を組む・居なければ XCUITest)
    private func driver(_ args: [String: Any]) async throws -> AppDriver {
        if let makeDriver {
            // 差し替えドライバのエンジンは分からない。**助言が出る側(xcuitest)を既定**にする
            // (テストは engines を先に埋めて別のエンジンを名乗れる)
            let key = Self.engineKey(args)
            if engines[key] == nil {
                engines[key] = (args["platform"] as? String) == "android" ? "android" : "xcuitest"
            }
            return try await makeDriver(args)
        }
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
            case .ios(let provisioned, let iosApp):
                created = try await Self.iosDriver(provisioned: provisioned, bundleID: iosApp?.bundleID)
            case .android(let serial, _):
                created = try AndroidDriver(serial: serial)
            }
            drivers[key] = created
            engines[key] = {
                if case .ios(let provisioned, _) = target { provisioned.physical ? "xcuitest" : provisioned.engine }
                else { "android" }
            }()
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
            let resolved = await ExploreDriverResolver.resolve(
                preferred: port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            created = resolved.driver
            engines[key] = resolved.engine
        case "android":
            created = try AndroidDriver(serial: args["serial"] as? String)
            engines[key] = "android"
        default:
            throw MCPError("platform must be ios or android: \(platform)")
        }
        drivers[key] = created
        return created
    }

    /// profile 経由の iOS ドライバ。**実行プロファイルのエンジンに追従する**(2026-08-04。
    /// それ以前は常に XCUITest だった —— StepExecutor を通らない ft_* が in-app では
    /// home/drag/座標 press で素の 501 になるためで、その穴は HybridFallbackDriver が埋めた)。
    /// エンジンを揃える理由は**探索と実行で見えるものを一致させる**こと: snapshot の内容も
    /// ジェスチャの成否もエンジンで変わるので、揃えないと「MCP では動いたのにシナリオでは falls」
    /// (およびその逆)が起きる。
    ///
    /// 合成は実行側(ScenarioRunnerMain)と同じ形:
    ///   in-app(注入) → WebView 画面だけ XCUITest へ委譲 → 不可な操作だけ XCUITest へ回す
    /// **hybrid でないとき(inapp 単独・xcuitest・実機)は素の1本**にする
    static func iosDriver(provisioned: ProvisionedIOSDevice, bundleID: String?) async throws -> AppDriver {
        guard !provisioned.physical, provisioned.engine == "inapp" || provisioned.engine == "hybrid" else {
            // xcuitest(と実機)は従来どおり。resolve は接続先が in-app だったときの振り替えも担う
            let resolution = await XCUIBridgeResolver.resolve(
                preferred: provisioned.port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            // **実機は UDID を渡す**: install/uninstall は simctl ではなく devicectl が要り、
            // clearAppData は「実機では不可」と即答できる(渡さないとデバイス名で simctl を
            // 撃つことになり、的外れな失敗になる)
            return SessionRecoveryDriver(base: BridgeClient(
                port: resolution.endpoint.port, host: resolution.endpoint.host,
                physicalUDID: provisioned.physical ? provisioned.udid : nil))
        }
        let inapp = InAppDriver(repoRoot: try RepoRoot.find(), udid: provisioned.udid,
                                port: provisioned.port)
        guard provisioned.engine == "hybrid", let xcuiPort = provisioned.xcuiPort,
              let bundleID else {
            return inapp
        }
        // attach は**同じインスタンス**を委譲とフォールバックの両方に使う(実行側と同じ理由:
        // activate/attached 状態を1本にしないと余計な activate が挟まる)
        let attach = AppAttachDriver(port: xcuiPort, bundleID: bundleID)
        return HybridFallbackDriver(primary: WebViewDelegatingDriver(primary: inapp, delegated: attach),
                                    fallback: attach)
    }

    /// **実際に主となったエンジンが XCUITest のときだけ**添える切り分け。XCUITest では
    /// 成立しないジェスチャがあり(表と実測は docs/commands.md)、何も起きなかったときに
    /// 原因が分からないと詰む。**Android と in-app/hybrid には付けない**(前者はこの制限が
    /// 無く、後者は成立する。無関係な助言は誤誘導になる)。
    /// エンジンは driver(_:) が記録する = **推測しない**(profile 無しでも稼働中の in-app
    /// ブリッジを掴めば hybrid になるため、引数だけからは決まらない)
    func iosEngineHint(_ framework: String, _ gesture: String, args: [String: Any]) -> String {
        guard engines[Self.engineKey(args)] == "xcuitest" else { return "" }
        return " If nothing changed on iOS: this ran on the XCUITest engine,"
            + " and \(framework) apps do not receive \(gesture) through it."
            + " Pass profile: to follow the run profile's engine, or start an in-app bridge"
            + " (`ftester bridge up --engine inapp`) — both handle it."
    }

    /// **in-app 経路で背面化すると、以降は XCUITest ブリッジ側が受ける**
    /// (in-app ブリッジはアプリのプロセス内に住み、suspend されると応答しない。
    /// 寄せ替えは HybridFallbackDriver が持つ)。XCUITest は外側のプロセスなので関係なく、
    /// back は前面のままなので関係ない
    static func backgroundedAppNote(target: String, engine: String?) -> String {
        guard target != "back", engine == "inapp" || engine == "hybrid" else { return "" }
        return ". The app is in the background now, so the tools run through the XCUITest bridge"
            + " (slower reads, and the snapshot still describes the app itself)"
            + " until you bring it back with ft_launch"
    }

    /// 待ちの既定(秒)。**DSL の defaultTimeout と同じ 5**(FTRuntime)。揃えておかないと
    /// 「MCP では出たのにシナリオでは間に合わない」が起きる
    static let defaultWaitSeconds: Double = 5

    /// ポーリング間隔(秒)。短くしても律速は snapshot 自体(iOS in-app で約 0.12s)
    private static let waitPollSeconds: Double = 0.3

    /// selector が出るまで snapshot を撃ち直す。**照合は DSL と同じ**(FTSelector →
    /// StepExecutor)なので、ここで書ける式はそのままシナリオへ持ち込める
    static func waitFor(_ selector: String, driver: AppDriver, first: SnapshotResponse,
                        seconds: Double) async throws -> (found: Bool, snapshot: SnapshotResponse) {
        if matches(selector, in: first) { return (true, first) }
        let deadline = Date().addingTimeInterval(seconds)
        var latest = first
        while Date() < deadline {
            try await Task.sleep(for: .seconds(waitPollSeconds))
            // **キャッシュを捨てて撮る**: 同じ木を読み続けると、出ていても永遠に出ない
            latest = driver.supportsCacheBypass
                ? try await driver.snapshot(bypassingCache: true) : try await driver.snapshot()
            if matches(selector, in: latest) { return (true, latest) }
        }
        return (false, latest)
    }

    /// セレクタ式(`#id` / ラベル / `.type` / `||` 等)がこの画面に1つでも当たるか
    static func matches(_ selector: String, in snapshot: SnapshotResponse) -> Bool {
        let parsed = FTSelector.parse(selector)
        return ([parsed.primary] + parsed.fallbacks).contains { locator in
            !(StepExecutor.resolvedCandidates(locator, elements: snapshot.elements) ?? []).isEmpty
        }
    }

    /// セッションのアプリが前面に居ないときの注記(居るとき・判定できないときは空)。
    /// 判定は 1 往復(/appstate)なので snapshot の1割程度。**黙って嘘を返すよりは安い**
    static func backgroundedSessionNote(_ snapshot: SnapshotResponse,
                                        driver: AppDriver) async -> String {
        guard let bundleID = snapshot.sessionBundleID,
              let foreground = try? await driver.isAppForeground(bundleID: bundleID),
              !foreground else { return "" }
        return "\(bundleID) is NOT in the foreground: this tree is its last state, not what is on"
            + " screen now (another app or a system screen is in front)."
            + " Bring it back with ft_launch before trusting these refs\n"
    }

    /// driver(_:) が使うキャッシュキーと同じ引き当て(エンジンの記録先)
    static func engineKey(_ args: [String: Any]) -> String {
        if let profileName = args["profile"] as? String {
            return driverCacheKey(profile: profileName, project: args["project"] as? String,
                                  platform: args["platform"] as? String)
        }
        let platform = (args["platform"] as? String)
            ?? ProcessInfo.processInfo.environment["FTESTER_PLATFORM"] ?? "ios"
        return driverCacheKey(platform: platform, port: args["port"] as? Int,
                              serial: args["serial"] as? String)
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
            let snapshotDriver = try await driver(args)
            var snapshot = try await snapshotDriver.snapshot()
            var waitNote = ""
            // **待つのはホスト側の仕事**: エージェントに snapshot を撃ち直させると、待った
            // 回数だけ画面一覧が文脈に積まれる(1回あたり数千トークン)
            if let waitFor = args["waitFor"] as? String {
                let seconds = args["timeout"] as? Double ?? Self.defaultWaitSeconds
                let waited = try await Self.waitFor(waitFor, driver: snapshotDriver,
                                                    first: snapshot, seconds: seconds)
                snapshot = waited.snapshot
                if !waited.found {
                    waitNote = "waitFor \"\(waitFor)\" did not appear within \(seconds)s"
                        + " — this is the screen as it is now\n"
                }
            }
            // **プラットフォームはドライバの実体から採る**(profile 指定時は args["platform"] が
            // 空でもプロファイル側で解決済みなので、args を見ると取り違える)
            recordSnapshot(snapshot, snapshotDriver is AndroidDriver ? "android" : "ios", args)
            // **背面のアプリのツリーを「今の画面」として返さない**: XCUITest の snapshot は
            // セッションのアプリに閉じているので、**別のアプリが前面に来ても同じ木を返し続ける**。
            // 実測(2026-08-05・シミュレータで確定。症状の初出は iPhone 実機):
            // ステータスバーの「◀ 元のアプリへ」を踏んだタップで前面が別アプリに替わったのに、
            // snapshot は元アプリの画面を返し、エージェントからは「タップが効かない」に見えた
            let backgroundNote = await Self.backgroundedSessionNote(snapshot, driver: snapshotDriver)
            return text(waitNote + backgroundNote + SnapshotRenderer.render(snapshot))

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
            // **Enter は別ツールにしない**が、**入力を伴わない pressEnter も要る**:
            // iOS はソフトキーボードを閉じる手段が pressEnter しかない(hideKeyboard は Android 専用。
            // docs/commands.md)。そのため text は「pressEnter だけを撃つとき」は省略できる
            let wantsEnter = args["pressEnter"] as? Bool == true
            let content = args["text"] as? String
            guard content != nil || wantsEnter else {
                throw MCPError("text is required (or pass pressEnter: true to fire Enter only)")
            }
            let typeDriver = try await driver(args)
            if let content, !content.isEmpty {
                try await typeDriver.type(ref: args["ref"] as? Int, text: content)
            } else if let ref = args["ref"] as? Int {
                // 入力せず Enter だけ撃つときも、対象が指定されていればフォーカスを立ててから
                try await typeDriver.tap(ref: ref)
            }
            guard wantsEnter else { return text("Typed: \"\(content ?? "")\"") }
            try await typeDriver.pressEnter()
            return text(content.map { "Typed: \"\($0)\" and pressed Enter" } ?? "Pressed Enter")

        case "ft_swipe":
            guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
                throw MCPError("direction must be one of up/down/left/right")
            }
            try await driver(args).swipe(direction)
            return text("swipe \(direction.rawValue) done")

        case "ft_navigate":
            // **3つを1ツールに束ねる**: back/home/appSwitcher を個別ツールにすると定義が3倍になり、
            // 似た選択肢が並んでエージェントの選択が揺れる(docs/shirates-parity.md の
            // 「別名族を置かない」と同じ判断)
            let target = args["target"] as? String ?? ""
            let navigation = try await driver(args)
            switch target {
            case "back": try await navigation.back()
            case "home": try await navigation.home()
            case "appSwitcher": try await navigation.openAppSwitcher()
            default: throw MCPError("target must be one of back/home/appSwitcher")
            }
            return text("\(target) done. The screen changed — take a fresh ft_snapshot"
                + Self.backgroundedAppNote(target: target, engine: engines[Self.engineKey(args)]))

        case "ft_clear_app_data":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId is required") }
            try await driver(args).clearAppData(bundleID: bundleID)
            return text("Cleared the data of \(bundleID). The app is stopped — ft_launch to continue")

        case "ft_clear_input":
            // ref 省略 = フォーカス中の欄(DSL の clearInput() と同じ)
            try await driver(args).clearInput(ref: args["ref"] as? Int)
            return text("cleared")

        case "ft_dsl_commands":
            return dslCommands(args)

        case "ft_double_tap":
            // **座標へ畳んでから撃つ**: ref はブリッジごとに別名前空間で、501 で別ドライバへ
            // 回るときに取り直しが要る(AppDriver.doubleTap が ref を取らない理由と同じ)
            let doubleTapDriver = try await driver(args)
            let doubleTapPoint: (x: Double, y: Double)
            if let ref = args["ref"] as? Int {
                let snapshot = try await doubleTapDriver.snapshot()
                guard let element = snapshot.elements.first(where: { $0.ref == ref }) else {
                    throw MCPError("unknown ref [\(ref)]. Take an ft_snapshot first")
                }
                doubleTapPoint = (element.frame.centerX, element.frame.centerY)
            } else if let x = args["x"] as? Double, let y = args["y"] as? Double {
                doubleTapPoint = (x, y)
            } else {
                throw MCPError("ref or x/y is required")
            }
            try await doubleTapDriver.doubleTap(x: doubleTapPoint.x, y: doubleTapPoint.y)
            return text("double tap (\(doubleTapPoint.x), \(doubleTapPoint.y)) done."
                + " The screen may have changed — take a fresh ft_snapshot."
                + iosEngineHint("Compose Multiplatform", "double tap", args: args))

        case "ft_drag":
            guard let fromX = args["fromX"] as? Double, let fromY = args["fromY"] as? Double,
                  let toX = args["toX"] as? Double, let toY = args["toY"] as? Double else {
                throw MCPError("fromX/fromY/toX/toY are required")
            }
            try await driver(args).drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                        pressSeconds: 0.05,
                                        durationSeconds: args["durationSeconds"] as? Double ?? 1.5)
            return text("drag (\(fromX), \(fromY)) → (\(toX), \(toY)) done")

        case "ft_pinch":
            let scale = args["scale"] as? Double ?? 2.0
            guard scale > 0, scale != 1, scale.isFinite else {
                throw MCPError("scale must be positive and not 1 (>1 zooms in, <1 zooms out)")
            }
            // ref 指定時は frame と identifier の**両方**を渡す(対象の伝え方が経路で違う。
            // Android/in-app は frame の中心・XCUITest は identifier。FTCore/BridgeDTO の PinchRequest)
            let pinchDriver = try await driver(args)
            var frame: FTRect?
            var identifier: String?
            if let ref = args["ref"] as? Int {
                let snapshot = try await pinchDriver.snapshot()
                guard let element = snapshot.elements.first(where: { $0.ref == ref }) else {
                    throw MCPError("unknown ref [\(ref)]. Take an ft_snapshot first")
                }
                frame = element.frame
                identifier = element.identifier
            }
            try await pinchDriver.pinch(frame: frame, identifier: identifier, scale: scale,
                                        durationSeconds: args["durationSeconds"] as? Double ?? 0.5)
            return text("pinch x\(scale) done."
                + " The zoom may be smaller than requested — verify with ft_snapshot/ft_screenshot."
                + iosEngineHint("Flutter", "pinch", args: args))

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

        case "ft_dry_run":
            return try await dryRun(args)

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

    /// 撮ったスナップショットの `#id` をプロジェクトの台帳へ足す(ft_dry_run が綴り誤りの照合に使う。
    /// SelectorInventory 参照)。**best-effort** —— プロジェクトを特定できない・書けないなら黙って諦める
    /// (探索の邪魔をしない。台帳が薄いと dry-run が黙るだけで、誤検知にはならない)
    static func recordSelectors(_ snapshot: SnapshotResponse, _ platform: String,
                                _ args: [String: Any]) {
        guard let project = try? ScenarioHost.project(named: args["project"] as? String) else { return }
        SelectorInventory.record(ids: SelectorInventory.ids(in: snapshot), platform: platform,
                                 at: SelectorInventory.url(projectRoot: project.rootURL))
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

    /// dry-run(**デバイス不要**)。コンパイルの次・実機実行の前に挟む検証で、実機時間ゼロで
    /// セレクタ構文エラー・到達しない scene・アサーション0の expectation を落とす。
    /// 実機に触れないのでロケータが実在するかは分からない(それは ft_run_scenario の仕事)
    private func dryRun(_ args: [String: Any]) async throws -> [[String: Any]] {
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
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-mcp-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var lines: [String] = []
        // dry-run は NullDriver 固定なので接続情報は使われない(platform だけが ios { } / android { } を分ける)
        let passed = await ScenarioHost.run(
            project: project, scenarioID: info.id,
            connection: DriverConnection(platform: info.platform ?? "ios"),
            fm: FMConfig(heal: false), reportDir: tempDir.path,
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

    /// DSL コマンド索引(`ftester api dsl-commands` と同じ出典 = Sources/FTDSL/CommandIndex.swift)。
    /// **既定は名前と署名だけ**にする: 全 136 件の要約まで返すと 15KB 級になり、
    /// 「どのコマンドがあるか」を知りたいだけの呼び出しでコンテキストを食う。
    /// 要約が要るときは name / category で絞る
    private func dslCommands(_ args: [String: Any]) -> [[String: Any]] {
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

    // MARK: - ツール定義

    // **共通引数の説明は最小限にする**: 5つ × デバイス系ツールで定義全体の約4割を占めるため、
    // 1文字が13倍になる(2026-08-05 実測)。意味は enum と名前で足りる
    static let platformProperty: [String: Any] = [
        "type": "string", "enum": ["ios", "android"], "description": "default ios",
    ]
    static let portProperty: [String: Any] = [
        "type": "integer", "description": "iOS bridge port (default 8123)",
    ]
    static let serialProperty: [String: Any] = [
        "type": "string", "description": "Android device serial",
    ]
    static let profileProperty: [String: Any] = [
        "type": "string",
        "description": "profiles/runs/<name>. Same device and engine as ft_run_scenario",
    ]
    static let projectProperty: [String: Any] = [
        "type": "string", "description": "Test project name",
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
        tool("ft_snapshot", "Get the element list of the current screen. Each line: [ref] Type \"label\" id=... (x,y WxH). "
            + "Use these refs for tap/type. With waitFor it polls for you instead of you calling this again", [
            "waitFor": ["type": "string", "description": "Wait until this selector is on screen. Same syntax as the DSL: #id, a label, .type, a||b"],
            "timeout": ["type": "number", "description": "Seconds to wait for waitFor (default 5, same as the DSL)"],
        ]),
        tool("ft_tap", "Tap an element (ref) or a coordinate (x,y). x/y match the ft_snapshot frames (iOS=pt / Android=px), not screenshot pixels. "
            + "If a tap below the fold misses, the frame was clamped: ft_swipe it into view, ft_snapshot again, then tap.", [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
        ]),
        tool("ft_type", "Type text (with ref, taps that field first). text is required unless pressEnter is "
            + "true — pressEnter alone fires the Enter/IME action, which is also the only way to close the "
            + "soft keyboard on iOS", [
            "text": ["type": "string", "description": "Omit it to fire Enter only"],
            "pressEnter": ["type": "boolean", "description": "Fire Enter/IME action (search, submit, close keyboard)"],
            "ref": ["type": "integer", "description": "Reference number of the input field (defaults to the focused element)"],
        ]),
        tool("ft_swipe", "Swipe (up = scroll down the content)", [
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
        ], required: ["direction"]),
        tool("ft_navigate", "Go back / to the home screen / to the app switcher", [
            "target": ["type": "string", "enum": ["back", "home", "appSwitcher"]],
        ], required: ["target"]),
        tool("ft_clear_app_data", "Wipe the app's data and permissions, keeping it installed (iOS: simulator only). "
            + "Stops the app, so ft_launch after it. Scenarios start from clearAppData(), so explore from that same state", [
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (Android)"],
        ], required: ["bundleId"]),
        tool("ft_clear_input", "Empty an input field (ft_type appends, so clear first to replace)", [
            "ref": ["type": "integer", "description": "Reference number of the field (default: the focused one)"],
        ]),
        tool("ft_dsl_commands", "List the Swift DSL commands with their signatures — the source of truth for "
            + "writing scenarios. Call it before writing code so you do not invent commands. "
            + "Without arguments it returns names and signatures only", [
            "category": ["type": "string", "description": "Only this category (operation/scroll/existence/text/value/app/control/…)"],
            "name": ["type": "string", "description": "Only this command, with its full summary"],
        ], scope: .none),
        tool("ft_double_tap", "Double-tap an element (ref) or a coordinate (x,y). Two ft_tap calls do not work "
            + "(the round trip exceeds the OS double-tap window). Pass profile: on iOS — without it these "
            + "tools use XCUITest, where Compose apps never receive a double tap (see docs/commands.md).", [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
        ]),
        tool("ft_drag", "Drag between two coordinates — the only way to pan diagonally (set both axes). "
            + "Coordinates use the same system as the ft_snapshot frames (iOS=pt / Android=px). "
            + "A long durationSeconds drags slowly and leaves no inertia; a short one flicks", [
            "fromX": ["type": "number"],
            "fromY": ["type": "number"],
            "toX": ["type": "number"],
            "toY": ["type": "number"],
            "durationSeconds": ["type": "number", "description": "Travel time in seconds (default 1.5)"],
        ], required: ["fromX", "fromY", "toX", "toY"]),
        tool("ft_pinch", "Pinch to zoom. scale > 1 zooms in, 0 < scale < 1 zooms out. Without ref the whole "
            + "screen is the target. The actual zoom can be smaller than requested (fingers stay inside the "
            + "target). Pass profile: on iOS — without it Flutter apps do not zoom (see docs/commands.md).", [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot (defaults to the whole screen)"],
            "scale": ["type": "number", "description": "Zoom factor (default 2.0)"],
            "durationSeconds": ["type": "number", "description": "Gesture duration in seconds (default 0.5)"],
        ]),
        tool("ft_press", "Long-press an element", [
            "ref": ["type": "integer"],
            "duration": ["type": "number", "description": "Seconds (default 1.0)"],
        ], required: ["ref"]),
        tool("ft_screenshot", "Take a screenshot (returns an image). Use it for visual verification", [:]),
        tool("ft_terminate", "Terminate the running app", [:]),
        tool("ft_list_scenarios", "List the Swift DSL scenarios (Projects/<name>/Scenarios/). Builds automatically; compile errors are returned as-is", [
            "project": ["type": "string", "description": "Test project name (defaults to the default project)"],
            "skipBuild": ["type": "boolean", "description": "Skip the swift build (default false)"],
        ], scope: .project),
        tool("ft_dry_run", "Dry-run a scenario without any device. Catches selector syntax errors, unreachable scenes and expectation blocks with no assertions in seconds. "
            + "Run it after ft_list_scenarios (compile) and before ft_run_scenario (real device) — it cannot tell whether a selector matches a real element", [
            "id": ["type": "string", "description": "Scenario ID (Class.method; see ft_list_scenarios)"],
            "project": ["type": "string", "description": "Test project name (defaults to the default project)"],
            "skipBuild": ["type": "boolean", "description": "Skip the swift build (default false)"],
        ], required: ["id"], scope: .project),
        tool("ft_run_scenario", "Run a scenario deterministically. On failure, returns the triage and the report path. Builds automatically", [
            "id": ["type": "string", "description": "Scenario ID (Class.method; see ft_list_scenarios)"],
            "project": ["type": "string", "description": "Test project name (defaults to the default project)"],
            "profile": ["type": "string", "description": "Run profile name (profiles/runs/; resolves the connection, heal and report destination)"],
            "heal": ["type": "boolean", "description": "Override for locator self-healing (defaults to the profile setting, or false without a profile; ineffective when the profile has fm:false)"],
            "port": ["type": "integer", "description": "iOS bridge port (default 8123)"],
            "serial": ["type": "string", "description": "Android device serial"],
        ], required: ["id"]),
        tool("ft_list_projects", "List the test projects (Projects/) and their run profiles", [:],
             scope: .none),
        tool("ft_doctor", "Check Foundation Models availability", [:], scope: .none),
    ]

    /// ツールがどの引数群を要るか。**デバイスに触らないツールへ5つ足さない**のが要点 ——
    /// 共通引数はツール定義全体の過半を占めており(2026-08-05 実測 57%)、
    /// 使えない引数を並べるとコンテキストを食うだけでなく「渡せば効く」と誤解させる
    enum ToolScope {
        /// デバイスを掴む(platform/port/serial/profile/project)
        case device
        /// プロジェクトだけ要る(ビルド・シナリオ解決。デバイスには触らない)
        case project
        /// どちらも要らない
        case none
    }

    static func tool(_ name: String, _ description: String,
                     _ properties: [String: Any], required: [String] = [],
                     scope: ToolScope = .device) -> [String: Any] {
        var props = properties
        // 個別宣言があればそちらを優先する(ft_run_scenario は profile/port/serial により詳細な説明を持つ)
        switch scope {
        case .device:
            for (key, value) in commonDeviceProperties where props[key] == nil {
                props[key] = value
            }
        case .project:
            if props["project"] == nil { props["project"] = projectProperty }
        case .none:
            break
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

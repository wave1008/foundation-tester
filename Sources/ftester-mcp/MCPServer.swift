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
    /// drivers と同じキーで**直前にエージェントへ返した木**を覚える。ref を撃つ直前に
    /// 撮り直して同じ要素を引き直すための起点(RefGuard 参照)。
    /// **ref はスナップショットごとに振り直される**ので、番号ではなく要素の同一性で照合する
    var lastSnapshots: [String: SnapshotResponse] = [:]
    /// scroll_to の空打ちゲート用 uiFramework(engineKey ごと)。**成功だけ**記憶する —
    /// 失敗(nil)を覚えると、suspend 中の1回のタイムアウトで判定がセッション全体に固定される
    var uiFrameworkHints: [String: String] = [:]
    /// drivers と同じキーで**最後に ft_launch した bundleID**を覚える。
    ///
    /// **Android のブリッジは session を前面ウィンドウから採る**(`SnapshotBuilder` の
    /// `root.getPackageName()`)。つまり back でアプリを出ると session がその場で別アプリに
    /// 差し替わり、`backgroundedSessionNote`(session が前面か)は**構造上まったく発火しない**。
    /// E2E の 4 SUT は `#id`・ラベルが共通契約なので、木を見ても入れ替わりに気付けない
    /// (2026-08-06 の探索で決定的に再現: `ft_launch com.ftester.e2e.android` → `back` 1回で
    /// 以後の snapshot が `com.ftester.e2e.flutter` の木になった)。
    /// **ホスト側で「起動したアプリ」を覚えて突き合わせる**のが唯一の検知経路。
    var launchedBundleIDs: [String: String] = [:]
    /// プロファイル解決で出た警告(未解決のデバイス名など)。**次に返す応答へ1度だけ**混ぜる。
    /// stderr だけに出していたときは MCP クライアントに一切届かなかった
    var pendingWarnings: [String: [String]] = [:]
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
            // **警告を stderr に捨てない**(外部フィードバック 2026-08-06)。MCP クライアントは
            // stderr を見ないので、「runs の name が machines のデバイスに解決できない」等の
            // 設定ミスが**実行するまで表に出なかった**。次の応答に1度だけ載せる
            pendingWarnings[key] = prologue.filter { $0.hasPrefix("⚠️") }
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
            // engine=xcuitest はブリッジが uiFramework を申告しないが、profile 経由なら
            // 対象 bundleID が分かるのでバンドルのマーカーで判定して覚える(scroll_to の
            // 空打ちゲート用。DSL の xcuitest 経路と同じ判定 = AppBundleInspector)
            if case .ios(let provisioned, let iosApp) = target, !provisioned.physical,
               engines[key] == "xcuitest", let bundleID = iosApp?.bundleID,
               let hint = AppBundleInspector.detect(
                   udid: provisioned.udid, bundleID: bundleID, physical: false) {
                uiFrameworkHints[key] = hint
            }
            // **profile 経由でも宛先を記録する**(2026-08-06)。ここが空だと ft_status が
            // 「どこに繋がっているか」を出せず、**同名のデバイスが並ぶフリートでどの1台か
            // 分からない** —— Android の status.device は全エミュレータで
            // `sdk_gphone64_arm64` になるので、serial が出ないと識別子がゼロになる
            connections[key] = switch target {
            case .ios(let provisioned, _):
                "\(provisioned.simulatorName) port \(provisioned.port)"
            case .android(let serial, let deviceName):
                "\(deviceName) serial \(serial)"
            }
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
            let port = try await Self.resolveIOSPort(explicit: (args["port"] as? Int).map(UInt16.init))
            let resolved = await ExploreDriverResolver.resolve(
                preferred: port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            created = resolved.driver
            engines[key] = resolved.engine
            connections[key] = "port \(port)"
            // **稼働中のブリッジが古いままではないか**を1度だけ確かめる(2026-08-06 に踏んだ)。
            // profile 経由は BridgeProvisioner が版で再利用可否を決めるが、**この経路は
            // 生きているポートへ素で繋ぐだけ**なので、版を上げても旧ランナーが使われ続ける。
            // 実害: ブリッジ側の修正2件を入れて版も上げたのに、ft_snapshot は直る前の木を
            // 返し続け、`bridge down && bridge up` するまで「直っていない」に見えた。
            // Android は AndroidBridge が expectedBridgeVersionCode で入れ替えるのでこの穴が無い
            if let note = await Self.staleBridgeWarning(driver: created) {
                pendingWarnings[key, default: []].append(note)
            }
        case "android":
            let serial = try Self.resolveAndroidSerial(explicit: args["serial"] as? String)
            created = try AndroidDriver(serial: serial)
            engines[key] = "android"
            connections[key] = "serial \(serial)"
        default:
            throw MCPError("platform must be ios or android: \(platform)")
        }
        drivers[key] = created
        return created
    }

    /// 繋いだブリッジが古い版なら警告文、そうでなければ nil。
    ///
    /// **止めはしない**: 利用者が意図して古いブリッジを使っていることはあるし、ここで throw
    /// するとセッションごと止まる。害は「直したはずの挙動が黙って旧版のまま」なので、
    /// 気付けさえすればよい。**判定できないときも nil**(旧ブリッジは版を返さない = nil で、
    /// それを「古い」と断じると常時警告になる)
    static func staleBridgeWarning(driver: AppDriver) async -> String? {
        guard let running = try? await driver.status().protocolVersion,
              running != BridgeAPI.bridgeProtocolVersion else { return nil }
        return "⚠️ The bridge you are connected to is v\(running) but this build expects"
            + " v\(BridgeAPI.bridgeProtocolVersion): snapshots and gestures still behave the way"
            + " the older bridge did. Restart it with `ftester bridge down && ftester bridge up`"
    }

    /// 接続先の宛先(ft_status が見せる)。**#2/#5 の取り違えは「今どこに繋がっているか」が
    /// 見えないまま起きる** —— 既定 8123 が死んでいても、はぐれエミュレータを掴んでいても、
    /// 応答だけ見ると正常に見える
    var connections: [String: String] = [:]

    /// profile 無しの iOS 宛先。**明示 port は探索しない**(利用者が宛先を決めている)。
    /// 既定ポートが死んでいるのは珍しくない —— `bridge up` は稼働中ブリッジの再利用や
    /// pid ファイルの残りで別ポートを選ぶ(FTester.swift の警告)
    static func resolveIOSPort(explicit: UInt16?) async throws -> UInt16 {
        if let explicit { return explicit }
        let preferred = BridgeAPI.defaultPort
        let repoRoot = try? RepoRoot.find()
        if await BridgeDiscovery.isAlive(port: preferred, repoRoot: repoRoot) { return preferred }
        // **応答なしを死と読まない**: 待受が続いているなら乗り換え先は別デバイスになる
        let bound = BridgeDiscovery.isBound(port: preferred, repoRoot: repoRoot)
        let found = bound ? [] : await BridgeDiscovery.scan(excluding: preferred, repoRoot: repoRoot)
        switch BridgeDiscovery.decide(preferredAlive: false, preferredBound: bound, found: found) {
        case .usePreferred:
            return preferred
        case .preferredBusy:
            throw MCPError(BridgeDiscovery.busyMessage(preferred: preferred))
        case .adopt(let bridge):
            logStderr(BridgeDiscovery.adoptedNote(preferred: preferred, found: bridge))
            return bridge.port
        case .none:
            throw MCPError(BridgeDiscovery.noBridgeMessage(preferred: preferred))
        case .ambiguous(let bridges):
            throw MCPError(BridgeDiscovery.ambiguousMessage(preferred: preferred, found: bridges))
        }
    }

    /// profile 無しの Android 宛先。**serial 無しで adb を撃たない**(複数台なら
    /// "more than one device/emulator" が生で出る)
    static func resolveAndroidSerial(explicit: String?) throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        let serials = AndroidSerialResolver.connectedSerials()
        switch AndroidSerialResolver.decide(explicit: nil, connected: serials) {
        case .use(let serial):
            logStderr(AndroidSerialResolver.adoptedNote(
                AndroidSerialResolver.describe(serials: [serial])[0]))
            return serial
        case .none:
            throw MCPError(AndroidSerialResolver.noDeviceMessage)
        case .ambiguous(let devices):
            throw MCPError(AndroidSerialResolver.ambiguousMessage(
                AndroidSerialResolver.describe(serials: devices.map(\.serial))))
        }
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
                                    fallback: attach, primaryBundleID: bundleID,
                                    foreignApp: SessionRecoveryDriver(base: BridgeClient(port: xcuiPort)))
    }

    /// **実際に主となったエンジンが XCUITest のときだけ**添える切り分け。XCUITest では
    /// 成立しないジェスチャがあり(表と実測は docs/commands.md)、何も起きなかったときに
    /// 原因が分からないと詰む。**Android と in-app/hybrid には付けない**(前者はこの制限が
    /// 無く、後者は成立する。無関係な助言は誤誘導になる)。
    /// エンジンは driver(_:) が記録する = **推測しない**(profile 無しでも稼働中の in-app
    /// ブリッジを掴めば hybrid になるため、引数だけからは決まらない)
    /// **1文に圧縮**(2026-08-08): UIKit アプリでも xcuitest エンジンなら毎回この助言が出ており、
    /// 長文の苦情があった。「in-app は起動し直る」制約(dylib は起動時にしか差し込めない。
    /// 2026-08-06 に実際に踏んだ: マップ画面で double tap → ホームから `#nav_scroll` が開いた)
    /// は末尾に畳み込む
    func iosEngineHint(_ framework: String, _ gesture: String, args: [String: Any]) -> String {
        guard engines[Self.engineKey(args)] == "xcuitest" else { return "" }
        // `ftester bridge up --engine inapp` と案内しない —— そのフラグは存在しない
        // (in-app ブリッジは in-app/hybrid の実行プロファイル経由でだけ立つ。2026-08-08 に確認)
        return " If nothing changed on iOS: \(framework) apps do not receive \(gesture) on the"
            + " XCUITest engine — pass profile: naming an in-app/hybrid run profile, which starts"
            + " an in-app bridge (this relaunches the app — re-navigate before retrying)."
    }

    /// **launch する前に**確かめる。未インストールのまま `XCUIApplication.launch()` を撃つと、
    /// XCUI が記録する issue が(main queue 上 = テストのスタック外なので)ランナーごと落とし、
    /// ブリッジが消える —— 2026-08-06 の外部フィードバック #7 の真因はこれで、
    /// 「Safari 操作後に切断」に見えていたのは**別ポートで先に死んでいたランナー**だった。
    /// requireLiveApp と同じ形(XCUI に触れる前に弾いて手前でエラーにする)。
    ///
    /// ブリッジ側は未インストールと未起動を区別できない(XCUIApplication はどちらも notRunning)
    /// のでホストが確かめる。**確かめられないときは nil = 素通し**(実機・同名デバイス複数・
    /// simctl/adb 不調。断定しない側に倒す)。iOS のシステムアプリ(springboard/Safari)も
    /// get_app_container が runtime のパスを返すので誤って弾かない(2026-08-06 実測)
    func installedState(bundleID: String, driver: AppDriver) async -> Bool? {
        // 差し替えドライバ(テスト)ではデバイスを照会しない = simctl/adb を撃たない
        guard makeDriver == nil else { return nil }
        if let android = driver as? AndroidDriver {
            let installed = android.isInstalled(bundleID: bundleID)
            if installed == nil { Self.logStderr(Self.uncheckedNote(bundleID: bundleID, reason: "adb")) }
            return installed
        }
        guard let device = try? await driver.status().device else {
            Self.logStderr(Self.uncheckedNote(bundleID: bundleID, reason: "the bridge did not report a device"))
            return nil
        }
        switch InstalledAppCheck.simulatorInstallVerdict(deviceName: device, bundleID: bundleID) {
        case .installed: return true
        case .notInstalled: return false
        case .unknown(let reason):
            // **素通しは必ず言う**: 黙って通すと、ランナーが死んでから原因を探すことになる
            Self.logStderr(Self.uncheckedNote(bundleID: bundleID, reason: reason))
            return nil
        }
    }

    static func uncheckedNote(bundleID: String, reason: String) -> String {
        "could not verify whether \(bundleID) is installed (\(reason)) — launching anyway."
            + " If it is missing, the XCUITest runner will exit and this bridge will disappear."
    }

    static func notInstalledMessage(bundleID: String) -> String {
        "\(bundleID) is not installed on this device."
            + " Install it with ft_install packagePath: <.app or .apk>, or check the bundle ID"
            + " (Android: the package name)."
    }

    /// XCUITest のセッションは**そのアプリに閉じている**ので、ホーム画面やシステム UI は
    /// 素では読めない。ただし**読む方法はある**(springboard 参照セッション。BridgeRouter の
    /// handleLaunch が bundleID=com.apple.springboard を非破壊で特別扱いする)。
    /// 詰まる2つの応答 —— セッション不在の 409 と、背面アプリ照会の kAXErrorServerNotFound ——
    /// にだけ足す(2026-08-06 フィードバック #6)。
    /// **in-app/hybrid には付けない**: in-app ブリッジは注入先アプリ専用で springboard を掴めない
    static func springboardHint(_ error: Error, engine: String?) -> String {
        guard engine == nil || engine == "xcuitest" else { return "" }
        guard case DriverError.badResponse(let status, let body) = error,
              status == 409 || (status == 500 && body.contains("kAXErrorServerNotFound")) else {
            return ""
        }
        return "\nTo read the home screen or a system dialog instead of the app,"
            + " ft_launch bundleId: com.apple.springboard — it attaches to SpringBoard without"
            + " launching anything, and ft_snapshot then returns the home screen."
            + " ft_launch your app again to go back."
    }

    /// home 直後の XCUITest は「セッションはアプリのまま・画面はホーム」になり、次の
    /// ft_snapshot がアプリの古い木か 500 を返す。**先に言う**(踏んでから調べさせない)
    static func homeScreenReadNote(target: String, engine: String?) -> String {
        guard target == "home", engine == nil || engine == "xcuitest" else { return "" }
        return ". The session still points at the app, so ft_snapshot cannot read the home screen"
            + " — ft_launch bundleId: com.apple.springboard first (non-destructive)"
    }

    /// back が**空振りし得る**ことと、**アプリの外へ出る**ことの2つを言う。
    /// iOS は端の swipe(`XCUIApplication` の navigation gesture)なので、画面側が
    /// システムの戻るを実装していないと 1px も動かない。Android は最初の画面からの back で
    /// アプリが終了し、前面が別アプリになる(`switchedAppNote` が次の snapshot で捕まえる)
    static func backNoOpNote(target: String, engine: String?) -> String {
        guard target == "back" else { return "" }
        let iosNote = engine == "android" ? ""
            : " On iOS this is an edge swipe: screens with their own in-app back button"
                + " (and no system navigation) do not move at all."
        return "." + iosNote
            + " If it was the app's first screen, back leaves the app and the tools follow"
            + " whatever is in front now — ft_launch to come back."
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

    /// システムダイアログのパッケージ/バンドル ID。これらへの切り替わりは「別アプリに迷い込んだ」
    /// ではなく「対象アプリの上にシステム UI が出ている」なので、案内を変える(欠陥⑧)。
    /// 実測: 位置情報の許可ダイアログ(permissioncontroller)で通常の案内(ft_launch し直す)に
    /// 従うと、ダイアログを放置したままアプリを再起動してループした
    static let systemDialogPackages: Set<String> = [
        "com.google.android.permissioncontroller", "com.android.permissioncontroller",
        "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.systemui",
    ]

    /// **この木は ft_launch したアプリのものか**。違えば名指しで止める。
    ///
    /// `backgroundedSessionNote` と役割が違う: あちらは「session のアプリが背面」を見るが、
    /// **session 自体が別アプリへ移ってしまう経路**(Android)ではあちらは永遠に沈黙する。
    /// ここは「起動したもの」対「木が名乗るもの」を比べるので、session が追従しても捕まる。
    ///
    /// **判定材料が無いときは黙る**(嘘を足さない): ft_launch していない・木が名乗らない。
    static func switchedAppNote(launched: String?, snapshot: SnapshotResponse) -> String {
        guard let launched, let session = snapshot.sessionBundleID, session != launched else {
            return ""
        }
        // springboard は ft_launch bundleId: com.apple.springboard がホーム画面へ attach する
        // 正規の使い方(ツール説明に明記)なので、その用途を否定しない文言にする
        if session == "com.apple.springboard" {
            return "⚠️ This tree is the home screen (springboard), not \(launched)."
                + " Reading it is fine — ft_launch bundleId: com.apple.springboard is the supported"
                + " way to attach there — but ft_launch \(launched) first if you meant to keep"
                + " testing the app.\n"
        }
        if systemDialogPackages.contains(session) {
            return "⚠️ \(session) is a system dialog drawn over \(launched)"
                + " (e.g. a permission prompt), not the app itself. Operate the dialog"
                + " (tap its buttons, or back) to get back to \(launched) — ft_launch restarts"
                + " the app and leaves the dialog on screen, so you would loop without progress.\n"
        }
        return "⚠️ This tree belongs to \(session), NOT the app you launched (\(launched))."
            + " Leaving the app (back from its first screen, home, an app switch) hands the"
            + " tools to whatever is in front now — and sibling test apps can look identical."
            + " ft_launch \(launched) before trusting these refs\n"
    }

    /// 木を撮り直す。**MCP は必ずキャッシュを捨てて撮る**(driver が対応していれば)。
    ///
    /// Android の a11y ノードはキャッシュ供給で、**Compose のスクロール後は木が古いまま固まる**
    /// (2026-08-06 に決定的再現。撮り直しても数分待っても直らない)。ブリッジ側の既定が
    /// 「WebView 内だけ refresh」なのは**シナリオ実行**の実測(全ノード refresh で
    /// snapshot +65ms・E2E-Android の sum +43%)に基づくもので、MCP はエージェントが
    /// 1手ずつ撃つ経路なので往復のほうが桁で大きく、この上乗せは見えない。
    /// **常時オンにする**(「ジェスチャの後だけ」のフラグ運用は、フラグを立て忘れたツールが
    /// 1つでもあると黙って古い木に戻る)
    private func freshSnapshot(_ driver: AppDriver, args: [String: Any]) async throws
        -> SnapshotResponse {
        let snapshot = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
        lastSnapshots[Self.engineKey(args)] = snapshot
        return snapshot
    }

    /// ref を撃つ直前の照合。**撮り直した木から同じ要素を引き直して、その新しい ref を返す**。
    /// 引けない(消えた・ghost)なら撃たずに throw する —— 沈黙した誤操作を作らないため。
    ///
    /// 直前の木を覚えていないとき(ft_snapshot を挟まずに ref を撃たれたとき)は素通しする:
    /// 照合の起点が無いので嘘の判断をするより、ブリッジの 404 に任せるほうが正しい
    private func verifiedRef(_ ref: Int, driver: AppDriver,
                             args: [String: Any]) async throws -> (ref: Int, note: String) {
        guard let remembered = lastSnapshots[Self.engineKey(args)],
              let target = remembered.elements.first(where: { $0.ref == ref })
        else { return (ref, "") }
        let lastRendered = remembered.elements
        let fresh = try await freshSnapshot(driver, args: args)
        switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
        case .gone:
            throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                truncatedCount: fresh.truncatedCount))
        case .ghost(let found):
            // **拒否せず警告して撃つ**(2026-08-06 に方針を後退させた。理由は RefGuard の宣言)。
            // **キーボード被覆は先に言う**(木の遮蔽判定では原理的に拾えない事実なので、
            // 座標由来の他の警告より確度が高い)
            return (found.ref, RefGuard.preTapWarnings(found, keyboardFrame: fresh.keyboardFrame)
                + RefGuard.ghostWarning(found: found, in: fresh.elements, screen: fresh.screen))
        case .found(let found, let moved):
            // **ghost でなくても別の物に当たり得る**2形(上に描かれた overlay / 同一矩形への
            // 積み重なり)。どちらも容器の内側なので RefGuard.relocate では .found になる
            let overlap = RefGuard.preTapWarnings(found, keyboardFrame: fresh.keyboardFrame)
                + RefGuard.overlapWarning(found: found, in: fresh.elements, screen: fresh.screen)
            guard moved >= RefGuard.movedThreshold else { return (found.ref, overlap) }
            // **原因までは断定できない**が、「他も同じだけ動いたか」は手元の2枚から言える。
            // 揃って動いていればスクロール等の画面全体の移動、その要素だけならレイアウト変化。
            // 切り分けの手掛かりとして出す(外部フィードバック 2026-08-06。severity は低いとのこと)
            let cause = RefGuard.movedTogether(target, found,
                                               before: lastRendered, after: fresh.elements)
            return (found.ref, RefGuard.preTapWarnings(found, keyboardFrame: fresh.keyboardFrame)
                + RefGuard.movedNote(found: found, moved: moved, cause: cause))
        }
    }

    /// 要素が出るまでスクロールして探す。**探索そのものは DSL と同じ StepExecutor に委ねる**。
    ///
    /// 自前でスワイプのループを書かない理由: 整定待ち・キャッシュ回避・容器基準の刻み・
    /// ghost の掴み直し・飛び越しの拾い直し・打ち切りは全部 StepExecutor に入っており、
    /// **同じ知見の2つ目の実装を作ると必ず割れる**(docs/design.md の「契約は1箇所」)。
    /// ここは FlowStep を1つ組んで投げるだけにする = MCP で届く要素はシナリオでも届く。
    private func scrollTo(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let selectorText = args["selector"] as? String, !selectorText.isEmpty else {
            throw MCPError("selector is required (same syntax as the DSL: #id, a label, .type, a||b)")
        }
        guard let direction = FTScrollDirection(rawValue: args["direction"] as? String ?? "down") else {
            throw MCPError("direction must be one of down/up/right/left (content direction)")
        }
        let scrollDriver = try await driver(args)
        // **曖昧さは「渡す前に見えていた画面」で判定する**: 探索後の木で数えると、リストが
        // 読み込み直しに入っている回に同名の容器が1つしか残らず黙ってしまう
        // (2026-08-07 実測。Google マップは探索スワイプのたびに結果を組み直す)
        let beforeScroll = lastSnapshots[Self.engineKey(args)]
        let selector = FTSelector.parse(selectorText)
        let step = FlowStep(
            action: "scrollTo", locator: selector.primary,
            fallbacks: selector.fallbacks.isEmpty ? nil : selector.fallbacks,
            direction: direction.swipe.rawValue,
            maxSwipes: args["maxSwipes"] as? Int ?? FlowStep.defaultMaxSwipes,
            scrollFrame: (args["scrollFrame"] as? String).map { FTSelector.parse($0).primary })
        // releasesScrollTouch は **iOS だけ true**(Android では 2pt のドラッグがクリックとして
        // 発火する。StepExecutor の宣言参照)。ここを取り違えると探索直後に行が勝手に選択される
        // uiFramework ヒント: xcuitest は profile 経由ならドライバ生成時にバンドルマーカーで
        // 判定済み(uiFrameworkHints)。in-app/hybrid は自己申告(status)を engineKey ごとに
        // 1回だけ取得して使い回す。Android は releasesScrollTouch=false で無関係。
        // **残穴は profile 無しの xcuitest だけ**(任意の前面アプリを駆動するため対象 bundleID が
        // 無くマーカー判定もできない → nil = 空打ちは従来どおり打たれる)
        let engineForKey = engines[Self.engineKey(args)]
        let isAndroid = engineForKey == "android" || scrollDriver is AndroidDriver
        let uiFrameworkHint: String?
        if isAndroid {
            uiFrameworkHint = nil
        } else if let cached = uiFrameworkHints[Self.engineKey(args)] {
            uiFrameworkHint = cached
        } else if engineForKey == "xcuitest" {
            uiFrameworkHint = nil
        } else {
            uiFrameworkHint = (try? await scrollDriver.status())?.uiFramework
            if let hint = uiFrameworkHint { uiFrameworkHints[Self.engineKey(args)] = hint }
        }
        let executor = StepExecutor(driver: scrollDriver,
                                    releasesScrollTouch: !isAndroid,
                                    uiFramework: uiFrameworkHint)
        let outcome = await executor.execute(step)
        // **探索でツリーは必ず動く**ので、覚えている木を捨てて撮り直す(古い ref を残さない)
        let after = try await freshSnapshot(scrollDriver, args: args)
        guard case .passed = outcome.status else {
            // **fail-fast(scrollFrame 未解決)は別の文で伝える**: 通常の「did not reach the
            // element」はスワイプを何本か送った前提の文言で、fail-fast は1本も送っていないので
            // そのままでは誤解を招く(2026-08-08。StepNote.scrollFrameMissing = DSL と共有した判定)
            if outcome.notes.contains(.scrollFrameMissing) {
                let reason: String
                if case .failed(let message) = outcome.status { reason = message }
                else { reason = "\(outcome.status)" }
                throw MCPError("scrollTo \"\(selectorText)\": \(reason)"
                    + Self.scrollAlternativesHint(beforeScroll ?? after))
            }
            // **止まった時点で見えているものを一緒に返す**(外部フィードバック 2026-08-06)。
            // 「届かなかった」だけだと ft_snapshot の往復が要るうえ、**記法の誤りに気づけない**
            // —— 素のラベルは完全一致なので、「端末情報」は「端末情報を表示」に当たらない。
            // 候補を見せれば、綴り違いなのか記法(`*…*`)不足なのかがその場で分かる
            throw MCPError("scrollTo \"\(selectorText)\" did not reach the element"
                + " (\(outcome.status))\(Self.truncationHint(after)). \(Self.visibleLabelsHint(after))"
                + Self.notationHint(selectorText, in: after)
                + Self.scrollAreaHint(beforeScroll ?? after, args: args))
        }
        // **成功と言う前に、返す木にそれが居ることを確かめる**(2026-08-06 の探索で外した)。
        // 探索のスワイプは**ボタンを発火させることがある**(SwiftUI の SUT で実測)。
        // その場合 executor は途中の観測で passed のまま、撮り直した木は**別画面**になり、
        // 「scrolled to #nav_diagnostics」+ `#nav_diagnostics` が居ない木、が返っていた。
        // 決定的再現: E2E-iOS のホームで `#nav_diagnostics`(下部タブの下にある行)
        // **照合は selector で行う**: `scrollTo` は `resolvedElement` を載せない
        // (StepExecutor の scrollTo 経路は要素を掴んでも記録しない)ので、それを当てにすると
        // この検査は一度も走らない。`matches` は waitFor と同じ = DSL と同じ照合
        if !Self.matches(selectorText, in: after) {
            throw MCPError("scrollTo \"\(selectorText)\" reached the element, but it is gone from"
                + " the screen now — the search itself changed the screen"
                + " (a swipe over a tappable row can fire it)\(Self.truncationHint(after))."
                + " \(Self.visibleLabelsHint(after))"
                + " Go back to the screen that has it and retry;"
                + " scrollFrame: <container> keeps the swipes inside the list."
                + Self.scrollAreaHint(after, args: args))
        }
        let landed = outcome.resolvedElement.map { " → [\($0.ref)] \(RefGuard.describe($0))" } ?? ""
        // **木を返す口はすべて名指しする**(2026-08-06 の掃討で漏れを見つけた)。上の再確認は
        // 「セレクタが居るか」しか見ないので、**別アプリに同じ id がある**と素通しする ——
        // E2E の 4 SUT は id・ラベルが共通契約なので、これは現に起こり得る形
        let switched = Self.switchedAppNote(
            launched: launchedBundleIDs[Self.engineKey(args)], snapshot: after)
        // scrollFrame を渡すべき当人なので、複数領域の注記もここに出す(欠陥⑪)
        let scrollAreaNote = args["scrollFrame"] == nil ? (ScrollFrameCandidates.note(after) ?? "")
            : Self.lineNote(Self.scrollAreaHint(beforeScroll ?? after, args: args))
        return text(switched + "scrolled to \"\(selectorText)\"\(landed)."
            + " The refs below are fresh\n" + scrollAreaNote + Self.ghostNote(after)
            + Self.keyboardCoverageNote(after) + Self.sliverNote(after)
            + (SnapshotRenderer.truncatedLabelNote(after) ?? "")
            + SnapshotRenderer.render(after, flagging: Self.ghostFlags(after)))
    }

    /// 「session のアプリが今も前面か」。判定できないドライバでは黙る(嘘を足さない)
    static func foregroundNote(_ sessionBundleID: String?, driver: AppDriver) async -> String {
        guard let bundleID = sessionBundleID else { return "" }
        if let front = (try? await driver.foregroundAppID()) ?? nil {
            return front == bundleID ? " / foreground: yes"
                : " / foreground: no (\(front) is in front — ft_launch to come back)"
        }
        guard let inFront = try? await driver.isAppForeground(bundleID: bundleID) else { return "" }
        return inFront ? " / foreground: yes"
            : " / foreground: no (another app or the home screen is in front — ft_launch to come back)"
    }

    /// 接続中の Android 全台の状態。**1台ずつ独立に見る**(1台落ちていても他を隠さない)
    static func androidFleetStatus(_ serials: [String]) async -> String {
        var lines = ["\(serials.count) Android devices are connected."
            + " Pass serial: (or profile:) to operate one — this listing is status-only."]
        for device in AndroidSerialResolver.describe(serials: serials) {
            let line: String
            if let driver = try? AndroidDriver(serial: device.serial),
               let status = try? await driver.status() {
                let session = status.sessionBundleID ?? "none"
                line = "ready: \(status.ready) / \(device.label) (\(status.osVersion))"
                    + " / session: \(session)"
            } else {
                line = "unreachable / \(device.label) (adb responds but the bridge does not —"
                    + " it starts on the first operation)"
            }
            lines.append("  serial \(device.serial): \(line)")
        }
        return lines.joined(separator: "\n")
    }

    /// 探索が止まった画面で「実際に引けるもの」を列挙する。id を優先し、無ければラベル。
    /// **多すぎると読めない**ので上限を切る(足りなければ ft_snapshot を撮ればよい)
    static func visibleLabelsHint(_ snapshot: SnapshotResponse) -> String {
        var seen = Set<String>()
        var shown: [String] = []
        for e in snapshot.elements {
            // **ゼロ幅文字を落としてから出す**: ここから写したラベルは**見た目が正しいのに
            // 完全一致しない**(2026-08-07 実測。Google マップの発車案内で U+200B が21個
            // 漏れていた。木の描画側は除去済みで、ヒストだけ素通しだった)
            let cleaned = e.label.map(FlowMatchMode.stripZeroWidthCharacters)
            let name = (e.identifier?.isEmpty == false) ? "#\(e.identifier!)"
                : (cleaned?.isEmpty == false) ? "\"\(cleaned!)\"" : ""
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            shown.append(name)
            if shown.count >= 20 { break }
        }
        guard !shown.isEmpty else { return "Nothing selectable is on screen." }
        let more = snapshot.elements.count > shown.count ? " …" : ""
        return "On screen where the search stopped: \(shown.joined(separator: " "))\(more)."
    }

    /// スクロール容器の**完全に外**に報告されている要素(ghost)を先頭で名指しする。
    ///
    /// 一覧そのものからは見分けが付かない —— ghost はフルフレームで並ぶので、
    /// 「画面に見えている行」と同じ形で出る(Compose iOS は容器の外の行も木に残す)。
    /// `waitFor` も素の存在しか見ないので、ghost だけで条件が満たされることがある。
    /// **叩けば RefGuard が止める**が、そこまで行かずに気付けるほうが往復が減る
    static func ghostRefs(_ snapshot: SnapshotResponse) -> [Int] {
        snapshot.elements
            .filter { RefGuard.isUntappableGhost($0, in: snapshot.elements, screen: snapshot.screen) }
            .map(\.ref)
    }

    /// 残像の行に付ける印。**先頭の注記だけでは足りない**(外部フィードバック 2026-08-06):
    /// エージェントは一覧の行から ref をコピーするので、その行自体に出ていないと届かない。
    ///
    /// 積み重なり(`stackedRefs`)にも同じ印を付ける —— 利用者から見ると原因は同じ
    /// 「スクロールの残骸がそこに描かれていない」で、対処(`ft_scroll_to` で出してから撮り直す)
    /// も同じ。**印を2種類に割らない**(見分けても打ち手が変わらないものを増やさない)
    static func ghostFlags(_ snapshot: SnapshotResponse) -> [Int: String] {
        let refs = Set(ghostRefs(snapshot)).union(RefGuard.stackedRefs(snapshot.elements))
        return Dictionary(uniqueKeysWithValues: refs.map { ($0, "⚠️scroll-leftover") })
    }

    static func ghostNote(_ snapshot: SnapshotResponse) -> String {
        let flagged = ghostFlags(snapshot)
        let ghosts = snapshot.elements.filter { flagged[$0.ref] != nil }
        guard !ghosts.isEmpty else { return "" }
        let listed = ghosts.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
            .joined(separator: " ")
        let more = ghosts.count > 8 ? " (+\(ghosts.count - 8) more)" : ""
        return "note: the ⚠️scroll-leftover rows below are not drawn where their frames say"
            + " (outside their scroll container, or clamped onto another row's frame),"
            + " so tapping them may hit something else:"
            + " \(listed)\(more). Bring them into view with ft_scroll_to first,"
            + " or verify with ft_screenshot\n"
    }

    /// **scrollFrame を渡すべき当人**である ft_scroll_to にだけ出す、複数スクロール領域の注記
    /// (欠陥⑪)。`ScrollFrameCandidates.note` は ft_snapshot でしか呼ばれておらず、一番効く場所
    /// (scrollFrame: を渡すべき本人の失敗文・成功文)に届いていなかった。
    /// scrollFrame: を既に渡しているときは黙る(選んだ後なので不要)
    /// 木の前に置く注記は**1行で終える**(次の注記と同じ行に流れ込むと読み手が切れ目を失う)
    static func lineNote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "note: \(trimmed)\n"
    }

    /// スクロールできる容器の実名の列挙だけ(理由の断定はしない。呼び出し側の文に添える)
    static func scrollAlternativesHint(_ snapshot: SnapshotResponse) -> String {
        let real = ScrollFrameCandidates.candidates(in: snapshot)
            .compactMap(\.selector).prefix(4).joined(separator: " ")
        return real.isEmpty
            ? " No element on this screen declares itself scrollable."
            : " Scrollable areas here: \(real)."
    }

    static func scrollAreaHint(_ snapshot: SnapshotResponse, args: [String: Any]) -> String {
        // **渡した scrollFrame が複数に当たっているなら、それを先に言う**。`matchDetailed` は
        // 添字が無ければ `matches[0]` を黙って採るので、同名の容器が並ぶ画面では
        // preorder 先頭(たいてい横カルーセル)を掴んだまま「見つからない」で終わる。
        // 実測(2026-08-07・Google マップ Android): `#recycler_view` は1画面に4つあり、
        // 注記どおり渡すと高さ126pxのチップ行が選ばれて結果リストは1pxも動かなかった。
        // **StepExecutor 側の申告は当てにしない** —— あちらの `pendingScrollFrameNote` は
        // 探索ループの条件分岐の中でしか埋まらず、空振りのまま失敗する回では nil のままになる
        if let frame = args["scrollFrame"] as? String {
            let locator = FTSelector.parse(frame).primary
            let matches = StepExecutor.candidates(locator, elements: snapshot.elements) ?? []
            // **1件も当たらないなら、その事実こそ言う**: 誤字や範囲外の添字でも
            // `scrollContainer` は nil を返し、**2026-08-08 からは探索そのものを打ち切る**
            // (以前は全画面スワイプへ黙って退化していたが、カードのボタン等を誤発火させる
            // 実害があったため fail-fast に変えた。ここは fail-fast の理由文に添える候補列挙)
            if matches.isEmpty {
                // 「search was not run」とはここでは言わない —— fail-fast の理由文
                // (StepExecutor.scrollNotFoundMessage)が既に言っており、このヒントは
                // 成功時の note にも合流するので、断定すると成功メッセージで嘘になる
                return " scrollFrame \"\(frame)\" matches nothing on this screen."
                    + Self.scrollAlternativesHint(snapshot)
            }
            guard locator.index == nil, matches.count >= 2 else { return "" }
            let listed = matches.prefix(4).enumerated().map { index, element -> String in
                let f = element.frame
                return "[\(index)] (\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)))"
            }.joined(separator: " ")
            return " scrollFrame \"\(frame)\" matches \(matches.count) elements and the first one"
                + " was used — add [n] to pick another: \(listed)."
        }
        // **スクロール容器が1つも申告されない木**では、案内が出せない理由ごと言う(2026-08-08 の
        // 監査)。in-app は版57から Compose/Flutter でも申告できるが、XCUITest エンジンの木では
        // 依然として出ない。黙ると「scrollFrame を渡せ」というツール説明だけが残り、
        // 渡す候補が無いことに気づけない
        if !snapshot.elements.contains(where: { $0.scrollable == true }) {
            return " No element in this tree declares itself scrollable (with Compose/Flutter,"
                + " only the in-app engine can see scroll containers), so the search swiped the"
                + " whole screen. If the target sits in a horizontal row, scroll the row with"
                + " ft_drag inside its bounds; a container that has a #id (testTag) can still be"
                + " passed as scrollFrame:."
        }
        guard let note = ScrollFrameCandidates.note(snapshot) else { return "" }
        return " " + note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// セレクタの**記法**が原因で外れたときだけ出す助言。無条件に「\* で囲め」と言っていた版は
    /// 誤った助言を2形返していた(2026-08-07 に Google マップで実測): 既に `*寿司*` を渡した相手に
    /// 同じ `*寿司*` を勧める / `#no_such_id` に**ラベル部分一致**の `*no_such_id*` を勧める。
    /// 判定は DSL と同じ `StepExecutor.partialMatchHint` に委ねる(3条件そろったときだけ返る)。
    /// 切り詰めラベルの取り違えはそれとは別の形なので独立に足す
    static func notationHint(_ selectorText: String, in snapshot: SnapshotResponse) -> String {
        var parts: [String] = []
        if let hint = SnapshotRenderer.truncatedSelectorHint(selectorText, in: snapshot) {
            parts.append(hint)
        }
        let locator = FTSelector.parse(selectorText).primary
        if let hint = StepExecutor.partialMatchHint(for: locator, in: snapshot.elements) {
            parts.append(" The element is \(hint).")
        }
        return parts.joined()
    }

    /// スナップショットが上限で打ち切られていたときの注記(欠陥①a)。**打ち切りは配列そのものからの
    /// 脱落**であって描画の省略ではないので、waitFor/scrollTo は打ち切られた要素を一生探し続ける。
    /// 実測: 画面に描画されている `#nav_button` を waitFor が「did not appear」、scrollTo が
    /// 「element not found」としか言わず、存在しない要素を探し続けることになっていた。
    /// FTCore 側に同趣旨(`StepExecutor+Assert.truncationHint`)があるが internal で呼べないため、
    /// 文言だけ揃えてこちらに複製する
    static func truncationHint(_ snapshot: SnapshotResponse) -> String {
        guard snapshot.truncatedCount > 0 else { return "" }
        return " (the tree was truncated at \(snapshot.elements.count) elements;"
            + " \(snapshot.truncatedCount) more were omitted — the element you are looking for"
            + " may be among them)"
    }

    /// **ラベルも id も無い clickable**の注記(欠陥⑨)。座標か ref でしか指定できず、
    /// シナリオでは安定したセレクタを書けないことを伝える。実測: 経路の移動手段タブ(アイコンのみ)
    /// が id もラベルも無い `clickable` として出て、書ける手段が何も無いことに気付けなかった
    static func unlabeledClickablesNote(_ snapshot: SnapshotResponse) -> String {
        let unlabeled = snapshot.elements.filter {
            $0.type == "clickable" && ($0.identifier ?? "").isEmpty && ($0.label ?? "").isEmpty
        }
        guard !unlabeled.isEmpty else { return "" }
        let listed = unlabeled.prefix(8).map { "[\($0.ref)]" }.joined(separator: " ")
        let more = unlabeled.count > 8 ? " (+\(unlabeled.count - 8) more)" : ""
        return "note: \(unlabeled.count) clickable element(s) have neither a label nor an id"
            + " (\(listed)\(more)) — they can only be targeted by ref or coordinates,"
            + " so a scenario cannot select them with a stable selector.\n"
    }

    /// キーボード下に隠れた操作対象。木からは判定できない(キーボードはスナップショットの対象外)
    /// ので、ブリッジ申告の `keyboardFrame` でだけ言える(判定は RefGuard.keyboardWarning と共有)。
    /// 実測(2026-08-08・iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった
    static func keyboardCoverageNote(_ snapshot: SnapshotResponse) -> String {
        guard let kb = snapshot.keyboardFrame else { return "" }
        let header = "the soft keyboard covers"
            + " (\(Int(kb.x)),\(Int(kb.y)) \(Int(kb.width))x\(Int(kb.height)))"
        let covered = snapshot.elements.filter {
            RefGuard.interactiveTypes.contains($0.type)
                && TapTargetGeometry.keyboardCoveredAdvisory($0, keyboardFrame: kb) != nil
        }
        guard !covered.isEmpty else { return "note: \(header); nothing tappable is beneath it\n" }
        let listed = covered.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
            .joined(separator: " ")
        let more = covered.count > 8 ? " (+\(covered.count - 8) more)" : ""
        return "note: \(header). \(covered.count) listed element(s) are beneath it and a tap would"
            + " hit the keyboard instead: \(listed)\(more)\n"
    }

    /// ラベル付きだが極端に細い要素(掴めないほど狭い可能性)。
    /// 判定は RefGuard.isClippedSliver = DSL(TapTargetGeometry)と共有。
    /// 判定は要素自身の細さだけ(縁で切れたかは見ない)
    static func sliverNote(_ snapshot: SnapshotResponse) -> String {
        let slivers = snapshot.elements.filter { RefGuard.isClippedSliver($0) }
        guard !slivers.isEmpty else { return "" }
        let listed = slivers.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
            .joined(separator: " ")
        let more = slivers.count > 8 ? " (+\(slivers.count - 8) more)" : ""
        return "note: \(slivers.count) element(s) are extremely thin with a label"
            + " (≤10 wide/tall) — the strip may be too thin to tap, whether clipped at an edge"
            + " or just narrow by design: \(listed)\(more)\n"
    }

    /// 同一ラベルが3件以上に一致するときの要約注記(欠陥⑩)。id の重複は別パッケージが
    /// 行内に `×N` として個別に出すので、こちらは**ラベルだけ**を扱う。
    /// 実測: 経路検索の候補一覧で「東京駅」が9件一致し、素のラベルでは一意に指せなかった
    static func ambiguousLabelsNote(_ snapshot: SnapshotResponse) -> String {
        var counts: [String: Int] = [:]
        for e in snapshot.elements {
            guard let label = e.label, !label.isEmpty else { continue }
            counts[label, default: 0] += 1
        }
        let ambiguous = counts.filter { $0.value >= 3 }.sorted { $0.value > $1.value }
        guard !ambiguous.isEmpty else { return "" }
        let listed = ambiguous.prefix(5).map { "\"\($0.key)\" ×\($0.value)" }.joined(separator: " ")
        let more = ambiguous.count > 5 ? " (+\(ambiguous.count - 5) more)" : ""
        return "note: these labels match multiple elements, so a plain label selector cannot"
            + " pick one uniquely: \(listed)\(more).\n"
    }

    /// フォーカス待ちの上限。**短い**のは、報告しないフレームワークで毎回これを丸ごと待つため
    static let focusWaitSeconds: Double = 1.5
    static let focusPollSeconds: Double = 0.15

    /// `tap(ref:)` の直後、pressEnter を撃つ前に**その欄へフォーカスが立つまで**待つ。
    ///
    /// **フォーカスを報告しないフレームワークで待ち続けない**のが要点: Compose iOS の a11y 要素は
    /// UIResponder ではないので in-app ブリッジは focused を一度も返さない(InAppSnapshot の
    /// makeInfo)。そこで「木の中に focused=true の要素が1つも無い」= 報告しない経路と読み、
    /// 即座に諦める。誰かが focused を名乗っているのに対象でないときだけが**本当の待ち**
    /// (= 前の欄にフォーカスが残っている状態)。
    private func awaitFocus(ref: Int, driver: AppDriver, args: [String: Any]) async -> String {
        guard let target = lastSnapshots[Self.engineKey(args)]?
            .elements.first(where: { $0.ref == ref }) else { return "" }
        let deadline = Date().addingTimeInterval(Self.focusWaitSeconds)
        while true {
            guard let fresh = try? await freshSnapshot(driver, args: args) else { return "" }
            if case .found(let found, _) = RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen),
               found.focused == true { return "" }
            // 誰も focused を名乗らない = 報告しない経路。待っても永遠に立たない
            guard fresh.elements.contains(where: { $0.focused == true }) else { return "" }
            guard Date() < deadline else {
                return " (warning: \(RefGuard.describe(target)) never took focus within"
                    + " \(Self.focusWaitSeconds)s — the Enter/IME action may have gone to"
                    + " whichever field still had it)"
            }
            try? await Task.sleep(for: .seconds(Self.focusPollSeconds))
        }
    }

    /// ref を撃つ直前に照合したうえで**要素そのもの**を返す(ft_double_tap / ft_pinch 用。
    /// 両者は ref ではなく座標・identifier で撃つため要素が要る)
    private func verifiedElement(_ ref: Int, driver: AppDriver,
                                 args: [String: Any]) async throws -> ElementInfo {
        let remembered = lastSnapshots[Self.engineKey(args)]?.elements.first { $0.ref == ref }
        let fresh = try await freshSnapshot(driver, args: args)
        // 直前の木を覚えていない(ft_snapshot を挟まずに撃たれた)= 撮ったばかりの木から素直に引く
        guard let target = remembered else {
            guard let element = fresh.elements.first(where: { $0.ref == ref }) else {
                throw MCPError("unknown ref [\(ref)]. Take an ft_snapshot first")
            }
            return element
        }
        switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
        case .gone:
            throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                truncatedCount: fresh.truncatedCount))
        case .ghost(let found), .found(let found, _):
            return found
        }
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

    /// **接続が消えた失敗には「今どこに何が居るか」を添える**(2026-08-06 フィードバック #7)。
    /// ポートで誰も待受していない = XCUITest ランナーのプロセス死で、原因の筆頭は
    /// **同一シミュレータに2本目のランナーが立った**こと(全ポート共通 bundle id のため
    /// 先代が蹴り出される。FTester.swift の bridge up 参照)。素のメッセージからは追えない
    func call(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        do {
            return try await dispatch(tool: tool, args: args)
        } catch {
            let hint = await connectionLostHint(error, args: args)
            guard !hint.isEmpty else { throw error }
            throw MCPError(error.localizedDescription + hint)
        }
    }

    func connectionLostHint(_ error: Error, args: [String: Any]) async -> String {
        // 差し替えドライバ(テスト)では走査しない = 実ポートを叩かない
        guard makeDriver == nil, case DriverError.bridgeConnectionRefused = error else { return "" }
        let key = Self.engineKey(args)
        guard let connection = connections[key], connection.hasPrefix("port") else { return "" }
        // 掴んでいたドライバは死んでいる。次の呼び出しで解決し直させる
        drivers[key] = nil
        connections[key] = nil
        let running = await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
        return Self.connectionLostMessage(connection: connection, running: running)
    }

    static func connectionLostMessage(connection: String,
                                      running: [BridgeDiscovery.Found]) -> String {
        let now = running.isEmpty
            ? "no iOS bridge is running now"
            : "running bridges now: \(running.map(\.label).joined(separator: ", "))"
        return "\nThe XCUITest runner behind \(connection) exited — a second runner on the same"
            + " simulator kicks out the first, and the app under test crashing takes an in-app"
            + " bridge with it. \(now). Start one with `ftester bridge up`; the session does not"
            + " survive, so ft_launch your app again."
    }

    func dispatch(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        switch tool {
        case "ft_status":
            // **読み取り専用のここだけは、複数台でも失敗させない**(外部フィードバック 2026-08-06)。
            // 操作系(tap/type/…)は従来どおりエラーにする —— 曖昧なまま「どれか」を操作させない
            // 規律([[BridgeDiscovery]] と同じ)を崩さないため。status は状態を見るだけなので、
            // 全台を並べて返すほうが次の一手(serial: を選ぶ)に直結する
            if args["profile"] == nil, args["serial"] == nil,
               (args["platform"] as? String) == "android",
               case .ambiguous(let devices) = AndroidSerialResolver.decide(
                   explicit: nil, connected: AndroidSerialResolver.connectedSerials()) {
                return text(await Self.androidFleetStatus(devices.map(\.serial)))
            }
            let status = try await driver(args).status()
            // **宛先とセッションの意味まで出す**: 「どこに繋がっているか」が見えないと、
            // 既定ポートの死・はぐれデバイスの誤掴み・ブリッジ再起動によるセッション消失が
            // どれも「応答はしているのに操作できない」に見える(2026-08-06 フィードバック #2/#8)
            let endpoint = connections[Self.engineKey(args)].map { " @ \($0)" } ?? ""
            let session = status.sessionBundleID
                ?? "none (no app attached — ft_launch <bundleId> first;"
                    + " a bridge restart clears the session)"
            // **session と「いま前面にあるもの」は別物**(外部フィードバック 2026-08-06)。
            // session はブリッジが掴んでいるアプリで、ft_navigate home の後も変わらない。
            // 前面の照会は 1 往復で済むので、シナリオ冒頭の appIs 相当をここで賄えるようにする
            let foreground = await Self.foregroundNote(status.sessionBundleID,
                                                       driver: try await driver(args))
            return text(withPendingWarnings(
                "ready: \(status.ready) / \(status.device) (\(status.osVersion))\(endpoint)"
                + " / session: \(session)\(foreground)", args: args))

        case "ft_install":
            guard let packagePath = args["packagePath"] as? String else {
                throw MCPError("packagePath is required")
            }
            try await driver(args).install(packagePath: packagePath)
            return text("Installed: \(packagePath)")

        case "ft_launch":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId is required") }
            let launchDriver = try await driver(args)
            // **撃つ前に弾く**(ランナー死の予防。installedState のコメント参照)
            if await installedState(bundleID: bundleID, driver: launchDriver) == false {
                throw MCPError(Self.notInstalledMessage(bundleID: bundleID))
            }
            try await launchDriver.launch(bundleID: bundleID)
            // 以後の snapshot は「これの木か」を突き合わせられる(switchedAppNote)
            launchedBundleIDs[Self.engineKey(args)] = bundleID
            return text("Launched: \(bundleID)")

        case "ft_snapshot":
            let snapshotDriver = try await driver(args)
            var snapshot: SnapshotResponse
            do {
                snapshot = try await freshSnapshot(snapshotDriver, args: args)
            } catch {
                // ホーム画面/システム UI を読もうとして詰まった形なら、読む方法まで返す
                let hint = Self.springboardHint(error, engine: engines[Self.engineKey(args)])
                guard !hint.isEmpty else { throw error }
                throw MCPError(error.localizedDescription + hint)
            }
            var waitNote = ""
            // **待つのはホスト側の仕事**: エージェントに snapshot を撃ち直させると、待った
            // 回数だけ画面一覧が文脈に積まれる(1回あたり数千トークン)
            if let waitFor = args["waitFor"] as? String {
                let seconds = args["timeout"] as? Double ?? Self.defaultWaitSeconds
                let waited = try await Self.waitFor(waitFor, driver: snapshotDriver,
                                                    first: snapshot, seconds: seconds)
                snapshot = waited.snapshot
                lastSnapshots[Self.engineKey(args)] = snapshot
                if !waited.found {
                    waitNote = "waitFor \"\(waitFor)\" did not appear within \(seconds)s"
                        + " — this is the screen as it is now\(Self.truncationHint(snapshot))"
                        // **記法の助言はここにも要る**: 切り詰めラベルをそのまま渡した waitFor は
                        // 外れるのに、返す木には**同じ文字列が印字されている**ので照合のバグに見える
                        // (2026-08-07 実測)。scrollTo だけに出していて届いていなかった
                        + Self.notationHint(waitFor, in: snapshot) + "\n"
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
            // **すり替わりを先頭に置く**: これが起きているとき、以下の一覧は丸ごと別アプリのもので、
            // ghost 注記も scrollFrame 候補も読む意味が無い
            let switchedNote = Self.switchedAppNote(
                launched: launchedBundleIDs[Self.engineKey(args)], snapshot: snapshot)
            return text(withPendingWarnings(
                switchedNote + waitNote + backgroundNote + Self.ghostNote(snapshot)
                + (ScrollFrameCandidates.note(snapshot) ?? "")
                + Self.unlabeledClickablesNote(snapshot) + Self.ambiguousLabelsNote(snapshot)
                + Self.keyboardCoverageNote(snapshot) + Self.sliverNote(snapshot)
                + (SnapshotRenderer.truncatedLabelNote(snapshot) ?? "")
                + SnapshotRenderer.render(snapshot, flagging: Self.ghostFlags(snapshot)), args: args))

        case "ft_tap":
            let d = try await driver(args)
            if let ref = args["ref"] as? Int {
                let target = try await verifiedRef(ref, driver: d, args: args)
                try await d.tap(ref: target.ref)
                return text("tap [\(ref)] done.\(target.note)"
                    + " The screen may have changed — take a fresh ft_snapshot")
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
            var targetRef = args["ref"] as? Int
            var note = ""
            // **type は追記**(docs/commands.md)。既に入っている欄へ撃つと連結された文字列になり、
            // 戻り値が `Typed: "東京タワー"` だけだと気づけない —— 検索欄なら検索自体は成立するので
            // **沈黙した誤りになる**(2026-08-07 に Google マップで `レストラン東京タワー` を実測)。
            // 撃つ前の値は verifiedRef が撮り直した木から引く(追加の snapshot を払わない)
            var priorValue: String?
            if let ref = targetRef {
                let verified = try await verifiedRef(ref, driver: typeDriver, args: args)
                targetRef = verified.ref
                note = verified.note
                priorValue = lastSnapshots[Self.engineKey(args)]?
                    .elements.first { $0.ref == verified.ref }?.value
            }
            if let content, !content.isEmpty {
                try await typeDriver.type(ref: targetRef, text: content)
                // **ref を渡したときだけ読み返しで検証される**。iOS の XCUITest ランナーは
                // ref から対象を引けたときだけ TypeReadback の resend/deleteExcess を回し、
                // 引けない(= ref なし)ときは無検証の `typeText` へ落ちて OK を返す。
                // Android は焦点ノードを読み返すので ref なしでも検証される
                if targetRef == nil, !(typeDriver is AndroidDriver) {
                    // **注意書きで済ませず、ここで確かめる**: iOS の XCUITest ランナーは ref から
                    // 対象を引けたときだけ TypeReadback を回すので、ref なしは無検証で OK が返る。
                    // 木は `focused` を持っているのだから、撮り直して**どこへ入ったか**を名指しできる
                    // (Android は焦点ノードを読み返すのでこの1枚は払わない)
                    note += await Self.typedIntoNote(driver: typeDriver, expected: content,
                                                     snapshot: try? freshSnapshot(typeDriver, args: args))
                }
                if let prior = priorValue, !prior.isEmpty {
                    note += " (the field already held \"\(SnapshotRenderer.truncate(prior, 30))\";"
                        + " ft_type appends, so it now reads"
                        + " \"\(SnapshotRenderer.truncate(prior + content, 60))\"."
                        + " Call ft_clear_input first if you meant to replace it)"
                }
            } else if let ref = targetRef {
                // 入力せず Enter だけ撃つときも、対象が指定されていればフォーカスを立ててから。
                // **タップの直後に撃たない**(下の awaitFocus): 直前に別の欄へ入力していると
                // フォーカスの移動が間に合わず、Enter が**前の欄**へ飛んで黙って何も起きない
                // (2026-08-06 に Android で観測。ime カウンタが増えなかった)
                try await typeDriver.tap(ref: ref)
                note += await awaitFocus(ref: ref, driver: typeDriver, args: args)
            }
            guard wantsEnter else { return text("Typed: \"\(content ?? "")\"\(note)") }
            try await typeDriver.pressEnter()
            return text((content.map { "Typed: \"\($0)\" and pressed Enter" } ?? "Pressed Enter")
                + note)

        case "ft_swipe":
            guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
                throw MCPError("direction must be one of up/down/left/right")
            }
            try await driver(args).swipe(direction)
            // **「動いた」と断言しない**(back と同じ理由。2026-08-06)。スワイプは端に着いていれば
            // 1px も動かないし、スクロールできない画面では何も起きない
            return text("swipe \(direction.rawValue) sent."
                + " If anything moved, the old refs are stale — take a fresh ft_snapshot"
                + " before using any ref")

        case "ft_scroll_to":
            return try await scrollTo(args)

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
            // **「画面が変わった」と断言しない**(2026-08-06 の探索で外した): iOS の back は
            // 端の swipe なので、自前ナビの画面(`#btn_back` を持つ SwiftUI 等)では
            // **何も起きない**。back でアプリ自体を出てしまうこともあり、どちらも
            // 「変わった」と言い切ると誤操作の起点になる
            return text("\(target) sent. Take a fresh ft_snapshot to see the result"
                + Self.backNoOpNote(target: target, engine: engines[Self.engineKey(args)])
                + Self.backgroundedAppNote(target: target, engine: engines[Self.engineKey(args)])
                + Self.homeScreenReadNote(target: target, engine: engines[Self.engineKey(args)]))

        case "ft_clear_app_data":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId is required") }
            try await driver(args).clearAppData(bundleID: bundleID)
            return text("Cleared the data of \(bundleID). The app is stopped — ft_launch to continue")

        case "ft_clear_input":
            // ref 省略 = フォーカス中の欄(DSL の clearInput() と同じ)
            let clearDriver = try await driver(args)
            var clearRef = args["ref"] as? Int
            var clearNote = ""
            if let ref = clearRef {
                let verified = try await verifiedRef(ref, driver: clearDriver, args: args)
                clearRef = verified.ref
                clearNote = verified.note
            }
            try await clearDriver.clearInput(ref: clearRef)
            return text("cleared\(clearNote)")

        case "ft_dsl_commands":
            return dslCommands(args)

        case "ft_double_tap":
            // **座標へ畳んでから撃つ**: ref はブリッジごとに別名前空間で、501 で別ドライバへ
            // 回るときに取り直しが要る(AppDriver.doubleTap が ref を取らない理由と同じ)
            let doubleTapDriver = try await driver(args)
            let doubleTapPoint: (x: Double, y: Double)
            // **答えは渡された形で返す**: ref を渡したのに座標で返すと、tap/press
            // (`[17]` と返す)と食い違って読み手が取り違える(2026-08-07 の棚卸し)
            var doubleTapWhat: String
            var doubleTapNote = ""
            if let ref = args["ref"] as? Int {
                let element = try await verifiedElement(ref, driver: doubleTapDriver, args: args)
                doubleTapPoint = (element.frame.centerX, element.frame.centerY)
                doubleTapWhat = "[\(ref)]"
                // **ft_tap と同じ被覆にする**(ft_tap は verifiedRef 経由で遮蔽・残像・
                // 中身外し・キーボード被覆も見ている)。ここだけ見落とすと、同じ要素に対して
                // ツールごとに言うことが変わる(2026-08-08 のレビュー)。
                // keyboardFrame は verifiedElement が撮り直した木(lastSnapshots に反映済み)から採る
                doubleTapNote = RefGuard.preTapWarnings(
                    element, keyboardFrame: lastSnapshots[Self.engineKey(args)]?.keyboardFrame)
                    + RefGuard.overlapWarning(found: element, in: lastSnapshots[Self.engineKey(args)]?
                        .elements ?? [], screen: lastSnapshots[Self.engineKey(args)]?.screen
                        ?? FTRect(x: 0, y: 0, width: 0, height: 0))
            } else if let x = args["x"] as? Double, let y = args["y"] as? Double {
                doubleTapPoint = (x, y)
                doubleTapWhat = "(\(x), \(y))"
            } else {
                throw MCPError("ref or x/y is required")
            }
            try await doubleTapDriver.doubleTap(x: doubleTapPoint.x, y: doubleTapPoint.y)
            return text("double tap \(doubleTapWhat) done.\(doubleTapNote)"
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
            // **無検証であることを言う**(swipe / pinch は言っているのに drag / press だけ
            // 「done」で言い切っていた。同じ無検証なのに信頼度が違って見える)
            return text("drag (\(fromX), \(fromY)) → (\(toX), \(toY)) sent."
                + " Nothing about the result is checked — if it should have moved something,"
                + " confirm with ft_snapshot/ft_screenshot")

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
                let element = try await verifiedElement(ref, driver: pinchDriver, args: args)
                frame = element.frame
                identifier = element.identifier
            }
            try await pinchDriver.pinch(frame: frame, identifier: identifier, scale: scale,
                                        durationSeconds: args["durationSeconds"] as? Double ?? 0.5)
            return text("pinch x\(scale) done."
                // **「小さくなる」とだけ言わない**(2026-08-06 実測): 指が対象の内側に収まる分だけ
                // 小さくなることもあれば、慣性で大きくもなる(scale 2.0 の要求で累積 3.9 倍)
                + " The actual zoom can differ from what you asked for in either direction"
                + " — verify with ft_snapshot/ft_screenshot."
                + iosEngineHint("Flutter", "pinch", args: args))

        case "ft_press":
            let pressDriver = try await driver(args)
            let pressDuration = args["duration"] as? Double ?? 1.0
            if let ref = args["ref"] as? Int {
                let pressTarget = try await verifiedRef(ref, driver: pressDriver, args: args)
                try await pressDriver.press(ref: pressTarget.ref, duration: pressDuration)
                return text("press [\(ref)] done\(pressTarget.note)."
                    + " The screen may have changed — take a fresh ft_snapshot")
            }
            // **座標形は ft_tap と揃える**: ドライバは press(x:y:duration:) を要件として持つのに
            // MCP からは ref でしか呼べなかった。地図・キャンバスのように a11y 要素が無い点を
            // 長押しする操作(ピンを落とす・住所を出す)が一切書けない状態だった(2026-08-07)
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                try await pressDriver.press(x: x, y: y, duration: pressDuration)
                return text("press (\(x), \(y)) done."
                    + " The screen may have changed — take a fresh ft_snapshot")
            }
            throw MCPError("ref or x/y is required")

        case "ft_screenshot":
            let png = try await driver(args).screenshot()
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]

        case "ft_terminate":
            try await driver(args).terminate()
            // 意図して落としたので、以後の別アプリの木は「すり替わり」ではない
            launchedBundleIDs[Self.engineKey(args)] = nil
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
                + (fm.available ? "" : "\n   " + FMDoctor.unavailableImpact)
                + "\n" + (vision.available ? "✅ " : "⚠️ ") + vision.detail)

        default:
            throw MCPError("unknown tool: \(tool)")
        }
    }

    private func text(_ string: String) -> [[String: Any]] {
        [["type": "text", "text": string]]
    }

    /// 溜まっているプロファイル警告を先頭に付けて1度だけ吐き出す
    private func withPendingWarnings(_ body: String, args: [String: Any]) -> String {
        let key = Self.engineKey(args)
        guard let warnings = pendingWarnings.removeValue(forKey: key), !warnings.isEmpty
        else { return body }
        return warnings.joined(separator: "\n") + "\n" + body
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
                    ? "No scenarios (add a @TestClass under TestProjects/\(project.name)/scenarios/)"
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

    /// dry-run(**デバイス不要**)。コンパイルの次・デバイス実行の前に挟む検証で、デバイスを
    /// 使わずにセレクタ構文エラー・到達しない scene・アサーション0の expectation を落とす。
    /// デバイスに触れないのでロケータが実在するかは分からない(それは ft_run_scenario の仕事)
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
        "type": "integer", "description": "iOS bridge port (default: the running bridge)",
    ]
    static let serialProperty: [String: Any] = [
        "type": "string", "description": "Android device serial (default: the connected device)",
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
        tool("ft_launch", "Launch the app (if already running, restarts from the first screen). "
            + "iOS: com.apple.springboard attaches to the home screen instead, without launching "
            + "anything — that is how you read the home screen or a system dialog", [
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (Android)"],
        ], required: ["bundleId"]),
        tool("ft_snapshot", "Get the element list of the current screen. Each line: [ref] Type \"label\" id=... (x,y WxH). "
            + "A line marked scroll is a scrolling container you can pass as scrollFrame. "
            + "Use these refs for tap/type. With waitFor it polls for you instead of you calling this again", [
            "waitFor": ["type": "string", "description": "Wait until this selector is on screen. Same syntax as the DSL: #id, a label, .type, a||b"],
            "timeout": ["type": "number", "description": "Seconds to wait for waitFor (default 5, same as the DSL)"],
        ]),
        tool("ft_tap", "Tap an element (ref) or a coordinate (x,y). x/y match the ft_snapshot frames (iOS=pt / Android=px), not screenshot pixels. "
            + "A ref is re-checked against a fresh tree before the tap, so a ref that moved is retargeted and "
            + "one that is gone is refused; a scroll leftover is tapped with a warning naming what "
            + "it may have hit instead. " + coordinateCaveat, [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
        ]),
        tool("ft_type", "Type text (with ref, taps that field first and waits for it to take focus). "
            + "It APPENDS to whatever the field already holds — call ft_clear_input first to replace. "
            + "text is required unless pressEnter is true — pressEnter alone fires the Enter/IME action. "
            + "Typing itself never closes the soft keyboard. pressEnter fires the Enter/IME action — on "
            + "UIKit/SwiftUI the return key usually closes the keyboard as a side effect; Compose and Flutter "
            + "keep it open, so do not retry pressEnter waiting for the keyboard to go away.", [
            "text": ["type": "string", "description": "Omit it to fire Enter only"],
            "pressEnter": ["type": "boolean", "description": "Fire Enter/IME action (search, submit)"],
            "ref": ["type": "integer", "description": "Reference number of the input field (defaults to the focused element)"],
        ]),
        tool("ft_swipe", "Swipe one screenful (up = scroll down the content). To reach a specific element use "
            + "ft_scroll_to instead — it stops on the element and hands back fresh refs", [
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
        ], required: ["direction"]),
        tool("ft_scroll_to", "Scroll until a selector is on screen, then return the fresh element list. "
            + "Use this instead of repeating ft_swipe + ft_snapshot: it runs the same search the DSL's "
            + "scrollTo does (settling, container-sized steps, overshoot recovery) and the refs it returns "
            + "are taken after the scroll", [
            "selector": ["type": "string", "description": "Same syntax as the DSL: #id, a label, .type, a||b"],
            "direction": ["type": "string", "enum": ["down", "up", "right", "left"],
                          "description": "Content direction to read towards (default down)"],
            "scrollFrame": ["type": "string",
                            "description": "Selector of the scrolling container to search inside (e.g. #list_rows). "
                                + "Pass it when the screen has more than one scrollable area — ft_snapshot marks "
                                + "those lines scroll and says so at the top"],
            "maxSwipes": ["type": "integer", "description": "Swipe limit (default 8, same as the DSL)"],
        ], required: ["selector"]),
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
            + "tools use XCUITest, where Compose apps never receive a double tap (see docs/commands.md). "
            + coordinateCaveat, [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
        ]),
        tool("ft_drag", "Drag between two coordinates — the only way to pan diagonally (set both axes). "
            + "Coordinates use the same system as the ft_snapshot frames (iOS=pt / Android=px). "
            + "A long durationSeconds drags slowly and leaves no inertia; a short one flicks. "
            + coordinateCaveat, [
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
        tool("ft_press", "Long-press an element (ref) or a coordinate (x,y). Use x/y on a map or "
            + "canvas, where the point you want has no element of its own. " + coordinateCaveat, [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "duration": ["type": "number", "description": "Seconds (default 1.0)"],
        ]),
        tool("ft_screenshot", "Take a screenshot (returns an image). Use it for visual verification", [:]),
        tool("ft_terminate", "Terminate the running app", [:]),
        tool("ft_list_scenarios", "List the Swift DSL scenarios (TestProjects/<name>/scenarios/). Builds automatically; compile errors are returned as-is", [
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
            "port": ["type": "integer", "description": "iOS bridge port (default: the running bridge)"],
            "serial": ["type": "string", "description": "Android device serial (default: the connected device)"],
        ], required: ["id"]),
        tool("ft_list_projects", "List the test projects (TestProjects/) and their run profiles", [:],
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

    /// ref なしで入力したあと、**実際にどの欄へ入ったか**を名指しする。
    /// 焦点が無ければそれ自体が答え(撃った先が無かった = 沈黙した誤り)。
    /// 値が読めるなら期待した文字列が入っているかまで見る
    static func typedIntoNote(driver: AppDriver, expected: String?,
                              snapshot: SnapshotResponse?) async -> String {
        guard let snapshot else { return " (could not re-read the screen to confirm where it went)" }
        guard let field = snapshot.elements.first(where: { $0.focused == true }) else {
            return " (warning: nothing has input focus now, so the text may have gone nowhere"
                + " — tap the field by ref first)"
        }
        let name = RefGuard.describe(field)
        guard let value = field.value.map(FlowMatchMode.stripZeroWidthCharacters), !value.isEmpty
        else { return " (into \(name); its value could not be read back)" }
        guard let expected, !value.contains(expected) else {
            return " (into \(name), which now reads \"\(SnapshotRenderer.truncate(value, 40))\")"
        }
        return " (warning: it went into \(name), but that field reads"
            + " \"\(SnapshotRenderer.truncate(value, 40))\" — the text may not have landed)"
    }

    /// 座標形は ref の安全網(遮蔽・残像・中身外し)を1つも通らない。**設計上そうなる**が、
    /// 説明に書いていないと読み手が ref 形と同じ信頼度だと思い込む(2026-08-07 の棚卸し)
    static let coordinateCaveat = "Coordinates skip the ref safety checks (occlusion, scroll"
        + " leftovers, a container whose centre misses its own content), so prefer a ref when the"
        + " element is in the tree."

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

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
    /// 探索中の操作列(ft_draft_scenario の材料。InteractionLog 参照)
    var interactions = InteractionLog()
    /// drivers と同じキーで**直前にエージェントへ返した木**を覚える。ref を撃つ直前に
    /// 撮り直して同じ要素を引き直すための起点(RefGuard 参照)。
    /// **ref はスナップショットごとに振り直される**ので、番号ではなく要素の同一性で照合する
    var lastSnapshots: [String: SnapshotResponse] = [:]
    /// **ref の世代管理**(2026-08-10)。ブリッジは撮るたびに ref を振り直すので、
    /// 「1つ前の木」しか起点にしない `lastSnapshots` だけでは、それより前の snapshot の ref を
    /// 撃たれたときに「たまたま同じ番号を持つ別要素」へ黙って当たる(実害: ft_scroll_to の後に
    /// 旧 ref [42](戻るボタン)を叩いたら新しい木の [42](静的テキスト「料金:」)に当たった)。
    /// MCP 層で ref にオフセット(`base`)を掛け、セッション内で全世代の ref を一意にする ——
    /// ブリッジには一切触らない。古い順に並び、**直近5世代だけ**保持する(adoptSnapshot 参照)
    var refGenerations: [String: [(base: Int, snapshot: SnapshotResponse)]] = [:]
    /// 次の新しい世代に割り当てる base(engineKey ごと)。**単調増加のみ**(世代を跨いで再利用しない
    /// ことで、セッションを通じて ref が一度も衝突しないことを保証する)
    var nextRefBase: [String: Int] = [:]
    /// 保持する世代数の上限。**5**: 「1つ前の木」しか見ない従来より十分に厚いが、
    /// 無制限にするとセッションが長引くほど探索コストと保持量が線形に増える
    private static let maxRefGenerations = 5
    /// scroll_to の空打ちゲート用 uiFramework(engineKey ごと)。**成功だけ**記憶する —
    /// 失敗(nil)を覚えると、suspend 中の1回のタイムアウトで判定がセッション全体に固定される
    var uiFrameworkHints: [String: String] = [:]
    /// 特定できたシミュレータの udid(engineKey ごと)。xcuitest のマーカー判定に使う
    var udids: [String: String?] = [:]
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
    /// ft_screenshot の鮮度判定用(engineKey ごと)。**静止画面の2連続 ft_screenshot は PNG が
    /// バイト単位で同一**(2026-08-10 実測: Android 83,028B×2 / iOS 95,076B×2)—— これが成り立つから
    /// 「木は変わったのに絵が前回と同一 = 古いフレームを返し続けている」と言える(treeFingerprint の
    /// 前後比較単独では拾えなかった動機の事象: 木は新しいのに絵だけ古い)
    var lastScreenshots: [String: (imageHash: Int, treeFingerprint: Int)] = [:]
    /// プロファイル解決で出た警告(未解決のデバイス名など)。**次に返す応答へ1度だけ**混ぜる。
    /// stderr だけに出していたときは MCP クライアントに一切届かなかった
    var pendingWarnings: [String: [String]] = [:]
    /// **セッション(プロセス)を通じて1度だけ**満額で説明した注記の鍵。以後は短縮形にする
    /// (`once` 参照)。engineKey を跨いで共有する — 説明の中身は接続先に依らず同じ文なので、
    /// 機ごとに割ると同じ長文が機の数だけ繰り返される
    var explainedNotes: Set<String> = []
    /// 応答の書き出し口。**stdout は JSON-RPC 専用**(診断を混ぜるとクライアントのパースが壊れる)
    private let write: (Data) -> Void
    /// ドライバ生成の差し替え口。nil = 実デバイスを解決する(既定)
    private let makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)?
    /// スナップショットの `#id` を台帳へ落とす口。**テストは必ず差し替える**
    /// (既定は実プロジェクトの `.ftester/` へ書くので、テストが利用者の資産を汚す)
    private let recordSnapshot: (_ snapshot: SnapshotResponse, _ platform: String,
                                 _ args: [String: Any]) -> Void

    /// 差し替えドライバの経路でも版ズレのゲートを通すか(テスト用。既定 off。
    /// 実運用の経路は常に通る。理由は driver(_:) のコメント)
    private let checksVersionOnInjectedDriver: Bool

    init(write: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) },
         makeDriver: ((_ args: [String: Any]) async throws -> AppDriver)? = nil,
         recordSnapshot: ((_ snapshot: SnapshotResponse, _ platform: String,
                           _ args: [String: Any]) -> Void)? = nil,
         checksVersionOnInjectedDriver: Bool = false) {
        self.write = write
        self.makeDriver = makeDriver
        self.recordSnapshot = recordSnapshot ?? MCPServer.recordSelectors
        self.checksVersionOnInjectedDriver = checksVersionOnInjectedDriver
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
                // FTCore 由来の文には CLI のフラグ(`--project`)が書いてある。MCP の読み手が
                // 渡せるのは同名の**引数**なので、ここで一度だけ言い換える(MCPMessageText)
                reply(id: id, result: [
                    "content": [["type": "text",
                                 "text": "Error: "
                                    + MCPMessageText.forMCP(error.localizedDescription)]],
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
            let driver = try await makeDriver(args)
            // **差し替え経路でもゲートを通せるようにする**(G): 素通しにすると拒否そのものが
            // 一度も実行されず、文言だけ検証して安心する形になる。ただし既定は off ——
            // 版照合は status() を1回撃つので、呼び出し列を固定している既存テストが軒並みずれる。
            // 実運用(makeDriver 無し)の経路は下で**常に**通る
            if checksVersionOnInjectedDriver {
                try await enforceVersion(driver: driver, key: key, args: args)
            }
            return driver
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
            if case .ios(let provisioned, _) = target { udids[key] = provisioned.udid }
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
            // **profile 経由もゲートを通す**(G-2 の「全操作系」): BridgeProvisioner が版で
            // 再利用可否を決めるので普段はここで落ちないが、**落ちないことと検査しないことは別**
            // —— 供給の判断とホストの期待がズレた回に、黙って旧ブリッジを操作させない
            try await enforceVersion(driver: created, key: key, args: args)
            return created
        }

        let platform = (args["platform"] as? String)
            ?? ProcessInfo.processInfo.environment["FTESTER_PLATFORM"]
            ?? "ios"
        // **udid → port の解決はここ1箇所**(H-2)。port は残す(既存の呼び出しを壊さない)
        let explicitPort = try await Self.portForIOS(args)
        let key = Self.driverCacheKey(platform: platform, port: explicitPort.map(Int.init),
                                      serial: args["serial"] as? String)
        if let cached = drivers[key] { return cached }
        let created: AppDriver
        switch platform {
        case "ios":
            let port = try await Self.resolveIOSPort(explicit: explicitPort)
            let resolved = await ExploreDriverResolver.resolve(
                preferred: port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            created = resolved.driver
            engines[key] = resolved.engine
            udids[key] = resolved.udid
            connections[key] = "port \(port)"
            // **稼働中のブリッジが古いままではないか**を1度だけ確かめる(2026-08-06 に踏んだ)。
            // profile 経由は BridgeProvisioner が版で再利用可否を決めるが、**この経路は
            // 生きているポートへ素で繋ぐだけ**なので、版を上げても旧ランナーが使われ続ける。
            // 実害: ブリッジ側の修正2件を入れて版も上げたのに、ft_snapshot は直る前の木を
            // 返し続け、`bridge down && bridge up` するまで「直っていない」に見えた。
            // Android は AndroidBridge が expectedBridgeVersionCode で入れ替えるのでこの穴が無い
            try await enforceVersion(driver: created, key: key, args: args)
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

    /// 版ズレを既定で拒否する(G)。押し通しは `allowVersionSkew: true` で、その場合は
    /// **毎回の応答に警告が付き続ける**(1度言って黙らない)。
    /// 拒否したときは覚えたドライバを捨てる —— 建て直した後に古い判定が残らないように
    func enforceVersion(driver: AppDriver, key: String, args: [String: Any]) async throws {
        guard let skew = await Self.bridgeVersionSkew(driver: driver) else {
            versionSkew[key] = nil
            return
        }
        versionSkew[key] = skew
        guard args["allowVersionSkew"] as? Bool == true else {
            drivers[key] = nil
            throw MCPError(skew)
        }
        pendingWarnings[key, default: []].append(Self.skewOverrideWarning(skew))
    }

    /// 繋いだブリッジの版が食い違っているときの文。一致・判定不能なら nil。
    ///
    /// **既定は拒否**(G。2026-08-09 に方針を反転した): 以前は警告だけで通していたが、
    /// MCP の出力はシナリオへ書く文字列を供給するためにあるので、**古いブリッジの出す古い注記から
    /// 誤ったセレクタが書き込まれる**ほうが「セッションが止まる」より高くつく。
    /// アドホック探索なら警告で足りるが、生成が目的だとそうではない。
    ///
    /// **どちらが新しいかを明示する**(G-4): 対処が変わる ——
    /// ブリッジが古い = 建て直す / ホストが古い = こちらを建て直す(or pull)。
    /// **判定できないときは黙る**(旧ブリッジは版を返さない = nil。それを「古い」と断じると常時警告)
    static func bridgeVersionSkew(driver: AppDriver) async -> String? {
        guard let running = try? await driver.status().protocolVersion,
              running != BridgeAPI.bridgeProtocolVersion else { return nil }
        let expected = BridgeAPI.bridgeProtocolVersion
        let side = running > expected
            ? "the bridge is NEWER than this build (v\(running) > v\(expected)) —"
                + " your ftester-mcp binary is stale, so rebuild it"
                + " (swift build --product ftester-mcp) or pull"
            : "the bridge is OLDER than this build (v\(running) < v\(expected)) —"
                + " restart it with `ftester bridge down --all && ftester bridge up`"
        return "bridge protocol mismatch: \(side)."
            + " Refusing to operate: a stale bridge answers with the behaviour and the notes of"
            + " its own version, and selectors written from those notes are silently wrong."
            + " Pass allowVersionSkew: true to proceed anyway."
    }

    /// 版ズレのまま押し通されたときに毎回付ける警告(G-3)。**1度言って黙らない** ——
    /// 押し通した事実は、その後の全応答の信頼度に掛かり続ける
    static func skewOverrideWarning(_ skew: String) -> String {
        "⚠️ allowVersionSkew: proceeding despite a bridge/host mismatch. \(skew)"
    }

    /// 接続先の宛先(ft_status が見せる)。**#2/#5 の取り違えは「今どこに繋がっているか」が
    /// 見えないまま起きる** —— 既定 8123 が死んでいても、はぐれエミュレータを掴んでいても、
    /// 応答だけ見ると正常に見える
    var connections: [String: String] = [:]

    /// 版ズレの内容(engineKey ごと)。ft_status が「失敗するが理由を返す」ために覚えておく
    var versionSkew: [String: String] = [:]

    /// `udid` / `port` から iOS の宛先ポートを決める(H-2)。**両方渡されたら port を優先**し、
    /// **食い違うなら明示的に失敗する** —— 黙ってどちらかを採ると、読み手は指したつもりの
    /// デバイスと別の機を操作したことに最後まで気付けない。
    /// どちらも無ければ nil(従来どおり resolveIOSPort が既定ポート → 探索の順で決める)
    static func portForIOS(_ args: [String: Any]) async throws -> UInt16? {
        let port = (args["port"] as? Int).map(UInt16.init)
        guard let udid = (args["udid"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return port
        }
        return try reconcilePort(port, udid: udid, udidPort: await bridgePort(forUDID: udid))
    }

    /// `port` と `udid` の突き合わせ。**走査から切り離した純粋関数** —— 実ブリッジが要ると
    /// 「食い違い」の枝がテストで一度も実行されず、判定を壊しても素通しする
    /// (2026-08-09 の変異テストで実際に素通しした)
    static func reconcilePort(_ port: UInt16?, udid: String, udidPort: UInt16?) throws -> UInt16? {
        guard let udidPort else {
            throw MCPError("no running bridge is on udid \(udid)."
                + " ft_list_devices shows which devices have one; start it with"
                + " `ftester bridge up` (a device without a bridge cannot be driven from MCP)")
        }
        guard let port else { return udidPort }
        guard port == udidPort else {
            throw MCPError("port \(port) and udid \(udid) point at different devices"
                + " (that udid is on port \(udidPort)). Pass only one of them")
        }
        return port
    }

    /// udid を申告している稼働中ブリッジのポート。**申告が無いブリッジ(旧版)は素通し** ——
    /// 「見つからない」と「そのブリッジは答えられない」を混ぜないため、見つからなければ nil
    static func bridgePort(forUDID udid: String) async -> UInt16? {
        for found in await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find()) {
            guard let client = try? BridgeClient(port: found.port),
                  let status = try? await client.status(), status.udid == udid else { continue }
            return found.port
        }
        return nil
    }

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
    /// StepExecutor)なので、ここで書ける式はそのままシナリオへ持ち込める。
    ///
    /// **完全一致が出るまで満額待つ**(2026-08-10。案B): 周回ごとに部分一致の有無だけ
    /// (`notationHint` はメモリ上の計算で往復を払わない)見て、最初に見えた経過秒とヒントを
    /// 覚える。**早期打ち切りはしない** —— ローディング中のプレースホルダが部分一致で先に出て、
    /// 本命が後から来る画面があるため(打ち切ると本命を待ち損ねる)
    /// `refetched`: 撃ち直しが1回でも起きたか(2026-08-10 の ref 世代管理で追加)。false のとき
    /// `snapshot` は引数 `first` そのもの(値も ref 番号も変わっていない)。呼び手はこれを見て
    /// `adoptSnapshot` を通すかどうかを決める —— **通さないと世代が進まない従来どおりの結果に
    /// なるだけで無害だが、通すと事故る**: `first` は既にセッション ref(base 込み)なので、
    /// native 前提の adoptSnapshot にそのまま渡すと素の native と誤認して余計な世代を作る
    static func waitFor(_ selector: String, driver: AppDriver, first: SnapshotResponse,
                        seconds: Double) async throws
        -> (found: Bool, snapshot: SnapshotResponse, partialSeenAfter: Double?, partialHint: String,
            refetched: Bool) {
        var partialSeenAfter: Double?
        var partialHint = ""
        func notePartial(_ snapshot: SnapshotResponse, elapsed: Double) {
            guard partialSeenAfter == nil else { return }
            let hint = notationHint(selector, in: snapshot)
            guard !hint.isEmpty else { return }
            partialSeenAfter = elapsed
            partialHint = hint
        }
        if matches(selector, in: first) { return (true, first, nil, "", false) }
        notePartial(first, elapsed: 0)
        let start = Date()
        let deadline = start.addingTimeInterval(seconds)
        var latest = first
        var refetched = false
        while Date() < deadline {
            try await Task.sleep(for: .seconds(waitPollSeconds))
            // **キャッシュを捨てて撮る**: 同じ木を読み続けると、出ていても永遠に出ない
            latest = driver.supportsCacheBypass
                ? try await driver.snapshot(bypassingCache: true) : try await driver.snapshot()
            refetched = true
            if matches(selector, in: latest) { return (true, latest, nil, "", true) }
            notePartial(latest, elapsed: Date().timeIntervalSince(start))
        }
        // ループが1周も回らなかった(seconds <= 0 等)ときは latest === first のまま = 未撃ち直し
        return (false, latest, partialSeenAfter, partialHint, refetched)
    }

    /// セレクタ式(`#id` / ラベル / `.type` / `||` 等)がこの画面に1つでも当たるか
    static func matches(_ selector: String, in snapshot: SnapshotResponse) -> Bool {
        let parsed = FTSelector.parse(selector)
        return ([parsed.primary] + parsed.fallbacks).contains { locator in
            !(StepExecutor.resolvedCandidates(locator, elements: snapshot.elements) ?? []).isEmpty
        }
    }

    /// 要素木の軽量指紋(ft_navigate の back 判定・ft_screenshot の鮮度判定で使う)。要素数 +
    /// 各要素の (type, identifier, label, frame の整数丸め)を畳む。
    /// **ref は含めない**(2026-08-10): MCP 層が ref にオフセットを掛けて世代管理するため
    /// (adoptSnapshot 参照)、同じ木でも取得経路(native のまま/セッション ref に振り直し済み)で
    /// 番号が変わり得る。含めると同じ木を「別物」と誤検知して鮮度警告が偽陽性になる。
    /// **単独では「木が安定したまま絵だけ古い」形を拾えない**(木を比べる方法の限界)。
    /// ft_screenshot はこれを画像ハッシュとの併用(lastScreenshots 参照)で補う
    static func treeFingerprint(_ snapshot: SnapshotResponse) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.elements.count)
        for element in snapshot.elements {
            hasher.combine(element.type)
            hasher.combine(element.identifier)
            hasher.combine(element.label)
            hasher.combine(Int(element.frame.x.rounded()))
            hasher.combine(Int(element.frame.y.rounded()))
            hasher.combine(Int(element.frame.width.rounded()))
            hasher.combine(Int(element.frame.height.rounded()))
        }
        return hasher.finalize()
    }

    /// PNG 生バイトのハッシュ(ft_screenshot の鮮度判定用)。**縮小前のバイト列**を渡すこと ——
    /// JPEG 再エンコードは決定的でない可能性があるため、比較は常に生 PNG で行う
    static func hashBytes(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data)
        return hasher.finalize()
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
    /// 1つでもあると黙って古い木に戻る)。
    ///
    /// 取得直後に `adoptSnapshot` を通す — ブリッジ由来の native ref をセッション ref へ
    /// 振り直すのはここが唯一の入口(waitFor 経路だけ例外。呼び出し側で個別に通す)
    private func freshSnapshot(_ driver: AppDriver, args: [String: Any]) async throws
        -> SnapshotResponse {
        let native = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
        return adoptSnapshot(native, args: args)
    }

    /// ref 同一性の比較キー。(ref, type, identifier, label) — 値/frame/focused の変化では
    /// 世代を進めない(adoptSnapshot 参照)ので、この4つだけを見る
    private struct RefIdentity: Hashable {
        let ref: Int
        let type: String
        let identifier: String?
        let label: String?
    }

    private static func identity(_ element: ElementInfo, base: Int) -> RefIdentity {
        RefIdentity(ref: element.ref - base, type: element.type,
                   identifier: element.identifier, label: element.label)
    }

    /// `element` の ref だけ差し替えたコピー(ElementInfo は struct。他フィールドは素通し)
    private static func withRef(_ element: ElementInfo, _ ref: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: element.type, identifier: element.identifier,
                   label: element.label, value: element.value, placeholder: element.placeholder,
                   enabled: element.enabled, frame: element.frame, depth: element.depth,
                   checked: element.checked, web: element.web, focused: element.focused,
                   scrollable: element.scrollable, z: element.z, range: element.range)
    }

    /// `snapshot.elements` の ref に一律 `base` を足したコピー。offscreen の ref は触らない
    /// (ブリッジは常に 0 を送るスクロールヒントで、要素解決には使われない — BridgeDTO 参照)
    private static func remapped(_ snapshot: SnapshotResponse, base: Int) -> SnapshotResponse {
        guard base != 0 else { return snapshot }
        var copy = snapshot
        copy.elements = snapshot.elements.map { withRef($0, $0.ref + base) }
        return copy
    }

    /// **ref の世代管理の本体**。ブリッジから来た native な snapshot を受け取り、セッション内で
    /// 一意な ref を持つ snapshot へ変換して返す。ブリッジは撮るたびに ref を振り直すので、
    /// 何もしないと「1つ前の木」より前の snapshot の ref を撃たれたとき、たまたま同じ番号を
    /// 持つ別要素へ黙って当たる(冒頭のコメント参照)。
    ///
    /// **同一性が変わらなければ base を使い回す**: 画面が動いていないのに ref を変えると、
    /// 撮り直すたびに番号が変わってエージェントを混乱させる。ラベルが1つでも変われば
    /// (時計等)世代は進むが、それ自体は無害 —— stale 判定は「受領時点で最新だったか」で行う
    /// (resolveSessionRef 参照)ので、無関係な世代の増加が誤警告を増やすことはない。
    /// **最初の世代は base 0**(= 従来の ref とビット単位で同じ)なので、世代が1本の間は
    /// 応答が今までと完全に一致する。
    private func adoptSnapshot(_ native: SnapshotResponse, args: [String: Any]) -> SnapshotResponse {
        let key = Self.engineKey(args)
        if var generations = refGenerations[key], let last = generations.last {
            let nativeIdentity = Set(native.elements.map { Self.identity($0, base: 0) })
            let lastIdentity = Set(last.snapshot.elements.map { Self.identity($0, base: last.base) })
            if nativeIdentity == lastIdentity {
                // 同じ木 — base を使い回し、最新世代の内容だけ最新化する(frame/value/focused 等)
                let remapped = Self.remapped(native, base: last.base)
                generations[generations.count - 1] = (base: last.base, snapshot: remapped)
                refGenerations[key] = generations
                lastSnapshots[key] = remapped
                return remapped
            }
        }
        let base = nextRefBase[key] ?? 0
        let remapped = Self.remapped(native, base: base)
        var generations = refGenerations[key] ?? []
        generations.append((base: base, snapshot: remapped))
        if generations.count > Self.maxRefGenerations {
            generations.removeFirst(generations.count - Self.maxRefGenerations)
        }
        refGenerations[key] = generations
        let maxNativeRef = native.elements.map(\.ref).max() ?? -1
        nextRefBase[key] = base + maxNativeRef + 1
        lastSnapshots[key] = remapped
        return remapped
    }

    /// セッション ref から要素を引く。世代を新しい順に探し、最初に見つかった世代の要素を返す。
    /// `isStale` = 最新世代以外で見つかった(= 撮り直した後にもっと新しい木が出ている)。
    ///
    /// **stale 判定はこの呼び出し時点の最新世代とだけ比べる**: 呼び手(verifiedRef 等)が
    /// この後で自分で撮り直して世代を進めても、それはエージェントが ref を送った**後**の話なので
    /// stale 扱いにしない。ここを先に評価してから撮り直すという順序を崩すと、時計のラベル変化
    /// だけで世代が進むたびに全タップへ偽の「older snapshot」警告が付く
    private func resolveSessionRef(_ ref: Int, args: [String: Any])
        -> (element: ElementInfo, isStale: Bool)? {
        guard let generations = refGenerations[Self.engineKey(args)] else { return nil }
        for (offset, generation) in generations.enumerated().reversed() {
            if let element = generation.snapshot.elements.first(where: { $0.ref == ref }) {
                return (element, offset != generations.count - 1)
            }
        }
        return nil
    }

    /// `ref` を含む世代の snapshot 全体(movedTogether の兄弟比較に使う「同じ世代の他の要素」用。
    /// resolveSessionRef と同じ探索だが、要素1件ではなく世代の全体が要る)
    private func generationSnapshot(containing ref: Int, args: [String: Any]) -> SnapshotResponse? {
        refGenerations[Self.engineKey(args)]?.reversed()
            .first { $0.snapshot.elements.contains { $0.ref == ref } }?.snapshot
    }

    /// セッション ref → native ref(ブリッジへ渡す番号)。**最新世代の base を引くことでしか
    /// 正しく戻せない** —— 渡してよいのは verifiedRef/verifiedElement が返した「撮り直した後の」
    /// ref だけという規約(古い世代の ref を渡すと、その世代の base を引いても、ブリッジは
    /// とうにその番号を再利用しているので無効)。世代が無ければ素通し(従来どおり)
    private func nativeRef(_ sessionRef: Int, args: [String: Any]) -> Int {
        guard let last = refGenerations[Self.engineKey(args)]?.last else { return sessionRef }
        return sessionRef - last.base
    }

    /// スナップショット本文(注記一式 + 木)。ft_snapshot と `snapshotAfter` が共有する ——
    /// **2つ目の組み立てを作らない**(注記を1つ足したときに片方だけ出る事故を防ぐ)。
    /// `extraNote` は ft_snapshot の waitFor 用(すり替わりの直後・他の注記より前に置く)
    private func snapshotBody(_ snapshot: SnapshotResponse, driver: AppDriver,
                              args: [String: Any], extraNote: String = "") async -> String {
        // **背面のアプリのツリーを「今の画面」として返さない**: XCUITest の snapshot は
        // セッションのアプリに閉じているので、**別のアプリが前面に来ても同じ木を返し続ける**。
        // 実測(2026-08-05・シミュレータで確定。症状の初出は iPhone 実機):
        // ステータスバーの「◀ 元のアプリへ」を踏んだタップで前面が別アプリに替わったのに、
        // snapshot は元アプリの画面を返し、エージェントからは「タップが効かない」に見えた
        let backgroundNote = await Self.backgroundedSessionNote(snapshot, driver: driver)
        // **すり替わりを先頭に置く**: これが起きているとき、以下の一覧は丸ごと別アプリのもので、
        // ghost 注記も scrollFrame 候補も読む意味が無い
        let switchedNote = Self.switchedAppNote(
            launched: launchedBundleIDs[Self.engineKey(args)], snapshot: snapshot)
        // **ghostNote と render で畳みの有無を揃える**: 片方だけ expandBulk を無視すると、
        // 注記は「畳んだ」と言うのに木は個別列挙、という食い違いになる
        let collapsingBulk = args["expandBulk"] as? Bool != true
        return switchedNote + extraNote + backgroundNote
            + Self.ghostNote(snapshot, collapsingBulk: collapsingBulk)
            + (ScrollFrameCandidates.note(snapshot) ?? "")
            + Self.truncationNote(snapshot) + Self.bulkExemptNote(snapshot)
            + onceNonEmpty("unlabeledClickablesNote", full: Self.unlabeledClickablesNote(snapshot),
                          short: Self.unlabeledClickablesNote(snapshot, abbreviated: true))
            + onceNonEmpty("ambiguousLabelsNote", full: Self.ambiguousLabelsNote(snapshot),
                          short: Self.ambiguousLabelsNote(snapshot, abbreviated: true))
            + Self.keyboardCoverageNote(snapshot) + Self.sliverNote(snapshot)
            + truncatedLabelNote(snapshot)
            + SnapshotRenderer.render(snapshot, flagging: Self.ghostFlags(snapshot),
                                      collapsingBulk: collapsingBulk,
                                      interactiveOnly: args["interactiveOnly"] as? Bool == true)
    }

    /// `SnapshotRenderer.truncatedLabelNote` を `once` で包む(F-6)。ft_snapshot と
    /// ft_scroll_to の両方が呼ぶので**鍵はここに1つだけ**にする(2つ目の呼び口を作らない)
    private func truncatedLabelNote(_ snapshot: SnapshotResponse) -> String {
        onceNonEmpty("truncatedLabelNote",
                    full: SnapshotRenderer.truncatedLabelNote(snapshot) ?? "",
                    short: "note: long labels are shown cut off with \"…\" — match with"
                        + " \"*prefix*\" (see the first snapshot's note).\n")
    }

    /// `snapshotAfter` が読む木は整定を待たない、という注意を初回だけ満額で出す(2026-08-10)。
    /// 実測: ft_type の直後は候補リストがまだネットワーク待ちで、waitFor 付きの ft_snapshot なら
    /// 出るものが「候補なし」に見えた
    private func immediateReadNote() -> String {
        once("snapshotAfterImmediateNote",
            full: "note: this tree was read immediately after the action, with no settling wait —"
                + " a dynamic list (search suggestions, network results) may not have populated"
                + " yet; if something you expect is missing, confirm with ft_snapshot waitFor"
                + " before concluding it is absent.\n",
            short: "(immediate read — see the first snapshotAfter note)\n")
    }

    /// 操作系ツールが `snapshotAfter: true` で返す「操作の直後の画面」。
    ///
    /// **往復を半分にするためにある**: tap/type/drag は「変わったかもしれない」で終わるので、
    /// 読み手はほぼ必ず ft_snapshot を続けて撃つ。実測(2026-08-09 のマップ探索1セッション)では
    /// 46 回の呼び出しのうち 21 回が**この確認だけの snapshot** だった。
    ///
    /// **撮るのは操作の直後**(整定は待たない)。アニメーション中の木が返ることがあるので、
    /// 期待する要素が居ないときは ft_snapshot の waitFor で待ち直す —— それはツール説明に書く。
    /// **失敗しても throw しない**: 操作自体は成功しているので、ここで throw すると
    /// 「タップは効いたのにエラーが返る」になり、読み手が操作を撃ち直して二重操作になる
    private func snapshotAfterBody(_ args: [String: Any]) async -> String {
        guard args["snapshotAfter"] as? Bool == true else { return "" }
        do {
            let snapshotDriver = try await driver(args)
            let snapshot = try await freshSnapshot(snapshotDriver, args: args)
            recordSnapshot(snapshot, snapshotDriver is AndroidDriver ? "android" : "ios", args)
            return "\n\n" + immediateReadNote()
                + (await snapshotBody(snapshot, driver: snapshotDriver, args: args))
        } catch {
            return "\n\n(snapshotAfter could not read the screen:"
                + " \(error.localizedDescription) — the action above still went through;"
                + " take an ft_snapshot yourself)"
        }
    }

    /// ref を撃つ直前の照合。**撮り直した木から同じ要素を引き直して、その新しい ref を返す**。
    /// 引けない(消えた・ghost)なら撃たずに throw する —— 沈黙した誤操作を作らないため。
    ///
    /// 直前の木を覚えていないとき(ft_snapshot を挟まずに ref を撃たれたとき)は素通しする:
    /// 照合の起点が無いので嘘の判断をするより、ブリッジの 404 に任せるほうが正しい。
    /// **どの世代にも無い ref**(何か撮った後で、それでも一致しない番号)は素通しせず throw する
    /// —— セッション内で ref は一意なので、世代があるのに見つからないのは番号の書き間違いか、
    /// 直近5世代より前の snapshot からコピーしてきた番号のどちらか(2026-08-10)。
    /// 返す ref は**セッション ref**(ブリッジへ渡す前に呼び手が `nativeRef` を通すこと)
    private func verifiedRef(_ ref: Int, driver: AppDriver,
                             args: [String: Any]) async throws -> (ref: Int, note: String) {
        guard let resolved = resolveSessionRef(ref, args: args) else {
            guard !(refGenerations[Self.engineKey(args)]?.isEmpty ?? true) else { return (ref, "") }
            throw MCPError("unknown ref [\(ref)] — it is not from any recent snapshot"
                + " (refs are per-snapshot; the last 5 snapshots were checked)."
                + " Take a fresh ft_snapshot")
        }
        let target = resolved.element
        // **isStale の注記を先頭に置く**: 何に当たったかの前に、番号の出所が古いことを言う
        // **先頭は空白・末尾に余白を残さない**(RefGuard の警告群と同じ形。ここだけ裸の
        // "note:" で始まると "done.note:" と密着し、末尾空白は次の " (selector:" と二重になる)
        let staleNote = resolved.isStale
            ? " note: [\(ref)] is from an older snapshot (refs have been renumbered since)."
                + " It was matched as \(RefGuard.describe(target)) and re-located in the current"
                + " tree — prefer refs from the latest snapshot."
            : ""
        let lastRendered = generationSnapshot(containing: ref, args: args)?.elements ?? []
        let fresh = try await freshSnapshot(driver, args: args)
        switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
        case .gone:
            throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                truncatedCount: fresh.truncatedCount))
        case .ghost(let found):
            // **拒否せず警告して撃つ**(2026-08-06 に方針を後退させた。理由は RefGuard の宣言)。
            // **キーボード被覆は先に言う**(木の遮蔽判定では原理的に拾えない事実なので、
            // 座標由来の他の警告より確度が高い)
            return (found.ref, staleNote + RefGuard.preTapWarnings(found, keyboardFrame: fresh.keyboardFrame)
                + RefGuard.ghostWarning(found: found, in: fresh.elements, screen: fresh.screen))
        case .found(let found, let moved):
            // **ラベルが変わっていないかも見る**(2026-08-10)。moved の大小とは無関係に出す ——
            // 動かずにラベルだけ変わった行も同じ危険(RefGuard.labelChangeNote 参照)
            let labelNote = RefGuard.labelChangeNote(old: target.label, new: found.label) ?? ""
            // **ghost でなくても別の物に当たり得る**2形(上に描かれた overlay / 同一矩形への
            // 積み重なり)。どちらも容器の内側なので RefGuard.relocate では .found になる
            let overlap = staleNote + RefGuard.preTapWarnings(found, keyboardFrame: fresh.keyboardFrame)
                + RefGuard.overlapWarning(found: found, in: fresh.elements, screen: fresh.screen)
            guard moved >= RefGuard.movedThreshold else { return (found.ref, overlap + labelNote) }
            // **原因までは断定できない**が、「他も同じだけ動いたか」は手元の2枚から言える。
            // 揃って動いていればスクロール等の画面全体の移動、その要素だけならレイアウト変化。
            // 切り分けの手掛かりとして出す(外部フィードバック 2026-08-06。severity は低いとのこと)
            let cause = RefGuard.movedTogether(target, found,
                                               before: lastRendered, after: fresh.elements)
            return (found.ref, staleNote + RefGuard.preTapWarnings(found, keyboardFrame: fresh.keyboardFrame)
                + RefGuard.movedNote(found: found, moved: moved, cause: cause) + labelNote)
        }
    }

    /// 要素が出るまでスクロールして探す。**探索そのものは DSL と同じ StepExecutor に委ねる**。
    ///
    /// 自前でスワイプのループを書かない理由: 整定待ち・キャッシュ回避・容器基準の刻み・
    /// ghost の掴み直し・飛び越しの拾い直し・打ち切りは全部 StepExecutor に入っており、
    /// **同じ知見の2つ目の実装を作ると必ず割れる**(docs/design.md の「契約は1箇所」)。
    /// ここは FlowStep を1つ組んで投げるだけにする = MCP で届く要素はシナリオでも届く。
    /// `scrollFrame` 引数の解決結果。**ref(整数)は rect へ、文字列は従来どおり locator へ**
    /// (FlowStep.scrollFrameRect 参照)。`original` は ref 経由のときだけ埋まり、
    /// シート展開後に同じ要素を撮り直した木から再照合して rect を作り直すのに使う
    private struct ScrollFrameArg {
        var locator: FlowLocator?
        var rect: FTRect?
        var original: ElementInfo?
        var note: String = ""
    }

    /// **ref はセレクタが書けない容器のための逃げ道**(id の重複・欠落。2026-08-10)。
    /// 既存の stale-ref 再照合(resolveSessionRef → RefGuard.relocate)を通してから frame を取る ——
    /// verifiedRef と同じ規律で、撮った時点から動いていても黙って古い座標を使わない
    private func resolveScrollFrameArg(_ args: [String: Any], driver: AppDriver) async throws
        -> ScrollFrameArg {
        if let ref = args["scrollFrame"] as? Int {
            guard let resolved = resolveSessionRef(ref, args: args) else {
                throw MCPError("scrollFrame ref [\(ref)] is unknown — it is not from any recent"
                    + " snapshot (refs are per-snapshot; the last 5 snapshots were checked)."
                    + " Take a fresh ft_snapshot")
            }
            let target = resolved.element
            let fresh = try await freshSnapshot(driver, args: args)
            switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
            case .gone:
                throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                    truncatedCount: fresh.truncatedCount))
            case .ghost(let found), .found(let found, _):
                let note = RefGuard.labelChangeNote(old: target.label, new: found.label) ?? ""
                return ScrollFrameArg(rect: found.frame, original: target, note: note)
            }
        }
        if let text = args["scrollFrame"] as? String {
            return ScrollFrameArg(locator: FTSelector.parse(text).primary)
        }
        return ScrollFrameArg()
    }

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
        let scrollFrameArg = try await resolveScrollFrameArg(args, driver: scrollDriver)
        var step = FlowStep(
            action: "scrollTo", locator: selector.primary,
            fallbacks: selector.fallbacks.isEmpty ? nil : selector.fallbacks,
            direction: direction.swipe.rawValue,
            maxSwipes: args["maxSwipes"] as? Int ?? FlowStep.defaultMaxSwipes,
            scrollFrame: scrollFrameArg.locator,
            scrollFrameRect: scrollFrameArg.rect)
        let scrollFrameLabelNote = scrollFrameArg.note.isEmpty ? ""
            : "note: the scrollFrame ref was re-checked against the current tree\(scrollFrameArg.note).\n"
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
            // profile 無しでも、resolver が udid を特定できていれば、attach 中のアプリ
            // (status.sessionBundleID)のバンドルマーカーで判定できる(成功だけ記憶)
            if let udid = udids[Self.engineKey(args)] ?? nil,
               let bundleID = (try? await scrollDriver.status())?.sessionBundleID,
               let hint = AppBundleInspector.detect(udid: udid, bundleID: bundleID,
                                                    physical: false) {
                uiFrameworkHints[Self.engineKey(args)] = hint
                uiFrameworkHint = hint
            } else {
                uiFrameworkHint = nil
            }
        } else {
            uiFrameworkHint = (try? await scrollDriver.status())?.uiFramework
            if let hint = uiFrameworkHint { uiFrameworkHints[Self.engineKey(args)] = hint }
        }
        // **1回目だけ半開きシートの逆走査を後回しにする**(defersPartialSheetRecovery の宣言参照):
        // sheetCollapsed なら下でシートを展開して再試行し、その再試行が全画面高で同じ救済を
        // 持つので、畳まれた視界での逆走査(実測 7.8s)は丸損になる
        let executor = StepExecutor(driver: scrollDriver,
                                    releasesScrollTouch: !isAndroid,
                                    uiFramework: uiFrameworkHint,
                                    defersPartialSheetRecovery: true)
        var outcome = await executor.execute(step)
        // **探索でツリーは必ず動く**ので、覚えている木を捨てて撮り直す(古い ref を残さない)
        var after = try await freshSnapshot(scrollDriver, args: args)
        // **半開きシートは自分で広げて1度だけやり直す**(2026-08-09)。この形は失敗文で
        // 「グラバーを上へ引け」と案内済みだったが、**案内できるなら自分でできる** ——
        // 実測(Apple マップの経路詳細)では、案内どおり ft_drag してから同じ ft_scroll_to を
        // 撃ち直すだけで通り、2往復を人手で払っていた。
        // 条件は StepExecutor と共有(StepNote.sheetCollapsed)。**グラバーを名前で特定できる
        // ときだけ**動かす —— 当てずっぽうのドラッグは地図やリストを勝手に動かす
        var sheetNote = ""
        if case .passed = outcome.status {} else if outcome.notes.contains(.sheetCollapsed),
           let grabber = Self.sheetGrabber(in: after) {
            let toY = after.screen.height * Self.expandedSheetTopRatio
            try await scrollDriver.drag(fromX: grabber.frame.centerX, fromY: grabber.frame.centerY,
                                        toX: grabber.frame.centerX, toY: toY,
                                        pressSeconds: 0.05, durationSeconds: 0.5)
            // **rect は展開後の木で作り直す**: シートが伸びると scrollFrameRect の元になった
            // 容器の frame も変わるので、展開前の rect のまま撃つと広がった分を探索できない。
            // 同じ要素を撮り直した木から再照合し、取れなければ従来の rect のまま(2026-08-10)
            if let original = scrollFrameArg.original {
                let expanded = try await freshSnapshot(scrollDriver, args: args)
                if case .found(let found, _) = RefGuard.relocate(
                    original, in: expanded.elements, screen: expanded.screen) {
                    step.scrollFrameRect = found.frame
                }
            }
            // **再試行は逆走査つき**(defers... を外した別 executor)。展開後も稀に部分高のまま
            // のことがあり、そこで再び後回しにすると救済がどこにも無くなる
            let retryExecutor = StepExecutor(driver: scrollDriver,
                                             releasesScrollTouch: !isAndroid,
                                             uiFramework: uiFrameworkHint)
            outcome = await retryExecutor.execute(step)
            after = try await freshSnapshot(scrollDriver, args: args)
            sheetNote = "note: the list had stopped moving inside a partially open sheet, so"
                + " [\(grabber.ref)] \(RefGuard.describe(grabber)) was dragged up to expand it and"
                + " the search was retried once.\n"
        }
        guard case .passed = outcome.status else {
            // **fail-fast(scrollFrame 未解決)は別の文で伝える**: 通常の「did not reach the
            // element」はスワイプを何本か送った前提の文言で、fail-fast は1本も送っていないので
            // そのままでは誤解を招く(2026-08-08。StepNote.scrollFrameMissing = DSL と共有した判定)
            if outcome.notes.contains(.scrollFrameMissing) {
                let reason: String
                if case .failed(let message) = outcome.status { reason = message }
                else { reason = "\(outcome.status)" }
                throw MCPError(scrollFrameLabelNote + "scrollTo \"\(selectorText)\": \(reason)"
                    + Self.scrollAlternativesHint(beforeScroll ?? after))
            }
            // **止まった時点で見えているものを一緒に返す**(外部フィードバック 2026-08-06)。
            // 「届かなかった」だけだと ft_snapshot の往復が要るうえ、**記法の誤りに気づけない**
            // —— 素のラベルは完全一致なので、「端末情報」は「端末情報を表示」に当たらない。
            // 候補を見せれば、綴り違いなのか記法(`*…*`)不足なのかがその場で分かる
            // **やり直し済みなら先に言う**: 言わないと読み手は失敗文のシート展開ヒントを
            // 読んで**もう一度同じことを手で試す**(そのぶん往復が増える)
            throw MCPError(scrollFrameLabelNote + sheetNote
                + "scrollTo \"\(selectorText)\" did not reach the element"
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
        // outcome.resolvedElement は StepExecutor が内部で撮った木の native ref を持っている
        // (MCP の ref 世代管理を経由していない)。表示するのは `after`(adoptSnapshot 済み =
        // セッション ref)の番号でなければ tap に使えないので、同一性で引き直す
        var landed = ""
        if let resolved = outcome.resolvedElement {
            switch RefGuard.relocate(resolved, in: after.elements, screen: after.screen) {
            case .found(let found, _), .ghost(let found):
                landed = " → [\(found.ref)] \(RefGuard.describe(found))"
            case .gone:
                landed = ""
            }
        }
        // **木を返す口はすべて名指しする**(2026-08-06 の掃討で漏れを見つけた)。上の再確認は
        // 「セレクタが居るか」しか見ないので、**別アプリに同じ id がある**と素通しする ——
        // E2E の 4 SUT は id・ラベルが共通契約なので、これは現に起こり得る形
        let switched = Self.switchedAppNote(
            launched: launchedBundleIDs[Self.engineKey(args)], snapshot: after)
        // scrollFrame を渡すべき当人なので、複数領域の注記もここに出す(欠陥⑪)
        let scrollAreaNote = args["scrollFrame"] == nil ? (ScrollFrameCandidates.note(after) ?? "")
            : Self.lineNote(Self.scrollAreaHint(beforeScroll ?? after, args: args))
        // **利用者が渡した式をそのまま残す**(F): 探索はセレクタで書くのが DSL の形なので、
        // ここだけは解決後の要素ではなく渡された式が正しい下書きになる
        var scrollStep = FlowStep(action: "scrollTo", locator: selector.primary)
        scrollStep.direction = direction.swipe.rawValue
        if args["scrollFrame"] != nil { scrollStep.note = "scrollFrame was used during exploration" }
        // 一覧に**スワイプ方向を出さない**: `direction.swipe` は指の動き(下を読むなら up)で、
        // 読み手が指定した意味方向とは逆になる。一覧は「どの手か」を見分けるためのものなので、
        // 逆向きの語を出すと `drop:` の選択を誤らせる
        interactions.record(InteractionLog.Entry(
            step: scrollStep, unresolved: nil, summary: "scrollTo \"\(selectorText)\""))
        // **ghostNote と render で畳みの有無を揃える**(ft_snapshot と同じ理由)
        let collapsingBulk = args["expandBulk"] as? Bool != true
        return text(switched + scrollFrameLabelNote + sheetNote + "scrolled to \"\(selectorText)\"\(landed)."
            + " The refs below are fresh\n" + scrollAreaNote
            + Self.ghostNote(after, collapsingBulk: collapsingBulk)
            + Self.truncationNote(after)
            + Self.keyboardCoverageNote(after) + Self.sliverNote(after)
            + truncatedLabelNote(after)
            // **既定で畳む**(expandBulk で戻せる): ft_scroll_to の答えは「探した1つがどこに居るか」
            // なので、地図のピンが数十行並ぶ意味は薄い。ft_snapshot と同じ規則にする
            // (2026-08-10 まではここだけ interactiveOnly を無視して常に全行を出していた)
            + SnapshotRenderer.render(after, flagging: Self.ghostFlags(after),
                                      collapsingBulk: collapsingBulk,
                                      interactiveOnly: args["interactiveOnly"] as? Bool == true))
    }

    /// シートを広げたときにグラバーを運ぶ先(画面高に対する比)。**上端そのものにはしない** ——
    /// ステータスバーへ届かせても得は無く、行き過ぎたドラッグはシートを閉じる実装がある
    static let expandedSheetTopRatio = 0.12

    /// 半開きシートのグラバー。**名前で特定できるときだけ**返す(当てずっぽうのドラッグは
    /// 地図やリストを勝手に動かすので、確信が無いなら何もしないほうが良い)。
    /// UIKit/SwiftUI のシートは `Card grabber` のような id/ラベルを出す(実測: Apple マップ)。
    ///
    /// 下半分に居るものだけを対象にする —— 既に上まで開いているグラバーを更に引いても
    /// 広がらず、実装によっては閉じる
    static func sheetGrabber(in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first { element in
            let name = ((element.identifier ?? "") + " " + (element.label ?? "")).lowercased()
            guard name.contains("grabber") else { return false }
            return element.frame.centerY > snapshot.screen.height * 0.3
        }
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
            let cleaned = e.label.map(FlowMatchMode.normalizeInvisibleCharacters)
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
            .filter {
                RefGuard.isUntappableGhost($0, in: snapshot.elements, screen: snapshot.screen)
                    // **申告されたスクロール容器の外**も同じ印に混ぜる(2026-08-09)。
                    // `isUntappableGhost` の入口は容器の*推測*なので、申告のある UIKit/SwiftUI の
                    // 木では1件も付かず、カードを送って上へ抜けた行が**可視の行と同じ形**で
                    // 並んでいた。利用者から見て原因(そこには描かれていない)も対処
                    // (ft_scroll_to で出してから撮り直す)も同じなので、印は割らない
                    || RefGuard.outsideDeclaredScroller($0, in: snapshot.elements) != nil
            }
            .map(\.ref)
    }

    /// 残像の行に付ける印。**先頭の注記だけでは足りない**(外部フィードバック 2026-08-06):
    /// エージェントは一覧の行から ref をコピーするので、その行自体に出ていないと届かない。
    ///
    /// 積み重なり(`stackedRefs`)にも同じ印を付ける —— 利用者から見ると原因は同じ
    /// 「スクロールの残骸がそこに描かれていない」で、対処(`ft_scroll_to` で出してから撮り直す)
    /// も同じ。**印を2種類に割らない**(見分けても打ち手が変わらないものを増やさない)
    static let leftoverMark = "⚠️scroll-leftover"
    /// 単に画面の外に居るだけの行。**危険度が違うので印を割る**(2026-08-09)。
    /// 上の `ghostFlags` の設計方針は「打ち手が変わらないものは割らない」だが、ここは
    /// **打ち手ではなく危険度**が違う —— leftover は「撃つと別の物に当たる」(沈黙した誤操作)、
    /// offscreen は「今そこに無い」だけ。実測(Apple マップの経路詳細)では、シートを広げた後に
    /// `y=-59` の行まで「別の物に当たるかも」と警告され、本物の leftover と同じ重さで並んでいた
    static let offscreenMark = "⚠️offscreen"

    static func ghostFlags(_ snapshot: SnapshotResponse) -> [Int: String] {
        let refs = Set(ghostRefs(snapshot)).union(RefGuard.stackedRefs(snapshot.elements))
        var flags: [Int: String] = [:]
        for element in snapshot.elements where refs.contains(element.ref) {
            // 画面外判定は DSL と共有(TapTargetGeometry)。2つ目の実装を作らない
            flags[element.ref] = TapTargetGeometry.offscreenAdvisory(
                for: element, screen: snapshot.screen) != nil ? offscreenMark : leftoverMark
        }
        return flags
    }

    /// offscreen 行がどちら側にはみ出しているか(ft_scroll_to の direction 選び用)。
    /// **はみ出し量が大きい軸を主方向にする** —— 斜めにはみ出す要素も1方向へ丸める
    /// (「7px 下 + 400px 右」のような行を両方の見出しへ重複させない)。
    /// `rawValue` はそのまま注記の見出し語、`scrollDirection` は ft_scroll_to の `direction:` の語彙
    /// (指の向きではなく「読み進める内容方向」— below な行は下方向へ読み進めると出てくる = down)
    enum OffscreenDirection: String, CaseIterable {
        case below, above
        case right = "to the right"
        case left = "to the left"

        var scrollDirection: String {
            switch self {
            case .below: return "down"
            case .above: return "up"
            case .right: return "right"
            case .left: return "left"
            }
        }
    }

    /// 実測(Apple マップの経路候補・横ページャ): 第2候補は x=401(画面幅402 の右隣ページ)に居て、
    /// 一度も表示していないのに旧文言「scrolled past」は不正確だった(2026-08-10)。
    /// 中心がどちらの縁をどれだけ超えているかを4方向とも計算し、いちばん超過が大きい方を返す
    static func offscreenDirection(of element: ElementInfo, screen: FTRect) -> OffscreenDirection {
        let cx = element.frame.centerX, cy = element.frame.centerY
        let overflows: [(OffscreenDirection, Double)] = [
            (.below, cy - (screen.y + screen.height)),
            (.above, screen.y - cy),
            (.right, cx - (screen.x + screen.width)),
            (.left, screen.x - cx),
        ]
        // 全方向が非正(=画面内)になることは呼び出し元の条件(offscreenMark 済み)上ないが、
        // 万一そろっても below を既定にして必ず1方向を返す
        return overflows.max { $0.1 < $1.1 }?.0 ?? .below
    }

    /// **collapsingBulk は render() と揃える**(2026-08-10): 畳まれる ref をここでも個別に
    /// 列挙すると、地図 POI のような大量群で出力の半分がこの注記に化ける。
    /// どの ref が畳まれるかは `SnapshotRenderer.foldedGroups` — render 本体と同じ関数 — で決める
    static func ghostNote(_ snapshot: SnapshotResponse, collapsingBulk: Bool = true) -> String {
        let flagged = ghostFlags(snapshot)
        let folded = SnapshotRenderer.foldedGroups(snapshot, flagging: flagged,
                                                   collapsingBulk: collapsingBulk)
        let leftovers = snapshot.elements.filter { flagged[$0.ref] == leftoverMark }
        let offscreens = snapshot.elements.filter { flagged[$0.ref] == offscreenMark }
        var note = ""
        if !leftovers.isEmpty {
            note += "note: the \(leftoverMark) rows below are not drawn where their frames say"
                + " (outside their scroll container, or clamped onto another row's frame),"
                + " so tapping them may hit something else:"
                + " \(listRefs(leftovers, folded: folded)). Bring them into view with ft_scroll_to first,"
                + " or verify with ft_screenshot\n"
        }
        if !offscreens.isEmpty {
            let byDirection = Dictionary(grouping: offscreens) {
                Self.offscreenDirection(of: $0, screen: snapshot.screen)
            }
            var groups: [String] = []
            var directions: [String] = []
            for direction in OffscreenDirection.allCases {
                guard let elements = byDirection[direction], !elements.isEmpty else { continue }
                groups.append("\(direction.rawValue): \(listRefs(elements, folded: folded))")
                directions.append(direction.scrollDirection)
            }
            note += "note: the \(offscreenMark) rows below are off the screen, so they are listed"
                + " but not visible — \(groups.joined(separator: " / "))."
                + " Reach them with ft_scroll_to (direction: \(directions.joined(separator: " / ")))"
                + " before using them\n"
        }
        return note
    }

    /// 注記に並べる ref の列挙。**8件で打ち切る**(全部出すと注記だけで木より長くなる)。
    /// **畳まれた ref は個別に出さず、件数だけ言う**(render 側で ×M の1行に既に畳まれているので、
    /// ここでも列挙すると二重に情報過多になる)
    private static func listRefs(_ elements: [ElementInfo], folded: [String: Set<Int>]) -> String {
        let visible = elements.filter { e in
            guard let id = e.identifier else { return true }
            return !(folded[id]?.contains(e.ref) ?? false)
        }
        var parts: [String] = []
        if !visible.isEmpty {
            let listed = visible.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
                .joined(separator: " ")
            parts.append(listed + (visible.count > 8 ? " (+\(visible.count - 8) more)" : ""))
        }
        var byID: [String: Int] = [:]
        var order: [String] = []
        for e in elements {
            guard let id = e.identifier, let group = folded[id], group.contains(e.ref) else { continue }
            if byID[id] == nil { order.append(id) }
            byID[id, default: 0] += 1
        }
        parts.append(contentsOf: order.map {
            "(+\(byID[$0]!) folded into the ×\(folded[$0]!.count) id=\($0) line below)"
        })
        return parts.joined(separator: " ")
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
        // **ref 指定は曖昧さが無い**(id の重複・欠落を避けるための逃げ道そのものなので、
        // 「他にも当たる」という注記自体が成立しない)。resolveScrollFrameArg 側で
        // 解決済みなのでここでは何も言わない
        if args["scrollFrame"] is Int { return "" }
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

    /// waitFor が空振りしたとき、画面に**近い**ラベル/id を最大3件挙げる(2026-08-10)。
    /// 実測: 経路ボタンを `waitFor "経路"` と推測したら実ラベルは「計画」で5秒空振りした。
    /// **断定しない**(「これのことでは」とは書かない) —— 似ているというだけで、
    /// 別物を待っていた可能性を否定できる材料は無い
    static func similarLabelsHint(_ selectorText: String, in snapshot: SnapshotResponse) -> String {
        let locator = FTSelector.parse(selectorText).primary
        guard let raw = locator.label ?? locator.id,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let target = FlowMatchMode.normalizeInvisibleCharacters(raw)
        var seen: Set<String> = [target]
        var matches: [String] = []
        for element in snapshot.elements where matches.count < 3 {
            if let label = element.label {
                let candidate = FlowMatchMode.normalizeInvisibleCharacters(label)
                if !candidate.isEmpty, Self.isSimilarText(target, candidate),
                   seen.insert(candidate).inserted {
                    matches.append("\"\(candidate)\"")
                }
            }
            guard matches.count < 3, let id = element.identifier, !id.isEmpty else { continue }
            if Self.isSimilarText(target, id), seen.insert("#" + id).inserted {
                matches.append("#\(id)")
            }
        }
        guard !matches.isEmpty else { return "" }
        return " note: similar labels on screen: \(matches.joined(separator: ", "))."
    }

    /// 「近い」の判定: ①どちらかがどちらかを部分文字列として含む(大文字小文字無視)
    /// ②短い文字列同士(6文字以下)なら編集距離2以下。②が無いと「経路」/「計画」のような
    /// 部分文字列関係の無い短い語の書き間違いを拾えない
    static func isSimilarText(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased(), lb = b.lowercased()
        guard la != lb else { return false }
        if la.contains(lb) || lb.contains(la) { return true }
        guard la.count <= 6, lb.count <= 6 else { return false }
        return Self.editDistance(la, lb) <= 2
    }

    /// 素朴な編集距離(挿入・削除・置換を1コストずつ)。短い文字列(≤6)にしか使わない前提の
    /// O(n*m) 実装で十分 — 長い文字列にまで広げるならもっと速いものへ替える
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i]
            for j in 1...y.count {
                current.append(x[i - 1] == y[j - 1] ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1]))
            }
            previous = current
        }
        return previous.last ?? 0
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
        if let hint = partialMatchFormHint(locator, in: snapshot.elements) {
            parts.append(hint)
        }
        return parts.joined()
    }

    /// **記法の形違い**による部分一致の空振り。実測(2026-08-10): `*武蔵野線`(endsWith)を渡して
    /// 7スクロール空振りした(正解は `*武蔵野線*`)。StepExecutor.partialMatchHint は
    /// 「素の完全一致指定が部分一致なら在る」しか見ないので、**既に endsWith/startsWith を
    /// 指定した相手が別の部分一致形でなら当たる**ケースはここで別に見る。
    /// **既に contains 形(`*x*`)を渡している相手には出ない**(mode が endsWith/startsWith
    /// でなければ何もしないので、誤って同じ助言を繰り返すことはない)
    static func partialMatchFormHint(_ locator: FlowLocator, in elements: [ElementInfo]) -> String? {
        if let label = locator.label, !label.isEmpty, let mode = locator.labelMatch,
           mode == .endsWith || mode == .startsWith,
           !elements.contains(where: { mode.matches($0.label, label) }),
           elements.contains(where: { FlowMatchMode.contains.matches($0.label, label) }) {
            return partialMatchFormText(mode: mode,
                                        typed: mode == .endsWith ? "*\(label)" : "\(label)*",
                                        suggestion: "*\(label)*")
        }
        if let id = locator.id, !id.isEmpty, let mode = locator.idMatch,
           mode == .endsWith || mode == .startsWith,
           !elements.contains(where: { mode.matches($0.identifier, id) }),
           elements.contains(where: { FlowMatchMode.contains.matches($0.identifier, id) }) {
            return partialMatchFormText(mode: mode,
                                        typed: mode == .endsWith ? "#*\(id)" : "#\(id)*",
                                        suggestion: "#*\(id)*")
        }
        return nil
    }

    private static func partialMatchFormText(mode: FlowMatchMode, typed: String,
                                              suggestion: String) -> String {
        let article = mode == .endsWith ? "an ends-with" : "a starts-with"
        let verb = mode == .endsWith ? "ends with" : "starts with"
        return " \"\(typed)\" is \(article) match and nothing \(verb) that text —"
            + " \"\(suggestion)\" (contains) would match here."
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
    /// `abbreviated`(F-6 の対象拡大・2026-08-10): 明細(`listed`)は既定と同じまま、
    /// 冒頭の長い advice だけ「初出の注記を見よ」に圧縮する。呼び手は once 経由(instance の
    /// `unlabeledClickablesNote(_:)` ラッパ)で使い分ける
    static func unlabeledClickablesNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false)
        -> String {
        let unlabeled = snapshot.elements.filter {
            $0.type == "clickable" && ($0.identifier ?? "").isEmpty && ($0.label ?? "").isEmpty
        }
        guard !unlabeled.isEmpty else { return "" }
        let listed = unlabeled.prefix(8).map { element -> String in
            scopedSelector(for: element, in: snapshot).map { "[\(element.ref)] = \($0)" }
                ?? "[\(element.ref)]"
        }.joined(separator: " ")
        let more = unlabeled.count > 8 ? " (+\(unlabeled.count - 8) more)" : ""
        let advice: String
        if abbreviated {
            advice = " — see the first snapshot's note for how to target them."
        } else {
            // **「セレクタを書けない」は嘘だった**(2026-08-09): id を持つ祖先があれば
            // `#container >> .clickable[n]` で書ける(スコープ記法。docs/commands.md)。
            // 実測(Google マップの移動手段タブ)では id もラベルも無い clickable が
            // `#directions_mode_tabs` の中に居り、この形で一意に指せた。
            // 祖先も名無しのときだけ「ref か座標しかない」が正しい
            let writable = unlabeled.contains { scopedSelector(for: $0, in: snapshot) != nil }
            advice = writable
                ? " — a plain label/#id selector cannot pick them, but the ones shown with"
                    + " \"= …\" sit inside a container that has an id, so a scenario can select them"
                    + " with that scoped selector. The rest can only be targeted by ref or coordinates."
                    + " Those scoped selectors are index-based: they break if the number of same-type"
                    + " siblings changes, so treat them as a last resort and prefer asking the app"
                    + " for an id."
                : " — they can only be targeted by ref or coordinates,"
                    + " so a scenario cannot select them with a stable selector."
        }
        return "note: \(unlabeled.count) clickable element(s) have neither a label nor an id"
            + " (\(listed)\(more))\(advice)\n"
    }

    /// **シナリオにそのまま書けるセレクタ**を1つ決める。書けないときは nil ——
    /// 「無い」を黙らず言うのが要点で、ref はセッション限りの番号なのでシナリオには書けない。
    ///
    /// 優先順(B-1・E-1 で共有。**2つ目の実装を作らない**):
    ///   1. 画面で一意な `#id` —— いちばん短く、他の画面でも通りやすい
    ///   2. 画面で一意なラベル —— id を持たない要素でも書ける
    ///   3. スコープ記法 `#容器 >> .型[n]` —— id を持つ一意な祖先があるときだけ
    ///   4. それ以外は nil
    ///
    /// **一意性は「今撮った画面の中で」**。他の画面まで保証はできないので、そこは
    /// ft_dry_run(SelectorInventory の突き合わせ)と実行に委ねる
    /// セレクタの壊れにくさ。**綴りからは判定しない**(2026-08-10)。
    /// 位置で選ぶ式は必ずしも `[n]` を含まない —— `#容器 >> .clickable` は「容器の中の最初の
    /// clickable」で、`[1]` を書いたのと同じ意味だが綴りに添字が出ない。
    /// 綴りで見ると**この形だけが「安定」と誤って印無しになる**ので、
    /// どの候補から採ったか(id/ラベル か スコープ記法 か)を持ち回る
    enum Durability {
        /// `#id` / 一意ラベル。木が変わっても指し続ける
        case stable
        /// `#container >> .type[n]`。同じ型の兄弟が1つ増減すると別要素を指す
        case indexed

        /// 一覧に添える印。安定側は無印(印が付くのは注意が要るものだけ、が読みやすい)
        var mark: String { self == .indexed ? "~" : "" }

        /// 1つだけ返すとき(ft_tap の戻り値)の但し書き
        var caution: String {
            self == .indexed
                ? " — index-based, so it breaks if the number of same-type siblings changes;"
                    + " prefer having the app expose an id"
                : ""
        }
    }

    struct SelectorNaming {
        private let idCounts: [String: Int]
        private let labelCounts: [String: Int]

        init(_ snapshot: SnapshotResponse) {
            var ids: [String: Int] = [:]
            var labels: [String: Int] = [:]
            for e in snapshot.elements {
                if let id = e.identifier, !id.isEmpty { ids[id, default: 0] += 1 }
                let label = FlowMatchMode.normalizeInvisibleCharacters(e.label ?? "")
                if !label.isEmpty { labels[label, default: 0] += 1 }
            }
            idCounts = ids
            labelCounts = labels
        }

        /// **勧める前に自分で引いてみる**(2026-08-09。実アプリ 18 枚へ当てて発覚): 候補を
        /// 組み立てただけでは書けているか分からない —— ラベルを `"…"` で囲んで出していた版は
        /// 引用符ごと literal になって**1件も当たらなかった**。記法の綴じ(先頭が `#`/`.`、
        /// `>>` や `||` を含む等)は場合分けで潰しきれないので、DSL 本体で解決して
        /// **当人が返ることを確かめてから**返す
        func selector(for element: ElementInfo, in snapshot: SnapshotResponse) -> String? {
            graded(for: element, in: snapshot)?.selector
        }

        /// セレクタと**その耐久性**。「書ける」と「壊れにくい」は別物で、同じ一覧に混ぜると
        /// 生成器は先頭を採るだけになる(2026-08-10)。`#id` と一意ラベルは木が変わっても
        /// 指し続けるが、`#container >> .type[n]` の `[n]` は**同じ型の兄弟が1つ増減しただけで
        /// 別要素を指す**ので、シナリオに書くと静かに壊れる
        func graded(for element: ElementInfo,
                    in snapshot: SnapshotResponse) -> (selector: String, durability: Durability)? {
            for candidate in candidates(for: element, in: snapshot)
            where MCPServer.picksExactly(element, with: candidate.selector, in: snapshot) {
                // **勧める形と書かれる形を揃える**(2026-08-10): 下書きは locator を
                // `FTSelector.serialize` で書き戻すので、`[1]` のような冗長な節はそこで落ちる。
                // 勧めた文字列をそのまま出すと「注記は `.clickable[1]`、コードは `.clickable`」
                // という食い違いになり、1箇所で決める意味が無くなる
                let written = MCPServer.asWritten(candidate.selector)
                let agreed = MCPServer.picksExactly(element, with: written, in: snapshot)
                return (agreed ? written : candidate.selector, candidate.durability)
            }
            return nil
        }

        /// 優先順に並べた候補(採否は graded(for:in:) が実際に引いて決める)。
        /// **耐久性は候補の出所で決める** —— 綴りを見ても分からない(Durability のコメント参照)
        private func candidates(for element: ElementInfo,
                                in snapshot: SnapshotResponse)
            -> [(selector: String, durability: Durability)] {
            var out: [(selector: String, durability: Durability)] = []
            if let id = element.identifier, !id.isEmpty, idCounts[id] == 1 {
                out.append(("#\(id)", .stable))
            }
            // **切り詰め表示になるラベルは候補にしない**: 40字超は一覧に "…" 付きで出るので、
            // 読み手が写した完全一致は必ず外れる(SnapshotRenderer.truncatedLabelNote と同じ理由)
            let label = FlowMatchMode.normalizeInvisibleCharacters(element.label ?? "")
            if !label.isEmpty, labelCounts[label] == 1,
               label.count <= SnapshotRenderer.labelDisplayLimit {
                // 素のラベルが記法と衝突する形(`#` や `.` 始まり)には `=` 逃がしがある
                out.append((label, .stable))
                out.append(("=\(label)", .stable))
            }
            if let scoped = MCPServer.scopedSelector(for: element, in: snapshot) {
                out.append((scoped, .indexed))
            }
            return out
        }
    }

    /// このセレクタが**その要素ただ1つ**を選ぶか。判定は DSL 本体(`matchDetailed`)に委ねる ——
    /// `resolvedCandidates` は `[n]` を適用する前の候補列なので、ここで使うと
    /// 添字付きのスコープ記法を「曖昧」と誤判定する。
    /// フォールバック(`a||b`)を含む式は「1つを選ぶ」と言えないので採らない
    static func picksExactly(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        let parsed = FTSelector.parse(selector)
        guard parsed.fallbacks.isEmpty else { return false }
        return StepExecutor.matchDetailed(parsed.primary,
                                          elements: snapshot.elements)?.0.ref == element.ref
    }

    /// `#container >> .type[n]` を組み立てる。**書けないときは nil**(嘘の助言を出さない)。
    ///
    /// 条件は2つ: ① id を持つ祖先が居る ② **その id が画面で一意**(重複していると
    /// スコープ自体が曖昧になり、`#recycler_view` のように4つある画面で別の容器を掴む)。
    /// 添字はスコープ内・同じ型の中での順番で、記法は **1 オリジン**(FlowLocator.index の規約)
    static func scopedSelector(for element: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        var idCounts: [String: Int] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            idCounts[id, default: 0] += 1
        }
        let ancestors = TapTargetGeometry.ancestors(of: element, in: snapshot.elements)
        guard let scope = ancestors.first(where: { ancestor in
            guard let id = ancestor.identifier, !id.isEmpty else { return false }
            return idCounts[id] == 1
        }), let scopeID = scope.identifier else { return nil }
        let siblings = StepExecutor.descendants(of: scope, in: snapshot.elements)
            .filter { $0.type == element.type }
        guard let position = siblings.firstIndex(where: { $0.ref == element.ref }) else { return nil }
        return "#\(scopeID) >> .\(element.type)[\(position + 1)]"
    }

    /// **打ち切りは先頭でも言う**(2026-08-09)。`(+91 elements truncated)` は render の末尾に
    /// 1行出るだけで、120 行の一覧のいちばん下にあった —— 実測(Apple マップの経路プランナー)で
    /// **候補 211 件中 91 件が木から落ちて**いたのに、いちばん重い事実がいちばん読まれない位置に
    /// あった。打ち切りは描画の省略ではなく配列からの脱落なので、`waitFor` も `scrollTo` も
    /// 落ちた要素を一生探し続ける。
    ///
    /// **何が落ちたかはブリッジしか知らない**ので、申告があるときだけ内訳を添える
    /// (`SnapshotResponse.truncatedTiers`。無い = 旧ブリッジなら件数だけ)
    static func truncationNote(_ snapshot: SnapshotResponse) -> String {
        guard snapshot.truncatedCount > 0 else { return "" }
        let breakdown = snapshot.truncatedTiers.map { tiers -> String in
            let parts = SnapshotResponse.truncatedTierOrder.compactMap { tier -> String? in
                guard let count = tiers[tier.key], count > 0 else { return nil }
                return "\(count) \(tier.label)"
            }
            return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        } ?? ""
        return "note: \(snapshot.truncatedCount) element(s) were dropped by the snapshot limit"
            + "\(breakdown) — they are gone from the tree, not just hidden, so waitFor/ft_scroll_to"
            + " will never find them. Narrow the screen (close a sheet, scroll a big list away)"
            + " or work from what is listed.\(capHogNote(snapshot))\n"
    }

    /// 上限の外で bulk を送ったときの注記(61)。
    ///
    /// **「一覧が上限を超えているのは異常ではない」と言うためにある**: 読み手は
    /// `maxSnapshotElements` を知らないので、120 を超える一覧を見て木が壊れていると読む余地がある。
    /// 同時に「畳まれた群は枠を食っていない」= 打ち切りの原因ではないことも伝わる。
    /// **申告が無いブリッジ(旧版・Android)では黙る** —— 嘘の安心を出さない
    static func bulkExemptNote(_ snapshot: SnapshotResponse) -> String {
        guard let count = snapshot.bulkExemptCount, count > 0 else { return "" }
        // **「無害」と読ませない**(2026-08-10): 元の文言は要素上限を守っていることしか言わず、
        // これらの行がコンテキストを消費している事実が伝わらなかった
        return "note: \(count) element(s) of large same-id group(s) are listed outside the"
            + " element limit — they did not crowd other elements out of the tree, but they do"
            + " add to this output; the rendering folds them (expandBulk lists them in full).\n"
    }

    /// 打ち切ったときだけ添える「枠を食っている当人」。
    ///
    /// **間引きの方針では直せないから、代わりに名指しする**(2026-08-09): 同一 id の地図 POI が
    /// 上限の過半を占めることは実際にある(実測: Apple マップの経路プランナーで 77/120)が、
    /// 「大きな同一 id 群を先に捨てる」は**リストの行にも同じだけ当たる**ので採れない
    /// (BridgeSnapshotThinning.bulkGroupMinimum の却下理由)。読み手にできる手は
    /// 「その群が出ない画面にする」= 地図を畳む・シートを閉じるなので、**どれが原因かだけ**言う
    static func capHogNote(_ snapshot: SnapshotResponse) -> String {
        var counts: [String: Int] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            counts[id, default: 0] += 1
        }
        guard let (id, count) = counts.max(by: { $0.value < $1.value }),
              count >= SnapshotRenderer.bulkGroupMinimum else { return "" }
        let share = count * 100 / max(1, snapshot.elements.count)
        return " #\(id) alone accounts for \(count) of the \(snapshot.elements.count) kept"
            + " element(s) (\(share)%) — collapsing whatever draws it (a map, a long list)"
            + " frees the most room."
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
    /// 判定は要素自身の細さだけ(縁で切れたかは見ない)。
    /// **列挙は操作可能型(operableTypes)に限る**(2026-08-10): 文言が「タップに失敗するかも」
    /// なので、タップ対象にならない image/staticText に出すと空振りの注意になる(実測:
    /// 画面下端で 84x9 に切れた「IC 運賃」アイコン)。判定自体は共有のまま型を問わない
    static func sliverNote(_ snapshot: SnapshotResponse) -> String {
        let slivers = snapshot.elements.filter {
            RefGuard.isClippedSliver($0)
                && BridgeSnapshotThinning.operableTypes.contains($0.type)
        }
        guard !slivers.isEmpty else { return "" }
        let listed = slivers.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
            .joined(separator: " ")
        let more = slivers.count > 8 ? " (+\(slivers.count - 8) more)" : ""
        return "note: \(slivers.count) element(s) are extremely thin with a label"
            + " (≤10 wide/tall) — the strip may be too thin to tap, whether clipped at an edge"
            + " or just narrow by design: \(listed)\(more)\n"
    }

    /// 曖昧と呼ぶ下限。**2**(2026-08-09 に3から下げた): 2件でも `tap("他のフィルタ")` は
    /// 一意に選べず、危険度は3件と変わらない。実測(Google マップの検索結果)では
    /// `"他のフィルタ"` が別 frame の2件あるのに黙っていた。
    /// 雑音は「入れ子の一本鎖」を除外して抑える(下記)
    static let ambiguousLabelMinimum = 2

    /// 同一ラベルが複数に一致するときの要約注記(欠陥⑩)。id の重複は別パッケージが
    /// 行内に `×N` として個別に出すので、こちらは**ラベルだけ**を扱う。
    /// 実測: 経路検索の候補一覧で「東京駅」が9件一致し、素のラベルでは一意に指せなかった
    /// `abbreviated`(F-6 の対象拡大・2026-08-10): 明細行(ラベルごとの候補列挙)と末尾の
    /// 「+N more」は既定と同じまま、ヘッダの凡例だけ「初出の注記を見よ」に圧縮する
    static func ambiguousLabelsNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false)
        -> String {
        var groups: [String: [ElementInfo]] = [:]
        for e in snapshot.elements {
            // **ゼロ幅文字を落としてから数える**(2026-08-09)。一覧の行は
            // `SnapshotRenderer.renderElement` が除去済みの形で出すので、生ラベルのまま
            // 注記に出すと**同じラベルが1つの応答の中で2表記**になる(実測: Google マップの
            // `"​​埼京線​"`)。読み手はこれを別物と読む。数える側も揃える —— ゼロ幅の有無だけが
            // 違う2件は `FlowMatchMode.matches` では区別できず、実際に曖昧だから
            let label = FlowMatchMode.normalizeInvisibleCharacters(e.label ?? "")
            guard !label.isEmpty else { continue }
            groups[label, default: []].append(e)
        }
        let ambiguous = groups
            .filter { $0.value.count >= ambiguousLabelMinimum && !isSingleChain($0.value, in: snapshot) }
            // **全員が飾りの葉なら列挙しない**(2026-08-10 の実アプリ監査): 地図 POI の
            // 「〜の路線」×3 のような群はセレクタの書き先にならないのに行を占めていた。
            // 1件でも操作対象・型付きが混じる群は従来どおり全員出す(片側だけ隠すと
            // ×N の数と明細が食い違う)。判定は bulk fold と同じ SnapshotRenderer.isDecorativeLeaf
            .filter { !$0.value.allSatisfy { SnapshotRenderer.isDecorativeLeaf($0, in: snapshot.elements) } }
            .sorted { $0.value.count > $1.value.count }
        guard !ambiguous.isEmpty else { return "" }
        // **「一意に指せない」で終わらせない**(2026-08-09): MCP の出力はシナリオへ書く文字列を
        // 供給するためにあるので、代わりに書ける形まで出す。機構は `writableSelector` =
        // ft_tap の推奨セレクタ(E)と同じ実装
        let naming = SelectorNaming(snapshot)
        var lines: [String] = [abbreviated
            ? "note: ambiguous labels — write one of these instead (legend in the first"
                + " snapshot's note):"
            : "note: these labels match multiple elements, so a plain label"
                + " selector cannot pick one uniquely. Write one of these instead"
                + " (\"—\" = this element has no stable selector; use a labelled ancestor or"
                + " a coordinate. \"~\" = index-based, so it breaks if the number of same-type"
                + " siblings changes — usable, but the weakest of the three):"]
        for (label, matches) in ambiguous.prefix(ambiguousLabelsShown) {
            let shown = matches.prefix(ambiguousMatchesShown).map { element -> String in
                guard let graded = naming.graded(for: element, in: snapshot) else {
                    return "[\(element.ref)] —"
                }
                return "[\(element.ref)] \(graded.selector)\(graded.durability.mark)"
            }.joined(separator: " / ")
            let cut = matches.count > ambiguousMatchesShown
                ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
            lines.append("  \"\(label)\" ×\(matches.count): \(shown)\(cut)")
        }
        if ambiguous.count > ambiguousLabelsShown {
            lines.append("  (+\(ambiguous.count - ambiguousLabelsShown) more ambiguous label(s)"
                + " not shown — ft_snapshot again after narrowing the screen to see them)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 曖昧ラベル注記に並べる上限。**打ち切ったことは必ず言う**(黙って切ると
    /// 「これで全部」と読まれる)
    static let ambiguousLabelsShown = 5
    static let ambiguousMatchesShown = 6

    /// 同じラベルの群が**入れ子の一本鎖**か(容器とその中身が同じラベルを名乗る形)。
    /// 下限を2へ下げると、`button "自宅、追加"` とその子 `#IconImage-TitleLabel-SubtitleLabel`
    /// のようなラッパー対が全部鳴る —— どちらを掴んでも同じものなので曖昧ではない。
    /// `RefGuard.stackedRefs` が同じ理由で使っている除外と同型
    static func isSingleChain(_ group: [ElementInfo], in snapshot: SnapshotResponse) -> Bool {
        guard let first = group.first else { return true }
        let chain = TapTargetGeometry.lineage(of: first, in: snapshot.elements)
        return group.allSatisfy { chain.contains($0.ref) }
    }

    /// 座標ピンチの既定の半径 = 画面の短辺のこの割合。**画面相対**なのは、座標系が
    /// iOS=pt(短辺 402)/ Android=px(短辺 1080)で桁が違うため —— 固定値にすると
    /// 片方で指が開かず、もう片方で画面をはみ出す
    static let pinchRadiusScreenRatio = 0.22
    static let pinchRadiusFallback: Double = 100

    /// (x,y) を中心にした正方形の対象領域。**画面が分かるなら内側へ収める** ——
    /// 画面外へはみ出した指はタッチとして届かず、要求より小さいズームになる。
    /// 収め方は**中心を動かさず半径を縮める**(中心を寄せるとズームの支点が変わり、
    /// 「この地点を拡大したい」という指定そのものが崩れる)。縁ぎわの指定では
    /// 指の開きが小さくなるぶん倍率が出にくい
    static func pinchArea(x: Double, y: Double, radius: Double?, screen: FTRect?) -> FTRect {
        var r = radius ?? screen.map { min($0.width, $0.height) * pinchRadiusScreenRatio }
            ?? pinchRadiusFallback
        if let screen, screen.width > 0, screen.height > 0 {
            let room = [x - screen.x, screen.x + screen.width - x,
                        y - screen.y, screen.y + screen.height - y].min() ?? r
            r = max(1, min(r, room))
        }
        return FTRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
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
        guard let target = resolveSessionRef(ref, args: args)?.element else { return "" }
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

    /// ref を撃つ直前に照合したうえで**要素そのもの**を返す(ft_double_tap / ft_pinch / ft_drag
    /// fromRef 用。いずれも ref ではなく座標・identifier で撃つため要素が要る)。
    ///
    /// **isStale の警告は呼び手に返していない**(座標系のジェスチャは verifiedRef ほど頻繁に
    /// 古い ref を渡される想定がなく、対象が消えていれば下の `.gone` が捕まえる)。
    /// **ラベル変化だけは note で返す**(2026-08-10) —— これは double_tap/drag/pinch が
    /// 再ターゲットした要素へ実際に操作を撃つ経路なので、verifiedRef と同じ危険がある
    /// (RefGuard.labelChangeNote 参照。.found のときだけ = verifiedRef と条件を揃える)
    private func verifiedElement(_ ref: Int, driver: AppDriver,
                                 args: [String: Any]) async throws -> (element: ElementInfo, note: String) {
        let resolved = resolveSessionRef(ref, args: args)
        // stderr のみ・応答には何も足さない。警告を付けるかは実運用の頻度を見て決める
        // (2026-08-10・依頼側と合意した観測)
        if resolved?.isStale == true {
            Self.logStderr("verifiedElement: stale ref [\(ref)] passed to a"
                + " double_tap/pinch/drag path — no warning is attached here; counting"
                + " occurrences to decide whether to add one")
        }
        // **fresh を撮る前に世代の有無を固定する**: freshSnapshot は内部で adoptSnapshot を通し、
        // 世代が無ければその場で最初の世代を作ってしまう。後から見ると常に「世代あり」に見えて
        // 「そもそも撮っていない」と「見つからない」を区別できなくなる
        let hadGenerations = !(refGenerations[Self.engineKey(args)]?.isEmpty ?? true)
        let fresh = try await freshSnapshot(driver, args: args)
        guard let target = resolved?.element else {
            // 世代が無かった(ft_snapshot を挟まずに撃たれた)= 撮ったばかりの木から素直に引く。
            // 世代があったのに見つからない(= 直近5世代のどれにも無い番号)なら unknown ref
            guard !hadGenerations else {
                throw MCPError("unknown ref [\(ref)] — it is not from any recent snapshot"
                    + " (refs are per-snapshot; the last 5 snapshots were checked)."
                    + " Take a fresh ft_snapshot")
            }
            guard let element = fresh.elements.first(where: { $0.ref == ref }) else {
                throw MCPError("unknown ref [\(ref)]. Take an ft_snapshot first")
            }
            return (element, "")
        }
        switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
        case .gone:
            throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                truncatedCount: fresh.truncatedCount))
        case .ghost(let found):
            return (found, "")
        case .found(let found, _):
            return (found, RefGuard.labelChangeNote(old: target.label, new: found.label) ?? "")
        }
    }

    /// driver(_:) が使うキャッシュキーと同じ引き当て(エンジンの記録先)
    static func engineKey(_ args: [String: Any]) -> String {
        if let profileName = args["profile"] as? String {
            return driverCacheKey(profile: profileName, project: args["project"] as? String,
                                  platform: args["platform"] as? String)
        }
        return driverCacheKey(platform: platformName(args), port: args["port"] as? Int,
                              serial: args["serial"] as? String)
    }

    /// 引数から見た宛先プラットフォーム。**既定は iOS**(FTESTER_PLATFORM で上書き)
    static func platformName(_ args: [String: Any]) -> String {
        (args["platform"] as? String)
            ?? ProcessInfo.processInfo.environment["FTESTER_PLATFORM"] ?? "ios"
    }

    /// ft_logs の bundleId 既定。ログはブリッジを通らないので engineKey が launch 時と
    /// 揃わない(profile で起動し serial 直指定で読む等)。覚えている起動が1つだけならそれを使う
    func lastLaunchedBundleID(_ args: [String: Any]) -> String? {
        if let exact = launchedBundleIDs[Self.engineKey(args)] { return exact }
        let known = Set(launchedBundleIDs.values)
        return known.count == 1 ? known.first : nil
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
        let clock = ContinuousClock()
        let start = clock.now
        // **udid は入口で port へ畳む**(2026-08-10)。`driver(_:)` は解決後のポートで
        // ドライバを引くのに、`engineKey` は生の引数しか見ないので、udid で指した機は
        // すべて port=nil の同じキーに落ちていた。engineKey が引く記憶は
        // lastSnapshots / launchedBundleIDs / uiFrameworkHints / connections /
        // pendingWarnings / udids / engines の7つで、**2台を udid で操作すると混ざる**
        // (実測: 機A に Preferences・機B に Maps を launch した後、機A への
        //  ft_open_url が com.apple.Maps へ配ると申告した。Android では intent の
        //  宛先そのものなので、同じ機の中で別アプリへ実際に配送される)。
        // 入口で畳めば 35 箇所の呼び出しを触らずに全部が揃う
        let resolved: [String: Any]
        do {
            resolved = try await Self.foldingUDIDIntoPort(args)
        } catch {
            let hint = await connectionLostHint(error, args: args)
            throw hint.isEmpty ? error : MCPError(error.localizedDescription + hint)
        }
        do {
            return Self.withElapsed(try await dispatch(tool: tool, args: resolved),
                                    since: start, clock: clock)
        } catch {
            let hint = await connectionLostHint(error, args: resolved)
            guard !hint.isEmpty else { throw error }
            throw MCPError(error.localizedDescription + hint)
        }
    }

    /// `udid` を解決して `port` として畳んだ引数。**udid が無いときは触らない**
    /// (Android や profile 指定はブリッジ走査を1回も払わない)。
    /// 解決と食い違い検査は `portForIOS` に委ねる = 宛先の決め方は1箇所のまま
    static func foldingUDIDIntoPort(_ args: [String: Any]) async throws -> [String: Any] {
        guard (args["udid"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) != nil else { return args }
        return injectingPort(args, port: try await portForIOS(args))
    }

    /// 解決したポートを引数へ載せる。**純粋関数**(走査を伴う解決と切り離してあるので、
    /// 「載せ忘れ」の枝をテストで直接踏める)
    static func injectingPort(_ args: [String: Any], port: UInt16?) -> [String: Any] {
        guard let port else { return args }
        var out = args
        out["port"] = Int(port)
        return out
    }

    /// **デバイス側に何秒かかったかを毎回返す**(2026-08-09)。読み手はこれが無いと、自分の
    /// 思考時間まで含んだ壁時計しか測れない —— 実測を頼まれたときに `date` をシェルで撃つ
    /// 往復が発生していた。
    ///
    /// **末尾に独立した content ブロックとして足す**(本文へ混ぜない): 本文を読む側は
    /// `content[0].text` を見るので、混ぜると所要時間が結果の文字列の一部になって
    /// 照合や引用を汚す。画像を返す ft_screenshot でも同じ形で足せる
    static func withElapsed(_ content: [[String: Any]], since start: ContinuousClock.Instant,
                            clock: ContinuousClock) -> [[String: Any]] {
        let ms = (clock.now - start) / .milliseconds(1)
        return content + [["type": "text", "text": "⏱ \(Self.elapsedText(milliseconds: ms))"]]
    }

    /// 1秒未満はミリ秒・以上は小数1桁の秒(読み手が桁を数えなくて済む形)
    static func elapsedText(milliseconds: Double) -> String {
        milliseconds < 1000 ? "\(Int(milliseconds.rounded()))ms"
            : String(format: "%.1fs", milliseconds / 1000)
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

        case "ft_list_devices":
            return text(await DeviceInventory.devicesText(
                project: args["project"] as? String,
                profile: args["profile"] as? String,
                platform: args["platform"] as? String))

        case "ft_list_apps":
            // driver() を先に通す: profile 指定の解決(provision)と udids の記録がここで済み、
            // 直指定でも同じ宛先選択規則に乗る
            let appsDriver = try await driver(args)
            let appsFilter = (args["filter"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // **filter を渡したら既定で system も探す**: 絞り込む唯一の動機は「あのアプリを
            // 見つける」ことで、端末に載っている地図・ブラウザは system 側に居る。既定のままだと
            // 「入っていない」という誤った空振りになる(2026-08-09 に実測して adb へ落ちた)。
            // 明示の includeSystem: false は尊重する
            let includeSystem = args["includeSystem"] as? Bool ?? (appsFilter != nil)
            if Self.platformName(args) == "android" {
                guard let android = appsDriver as? AndroidDriver else {
                    throw MCPError("this Android connection cannot list packages")
                }
                return text(DeviceInventory.appsText(
                    packages: try android.listPackages(includeSystem: includeSystem),
                    includeSystem: includeSystem, filter: appsFilter))
            }
            let deviceName = try await appsDriver.status().device
            let udid = try udids[Self.engineKey(args)].flatMap { $0 }
                ?? SimulatorAppCatalog.bootedSimulatorUDID(named: deviceName)
            return text(DeviceInventory.appsText(apps: try SimulatorAppCatalog.apps(udid: udid),
                                                 includeSystem: includeSystem, filter: appsFilter))

        case "ft_logs":
            let logBundleID = args["bundleId"] as? String ?? lastLaunchedBundleID(args)
            return text(await CrashLogs.text(
                platform: Self.platformName(args),
                bundleID: logBundleID,
                serial: args["serial"] as? String,
                withinSeconds: args["sinceSeconds"] as? Int ?? 300,
                maxLines: args["lines"] as? Int ?? 100,
                crashOnly: (args["all"] as? Bool) != true))

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
            // 下書きの起点(F-3 の既定範囲は「直近の ft_launch 以降」)。@TestClass(app:) にも使う
            interactions.record(InteractionLog.Entry(
                step: nil, unresolved: nil, isLaunch: true, bundleID: bundleID,
                platform: Self.platformName(args), summary: "launch \(bundleID)"))
            return text("Launched: \(bundleID)")

        case "ft_open_url":
            guard let url = args["url"] as? String else { throw MCPError("url is required") }
            let openURLDriver = try await driver(args)
            let openURLBundleID = args["bundleId"] as? String ?? launchedBundleIDs[Self.engineKey(args)]
            // installedState は撃たない: simctl openurl/devicectl openURL・am start は OS の URL
            // ルーティングで、installedState が守っている XCUIApplication.launch() のランナー死
            // (ft_launch のコメント参照)とは経路が別
            try await openURLDriver.openURL(url, bundleID: openURLBundleID)
            var openStep = FlowStep(action: "openURL")
            openStep.text = url
            interactions.record(InteractionLog.Entry(step: openStep, unresolved: nil,
                                                     summary: "openURL \"\(url)\""))
            return text("Delivered \(url)"
                + (openURLBundleID.map { " to \($0)" } ?? "") + "."
                + " Delivery is asynchronous (the app has to receive and handle it) — if a"
                + " ft_snapshot right after still shows the old screen, wait and snapshot again")

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
                // **撃ち直しが起きたときだけ adoptSnapshot を通す**: 撃ち直しが無ければ
                // `waited.snapshot` は `snapshot`(既にセッション ref)そのものなので、
                // native 前提の adoptSnapshot に通すと同じ木を「別世代」と誤認する
                // (base 込みの ref を native ref と取り違えて比較するため)
                snapshot = waited.refetched ? adoptSnapshot(waited.snapshot, args: args) : waited.snapshot
                if !waited.found {
                    waitNote = "waitFor \"\(waitFor)\" did not appear within \(seconds)s"
                        + " — this is the screen as it is now\(Self.truncationHint(snapshot))"
                        + (waited.partialSeenAfter.map { seenAfter in
                            // **完全一致でなく部分一致が先に出た形を名指しする**: 満額待った理由
                            // (早期打ち切りはしない)まで書かないと、待った時間が無駄に見える
                            " — a partial match was already on screen \(Int(seenAfter.rounded()))s"
                                + " into the wait:\(waited.partialHint) The exact form never"
                                + " appeared, so the wait ran to the deadline"
                        // **記法の助言はここにも要る**: 切り詰めラベルをそのまま渡した waitFor は
                        // 外れるのに、返す木には**同じ文字列が印字されている**ので照合のバグに見える
                        // (2026-08-07 実測)。scrollTo だけに出していて届いていなかった
                        } ?? (Self.notationHint(waitFor, in: snapshot)
                              // **部分一致が出ていたときは出さない**: そちらのほうが具体的な
                              // ヒントなので、的の外れた推測を並べて紛らわせない(2026-08-10)
                              + Self.similarLabelsHint(waitFor, in: snapshot))) + "\n"
                }
            }
            // **プラットフォームはドライバの実体から採る**(profile 指定時は args["platform"] が
            // 空でもプロファイル側で解決済みなので、args を見ると取り違える)
            recordSnapshot(snapshot, snapshotDriver is AndroidDriver ? "android" : "ios", args)
            return text(withPendingWarnings(
                await snapshotBody(snapshot, driver: snapshotDriver, args: args,
                                   extraNote: waitNote),
                args: args))

        case "ft_tap":
            let d = try await driver(args)
            if let ref = args["ref"] as? Int {
                let target = try await verifiedRef(ref, driver: d, args: args)
                // **target.ref はセッション ref**。ブリッジは native の番号しか知らないので、
                // 撃つ直前にだけ nativeRef で戻す(応答・記録には引き続きセッション ref を使う)
                try await d.tap(ref: nativeRef(target.ref, args: args))
                recordInteraction(action: "tap", resolvedRef: target.ref, args: args)
                return text("tap [\(ref)] done.\(target.note)"
                    + reproductionNote(resolvedRef: target.ref, args: args)
                    + Self.changedHint(args) + (await snapshotAfterBody(args)))
            }
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                try await d.tap(x: x, y: y)
                recordInteraction(action: "tap", resolvedRef: nil, args: args, coordinate: (x, y))
                return text("tap (\(x), \(y)) done" + once("coordinateReproductionNote",
                    full: Self.coordinateReproductionNote,
                    short: Self.coordinateReproductionNoteShort)
                    + (await snapshotAfterBody(args)))
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
                // targetRef はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
                try await typeDriver.type(ref: targetRef.map { nativeRef($0, args: args) }, text: content)
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
                try await typeDriver.tap(ref: nativeRef(ref, args: args))
                note += await awaitFocus(ref: ref, driver: typeDriver, args: args)
            }
            // 入力欄も**セレクタで再現できないと書けない**(E)。ref を渡さない
            // (フォーカス任せの)呼び方では対象が確定しないので黙る
            let typedSelector = targetRef.map { reproductionNote(resolvedRef: $0, args: args) } ?? ""
            if let content, !content.isEmpty {
                recordInteraction(action: "type", resolvedRef: targetRef, args: args, text: content)
            }
            if wantsEnter { recordInteraction(action: "pressEnter", resolvedRef: nil, args: args) }
            guard wantsEnter else {
                return text("Typed: \"\(content ?? "")\"\(note)\(typedSelector)"
                    + (await snapshotAfterBody(args)))
            }
            try await typeDriver.pressEnter()
            return text((content.map { "Typed: \"\($0)\" and pressed Enter" } ?? "Pressed Enter")
                + note + typedSelector + (await snapshotAfterBody(args)))

        case "ft_swipe":
            guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
                throw MCPError("direction must be one of up/down/left/right")
            }
            try await driver(args).swipe(direction)
            recordInteraction(action: "swipe", resolvedRef: nil, args: args,
                              direction: direction.rawValue)
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
            // **back が無効だったかは木の指紋で見る**(home/appSwitcher は対象外)。
            // 覚えている木が無ければチェック自体をしない(照合の起点が無いのに撃つのは
            // 余計な往復を増やすだけ)
            let beforeBackFingerprint = target == "back"
                ? lastSnapshots[Self.engineKey(args)].map(Self.treeFingerprint) : nil
            switch target {
            case "back": try await navigation.back()
            case "home": try await navigation.home()
            case "appSwitcher": try await navigation.openAppSwitcher()
            default: throw MCPError("target must be one of back/home/appSwitcher")
            }
            recordInteraction(action: target, resolvedRef: nil, args: args)
            var backIneffectiveNote = ""
            if let before = beforeBackFingerprint {
                // **1回の撮り直しでは判定しない**(ポーリング): アニメーション途中の木を
                // 「変わっていない」と誤読しないため。取得に失敗したら黙って諦める
                // (成功した観測が1つも無ければ「変わっていない」と断言する材料が無い)
                var sawChange = false
                var sawAnySnapshot = false
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(0.3))
                    guard let after = try? await freshSnapshot(navigation, args: args) else { continue }
                    sawAnySnapshot = true
                    if Self.treeFingerprint(after) != before { sawChange = true; break }
                }
                if sawAnySnapshot, !sawChange {
                    backIneffectiveNote = ". note: the tree is identical to the one before back —"
                        + " back appears to have had no effect on this screen (apps drawing their"
                        + " own back button often ignore the system back); tap the app's own back"
                        + " control, or send back again"
                }
            }
            // **「画面が変わった」と断言しない**(2026-08-06 の探索で外した): iOS の back は
            // 端の swipe なので、自前ナビの画面(`#btn_back` を持つ SwiftUI 等)では
            // **何も起きない**。back でアプリ自体を出てしまうこともあり、どちらも
            // 「変わった」と言い切ると誤操作の起点になる
            return text("\(target) sent. Take a fresh ft_snapshot to see the result"
                + Self.backNoOpNote(target: target, engine: engines[Self.engineKey(args)])
                + backIneffectiveNote
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
            // clearRef はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
            try await clearDriver.clearInput(ref: clearRef.map { nativeRef($0, args: args) })
            recordInteraction(action: "clearInput", resolvedRef: clearRef, args: args)
            return text("cleared\(clearNote)"
                + (clearRef.map { reproductionNote(resolvedRef: $0, args: args) } ?? ""))

        case "ft_draft_scenario":
            return text(draftScenario(args))

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
            var doubleTapSelector = ""
            if let ref = args["ref"] as? Int {
                let (element, labelNote) = try await verifiedElement(ref, driver: doubleTapDriver, args: args)
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
                        ?? FTRect(x: 0, y: 0, width: 0, height: 0)) + labelNote
                doubleTapSelector = reproductionNote(resolvedRef: element.ref, args: args)
            } else if let x = args["x"] as? Double, let y = args["y"] as? Double {
                doubleTapPoint = (x, y)
                doubleTapWhat = "(\(x), \(y))"
                doubleTapSelector = once("coordinateReproductionNote",
                                         full: Self.coordinateReproductionNote,
                                         short: Self.coordinateReproductionNoteShort)
            } else {
                throw MCPError("ref or x/y is required")
            }
            try await doubleTapDriver.doubleTap(x: doubleTapPoint.x, y: doubleTapPoint.y)
            return text("double tap \(doubleTapWhat) done.\(doubleTapNote)\(doubleTapSelector)"
                + " The screen may have changed — take a fresh ft_snapshot."
                + iosEngineHint("Compose Multiplatform", "double tap", args: args))

        case "ft_drag":
            let dragDriver = try await driver(args)
            // **掴む側を ref で指せる**(2026-08-09): 半開きのシートを広げる操作は
            // 「グラバーを上へ引く」だけなのに、座標しか受けないせいで
            // `#Card grabber` の frame を人が読んで手で計算する必要があった(実測)。
            // 終点は「そこまで運ぶ距離」なので dy/dx でも書ける
            var fromPoint: (x: Double, y: Double)?
            // **once() は実際に使う枝でだけ呼ぶ**: fromRef 側で上書きされる既定値として
            // 呼ぶと、座標形を一度も返していないのに「もう説明した」ことになってしまう
            var dragSelector = ""
            if let ref = args["fromRef"] as? Int {
                // **撮り直した木の frame を使う**(verifiedElement)。覚えていた frame から
                // 座標を作ると、この修正が防ごうとしている「古い座標を撃つ」に自分で落ちる
                let (element, labelNote) = try await verifiedElement(ref, driver: dragDriver, args: args)
                fromPoint = (element.frame.centerX, element.frame.centerY)
                dragSelector = reproductionNote(resolvedRef: element.ref, args: args) + labelNote
            } else if let x = args["fromX"] as? Double, let y = args["fromY"] as? Double {
                fromPoint = (x, y)
                dragSelector = once("coordinateReproductionNote",
                                    full: Self.coordinateReproductionNote,
                                    short: Self.coordinateReproductionNoteShort)
            }
            guard let from = fromPoint else {
                throw MCPError("fromRef or fromX/fromY is required")
            }
            // 終点は絶対座標か相対移動のどちらか(相対は「グラバーを 400 上へ」を素直に書ける)
            let toX = args["toX"] as? Double ?? (from.x + (args["dx"] as? Double ?? 0))
            let toY = args["toY"] as? Double ?? (from.y + (args["dy"] as? Double ?? 0))
            guard toX != from.x || toY != from.y else {
                throw MCPError("the drag does not move: pass toX/toY, or dx/dy")
            }
            let fromX = from.x
            let fromY = from.y
            try await dragDriver.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                      pressSeconds: 0.05,
                                      durationSeconds: args["durationSeconds"] as? Double ?? 1.5)
            // **無検証であることを言う**(swipe / pinch は言っているのに drag / press だけ
            // 「done」で言い切っていた。同じ無検証なのに信頼度が違って見える)
            return text("drag (\(fromX), \(fromY)) → (\(toX), \(toY)) sent.\(dragSelector)"
                + (args["snapshotAfter"] as? Bool == true
                   ? " Nothing about the result is checked — read the tree below to confirm"
                     + " it moved what you meant."
                   : " Nothing about the result is checked — if it should have moved something,"
                     + " confirm with ft_snapshot/ft_screenshot")
                + (await snapshotAfterBody(args)))

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
            var whole = false
            var areaIgnored = false
            var pinchSelector = ""
            if let ref = args["ref"] as? Int {
                let (element, labelNote) = try await verifiedElement(ref, driver: pinchDriver, args: args)
                frame = element.frame
                identifier = element.identifier
                pinchSelector = reproductionNote(resolvedRef: element.ref, args: args) + labelNote
            } else if let x = args["x"] as? Double, let y = args["y"] as? Double {
                // **地図・キャンバスには ref が無い**(2026-08-09 実測): Apple マップの場所カードを
                // 半分出したまま ref 無しで撃つと、指が画面全体に開くのでシートが掴まれ、
                // **地図は 1px も動かずシートが全画面に展開した**。逃げ道が無かったので、
                // ft_tap / ft_press / ft_drag と同じく座標を受ける
                frame = Self.pinchArea(x: x, y: y, radius: args["radius"] as? Double,
                                       screen: lastSnapshots[Self.engineKey(args)]?.screen)
                // **XCUITest は領域を受け取れない**(`PinchRequest.frame` を読むのは Android と
                // in-app だけ。XCTest のピンチは XCUIElement にしか生えておらず、座標版が無い)。
                // 黙って全画面へ退化させると、狙った場所を撃ったつもりで**手前のシートを掴む**
                // —— この修正の動機そのものなので、退化したことを必ず言う
                areaIgnored = engines[Self.engineKey(args)] == "xcuitest"
            } else {
                whole = true
            }
            try await pinchDriver.pinch(frame: frame, identifier: identifier, scale: scale,
                                        durationSeconds: args["durationSeconds"] as? Double ?? 0.5)
            return text("pinch x\(scale) done.\(pinchSelector)"
                // **「小さくなる」とだけ言わない**(2026-08-06 実測): 指が対象の内側に収まる分だけ
                // 小さくなることもあれば、慣性で大きくもなる(scale 2.0 の要求で累積 3.9 倍)
                + " The actual zoom can differ from what you asked for in either direction"
                + " — verify with ft_snapshot/ft_screenshot."
                + (whole ? " The fingers spanned the whole screen, so anything on top of the area"
                    + " you meant (a bottom sheet, a card) may have taken the gesture instead —"
                    + " pass x/y to pinch a specific spot." : "")
                + (areaIgnored ? " x/y was NOT honoured: the XCUITest engine can only pinch an"
                    + " element (XCTest has no coordinate pinch), so the fingers spanned the whole"
                    + " screen and anything drawn over that spot may have taken the gesture."
                    + " Pass profile: naming an in-app/hybrid run profile to pinch a coordinate"
                    + " area (this relaunches the app — re-navigate before retrying)." : "")
                // **同じ逃げ道を2度書かない**(2026-08-08 に長文の苦情があった箇所)。
                // 領域が無視されたときの文は engine も remedy も言い切っているので、
                // 汎用の Flutter 助言はそこでは畳む
                + (areaIgnored ? "" : iosEngineHint("Flutter", "pinch", args: args)))

        case "ft_press":
            let pressDriver = try await driver(args)
            let pressDuration = args["duration"] as? Double ?? 1.0
            if let ref = args["ref"] as? Int {
                let pressTarget = try await verifiedRef(ref, driver: pressDriver, args: args)
                // pressTarget.ref はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
                try await pressDriver.press(ref: nativeRef(pressTarget.ref, args: args),
                                            duration: pressDuration)
                recordInteraction(action: "press", resolvedRef: pressTarget.ref, args: args)
                return text("press [\(ref)] done.\(pressTarget.note)"
                    + reproductionNote(resolvedRef: pressTarget.ref, args: args)
                    + " The screen may have changed — take a fresh ft_snapshot")
            }
            // **座標形は ft_tap と揃える**: ドライバは press(x:y:duration:) を要件として持つのに
            // MCP からは ref でしか呼べなかった。地図・キャンバスのように a11y 要素が無い点を
            // 長押しする操作(ピンを落とす・住所を出す)が一切書けない状態だった(2026-08-07)
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                try await pressDriver.press(x: x, y: y, duration: pressDuration)
                recordInteraction(action: "press", resolvedRef: nil, args: args, coordinate: (x, y))
                return text("press (\(x), \(y)) done." + once("coordinateReproductionNote",
                    full: Self.coordinateReproductionNote,
                    short: Self.coordinateReproductionNoteShort)
                    + " The screen may have changed — take a fresh ft_snapshot")
            }
            throw MCPError("ref or x/y is required")

        case "ft_screenshot":
            let screenshotDriver = try await driver(args)
            // **鮮度チェックは画像ハッシュ×木指紋の前回比較**(2026-08-10、前後2枚方式から置き換え)。
            // 静止画面の2連続 ft_screenshot は PNG がバイト単位で同一と実測済み(lastScreenshots
            // 宣言参照)——だから「木は前回と変わったのに画像はバイト同一」を古いフレームの証拠に
            // 使える。撮影前の snapshot は取らない(往復は screenshot 1回 + snapshot 1回の計2回)。
            // **限界**: 木の変化が画素に出ない変化(a11y のみ)は偽陽性になり得るが、指紋は
            // type/id/label/frame なので実害は薄い
            let png = try await screenshotDriver.screenshot()
            var staleNote: [[String: Any]] = []
            // 木の取得に失敗したら判定せず、記録も汚さない(前回の記録を残す)
            if let after = try? await freshSnapshot(screenshotDriver, args: args) {
                let key = Self.engineKey(args)
                let imageHash = Self.hashBytes(png)
                let fingerprint = Self.treeFingerprint(after)
                if let previous = lastScreenshots[key],
                   previous.imageHash == imageHash, previous.treeFingerprint != fingerprint {
                    staleNote = [["type": "text", "text":
                        "note: the element tree has changed since the previous ft_screenshot, but"
                        + " this image is byte-identical to that previous one — the frame is likely"
                        + " STALE (a frozen display can keep serving an old frame). Do not read"
                        + " results off this image; trust ft_snapshot, and re-take the screenshot"
                        + " after interacting with the screen."]]
                }
                // **同じ凍結フレームへの注記は最初の1回だけ**: ここで指紋を新しい木へ更新するため、
                // 以後は「画像同一・木も同一」になり静止画面と区別できない(意図した設計。
                // 記録を更新しない案は、静止画面の連写で木の自然な揺れを拾い偽陽性を積む)
                lastScreenshots[key] = (imageHash: imageHash, treeFingerprint: fingerprint)
            }
            guard (args["fullSize"] as? Bool) != true else {
                return staleNote
                    + [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
            }
            // 縮小できないとき(壊れた PNG・ImageIO 失敗)は絵を返さないより原寸のほうがまし
            guard let scaled = ImageDownscale.jpeg(
                png: png,
                maxWidth: args["maxWidth"] as? Int ?? Self.screenshotMaxWidth,
                quality: args["quality"] as? Double ?? Self.screenshotQuality) else {
                return staleNote
                    + [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
            }
            return staleNote + [["type": "image", "data": scaled.data.base64EncodedString(),
                                  "mimeType": "image/jpeg"]]

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

    /// 探索の操作列から Swift シナリオの**下書き**を組む(F)。
    ///
    /// **ファイルには書かない**(F-2): 置き場所と命名はスキルの仕事で、MCP は文字列を返すだけ。
    /// 生成そのものは `ScenarioCodeGen.render` に委ねる —— 記録機能(`ftester api gen-scenario`)と
    /// 同じ生成器を通すので、CAE の形も DSL の綴りも1箇所で決まる(2つ目の実装を作らない)。
    ///
    /// **アサーションは推測で作らない**(F-5): expectation は空の骨格で出し、
    /// ft_dry_run の「アサーションの無い expectation ブロック」検出に埋めさせる。
    /// **セレクタを解決できなかった手は TODO で残す**(F-4) —— 消すと手順と食い違う
    func draftScenario(_ args: [String: Any]) -> String {
        let recorded = (args["all"] as? Bool == true)
            ? interactions.entries : interactions.sinceLastLaunch
        guard !recorded.isEmpty else {
            return "No interactions recorded yet. Drive the app with ft_launch / ft_tap / ft_type"
                + " / ft_scroll_to first — this tool turns that sequence into a scenario draft."
        }
        // **刈り込みは下書きの質そのもの**(2026-08-10): 記録は「やったこと」であって
        // 「意図」ではないので、行き止まりのタップや試し打ちがそのまま載る。自動では
        // 本筋と回り道を見分けられない(どちらも成功した操作)ので、**番号を見せて選ばせる**
        let (scope, droppedCount, ignoredNumbers) = InteractionLog.prune(
            recorded, lastN: args["lastN"] as? Int,
            drop: (args["drop"] as? [Any])?.compactMap { $0 as? Int } ?? [])
        guard !scope.isEmpty else {
            return "Every recorded step was pruned away (\(recorded.count) recorded,"
                + " \(droppedCount) dropped). Call ft_draft_scenario again with a smaller"
                + " drop list — the numbering is 1-based over the steps shown in the listing."
        }
        let target = interactions.target(in: scope)
        let unresolved = scope.compactMap(\.unresolved)
        let steps = scope.compactMap(\.step)
        // **解決できなかった手はその場に残す**(2026-08-10)。まとめて先頭へ出すと action の
        // 並びからその手が消え、生成コードが実際の手順と食い違う(33 手の下書きで実際に起きた:
        // チェックアウト→住所画面へ移る手が抜けたまま #btn_add_address を叩く形になった)
        var notesBeforeStep: [Int: [String]] = [:]
        // 一覧の番号(1 起点・刈り込み後)→ steps の位置。scenes: もこの対応で読む
        var stepIndexForListing: [Int] = []
        var resolved = 0
        for (position, entry) in scope.enumerated() {
            stepIndexForListing.append(resolved)
            if let described = entry.unresolved {
                notesBeforeStep[resolved, default: []].append(
                    "TODO: no stable selector — \(described)"
                        + " (step \(position + 1) of the exploration)")
            } else if entry.step != nil {
                resolved += 1
            }
        }
        let sceneBreaks = ((args["scenes"] as? [Any])?.compactMap { $0 as? Int } ?? [])
            .compactMap { number -> Int? in
                guard number >= 1, number <= stepIndexForListing.count else { return nil }
                return stepIndexForListing[number - 1]
            }
        let flow = Flow(name: args["title"] as? String ?? "explored with ft_* (draft)",
                        app: target.app, platform: target.platform,
                        goal: nil, generatedBy: Self.draftGeneratedBy, steps: steps)
        let className = (args["className"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "DraftedScenario"
        let code = ScenarioCodeGen.render(flow: flow, className: className,
                                          generatedBy: Self.draftGeneratedBy,
                                          emptyExpectation: true,
                                          notesBeforeStep: notesBeforeStep,
                                          sceneBreaks: sceneBreaks)
        var header = "Draft for \(target.app.isEmpty ? "(unknown app)" : target.app)"
            + " from \(scope.count) recorded interaction(s)"
            + (unresolved.isEmpty ? "" : ", \(unresolved.count) of which have no stable selector")
            + ".\nWrite it under TestProjects/<project>/scenarios/ and run ft_dry_run."
            + " **The expectation block is intentionally empty** — dry-run will report it,"
            + " and that is the signal to fill in what this scenario proves.\n"
        if interactions.droppedFromFront > 0 {
            header += "note: the \(interactions.droppedFromFront) oldest interaction(s) were"
                + " dropped from the log (it keeps the most recent"
                + " \(InteractionLog.maximumEntries)).\n"
        }
        if droppedCount > 0 {
            header += "note: \(droppedCount) step(s) were pruned at your request.\n"
        }
        if !ignoredNumbers.isEmpty {
            // **黙って無視しない**: 番号を1つ外しただけで別の手が落ちるので、
            // 「効かなかった指定がある」ことに気付けないと誤った下書きを持ち帰る
            header += "⚠️ drop \(ignoredNumbers.map(String.init).joined(separator: ", "))"
                + " is out of range (1…\(recorded.count)) and was ignored.\n"
        }
        return header + Self.pruningListing(scope) + "\n" + code
    }

    /// 下書きに書かれる形。`FTSelector` を通して往復させ、**ScenarioCodeGen が出す綴りに揃える**
    /// (あちらも `serialize` で書き戻すので、ここを通せば注記とコードが必ず一致する)
    static func asWritten(_ selector: String) -> String {
        let parsed = FTSelector.parse(selector)
        let serialized = FTSelector.serialize(primary: parsed.primary, fallbacks: parsed.fallbacks)
        return serialized.isEmpty ? selector : serialized
    }

    /// 下書きの行末に残す但し書き。安定なセレクタには**付けない** ——
    /// 全行にコメントが付くと読み飛ばされ、本当に危ない行が埋もれる
    static func indexedSelectorNote(_ durability: Durability) -> String? {
        durability == .indexed
            ? "index-based selector — breaks if the number of same-type siblings changes"
            : nil
    }

    /// 下書きに入った手の番号付き一覧。**これを見て `drop:` を組む**ので、番号は
    /// 刈り込み後の並び(次の呼び出しで同じ番号が同じ手を指す)
    static func pruningListing(_ scope: [InteractionLog.Entry]) -> String {
        let rows = scope.enumerated().map { index, entry -> String in
            "  \(index + 1). \(entry.summary.isEmpty ? "(unnamed step)" : entry.summary)"
        }
        return "Steps in this draft — re-run with drop: [n, …] to remove the dead ends,"
            + " lastN: <k> to keep only the last k, or scenes: [n, …] to cut it into scenes"
            + " at those steps:\n" + rows.joined(separator: "\n") + "\n"
    }

    static let draftGeneratedBy = "ftester MCP exploration (ft_draft_scenario)"

    /// 「撮り直せ」の案内。**snapshotAfter を渡されているときは黙る** —— 木がその下に続くのに
    /// 撮り直しを勧めると、往復を減らすために足した機能が往復を増やす助言と矛盾する
    static func changedHint(_ args: [String: Any]) -> String {
        args["snapshotAfter"] as? Bool == true ? ""
            : " The screen may have changed — take a fresh ft_snapshot"
    }

    /// 操作した要素を**シナリオで再現するためのセレクタ**(E)。
    ///
    /// ref はセッション限りの番号なのでシナリオには書けない。探索の目的が「操作しながら
    /// 実セレクタを採る」ことである以上、ここで返すべきは ref ではなく**その操作を再現する
    /// 文字列**である。判定は B(曖昧ラベル注記)と同じ `SelectorNaming` を通す。
    ///
    /// **書けないときも黙らない** —— 「安定セレクタが無い」と言われて初めて、読み手は
    /// 祖先を掴むなり id を足すなりの次の手を選べる。
    /// `resolvedRef` は verifiedRef が撮り直した木での ref(掴み直しで動いていることがある)
    func reproductionNote(resolvedRef: Int, args: [String: Any]) -> String {
        guard let snapshot = lastSnapshots[Self.engineKey(args)],
              let element = snapshot.elements.first(where: { $0.ref == resolvedRef })
        else { return "" }
        if let graded = Self.SelectorNaming(snapshot).graded(for: element, in: snapshot) {
            // **セレクタ自体は毎回出すが、但し書きは初回だけ満額**(2026-08-10): id の薄いアプリ
            // (地図等)ではタップのたび同じ index-based 注意が繰り返され、id を足せない他社
            // アプリ相手ではノイズになる。indexedSelectorNote(下書き用・L2677/L2771)とは
            // 文言が違うので鍵を共有しない
            let caution = graded.durability == .indexed
                ? once("indexedSelectorCaution", full: graded.durability.caution,
                      short: " — index-based (see the first note)")
                : ""
            return " (selector: \(graded.selector)\(caution))"
        }
        return " — no stable selector for this element, so a scenario cannot reproduce this"
            + " by selector; use a labelled ancestor, or have the app expose an id"
    }

    /// 座標で撃ったときの断り(E-4)。**推測のセレクタを出さない** —— 座標には
    /// 「その点に何があったか」以上の根拠が無い
    static let coordinateReproductionNote =
        " (coordinates cannot be reproduced by selector — a scenario written from this"
        + " will break as soon as the layout moves)"
    /// `once` の短縮形(セッション内2回目以降)。**理由の再掲は落とす** —— 1度言えば足りる
    static let coordinateReproductionNoteShort =
        " (coordinates cannot be reproduced by selector — see the first note)"

    /// 操作を1手ぶん記録する(F)。**E と同じ `SelectorNaming` でセレクタを決める** ——
    /// 戻り値に出したセレクタと、下書きに書かれるセレクタが食い違わないようにするため。
    ///
    /// セレクタを解決できなかった手も**捨てずに**残す(`unresolved`)。落とすと、
    /// 出来上がったシナリオが実際の手順と食い違う(F-4)
    func recordInteraction(action: String, resolvedRef: Int?, args: [String: Any],
                           text: String? = nil, direction: String? = nil,
                           coordinate: (x: Double, y: Double)? = nil) {
        var selector: String?
        var durability: Durability = .stable
        var described = "\(action)"
        if let resolvedRef,
           let snapshot = lastSnapshots[Self.engineKey(args)],
           let element = snapshot.elements.first(where: { $0.ref == resolvedRef }) {
            let graded = Self.SelectorNaming(snapshot).graded(for: element, in: snapshot)
            selector = graded?.selector
            durability = graded?.durability ?? .stable
            described = "\(action) ref \(resolvedRef) — \(RefGuard.describe(element))"
        } else if let coordinate {
            described = "\(action) at (\(coordinate.x), \(coordinate.y))"
        }
        // ロケータ不要の手(swipe / フォーカス任せの type)はセレクタが無くても行にできる
        let needsLocator = !["swipe", "type", "pressEnter", "back", "home", "appSwitcher"]
            .contains(action) || (resolvedRef != nil || coordinate != nil)
        if selector == nil, needsLocator, action != "swipe" {
            interactions.record(InteractionLog.Entry(step: nil, unresolved: described,
                                                     summary: "\(described) [no selector]"))
            return
        }
        var step = FlowStep(action: action)
        if let selector { step.locator = FTSelector.parse(selector).primary }
        step.text = text
        step.direction = direction
        // **下書きの本文にも格付けを残す**(2026-08-10 の掃討): 注記と ft_tap の戻り値だけに
        // 印を出しても、その場で読まれなければ意味が無い —— 添字付きのセレクタは
        // シナリオに書かれた後で静かに壊れるので、コードの側に理由を残す。
        // **セッション内2回目以降は短縮形**(once)にする — 同じ探索で添字セレクタが何度も
        // 出る画面(一覧行の連打など)では、同じ長文がそのぶん下書きに繰り返される
        step.note = selector == nil ? nil : Self.indexedSelectorNote(durability).map { full in
            once("indexedSelectorNote", full: full, short: "index-based selector (see the first note)")
        }
        let detail = [selector.map { "\"\($0)\"" }, text.map { "\"\($0)\"" }, direction]
            .compactMap { $0 }.joined(separator: " ")
        interactions.record(InteractionLog.Entry(
            step: step, unresolved: nil,
            summary: detail.isEmpty ? action : "\(action) \(detail)"))
    }

    /// 溜まっているプロファイル警告を先頭に付けて1度だけ吐き出す
    private func withPendingWarnings(_ body: String, args: [String: Any]) -> String {
        let key = Self.engineKey(args)
        guard let warnings = pendingWarnings.removeValue(forKey: key), !warnings.isEmpty
        else { return body }
        return warnings.joined(separator: "\n") + "\n" + body
    }

    /// 繰り返し出る注記を初回だけ満額にする(F-6・2026-08-10)。**通すのは dispatch 経由の
    /// 応答組み立てだけ**にすること — static 関数そのものは short/full を知らないまま変えない
    /// (テストの独立性を保つ: 同じ static 関数を単体で呼ぶテストは常に満額の文を見る)
    func once(_ key: String, full: String, short: String) -> String {
        explainedNotes.insert(key).inserted ? full : short
    }

    /// `once` を「注記が空のときはキーを消費しない」形にした版。full が空の画面で先に呼ぶと、
    /// その画面には何も出ないのにキーだけ記録され、次に本当に出た画面(初出のはず)が
    /// 短縮形になってしまう。truncatedLabelNote/unlabeledClickablesNote/ambiguousLabelsNote が共有する
    private func onceNonEmpty(_ key: String, full: String, short: String) -> String {
        guard !full.isEmpty else { return "" }
        return once(key, full: full, short: short)
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
    /// iOS の宛先を udid で指す(H)。ft_list_devices が出す udid をそのまま渡せる
    static let udidProperty: [String: Any] = [
        "type": "string",
        "description": "iOS simulator UDID to drive (as printed by ft_list_devices). Resolved to "
            + "the port of the bridge running on it — a device with no bridge cannot be driven, "
            + "and says so. If you also pass port, the two must agree.",
    ]
    /// 操作系ツールの「結果の木も一緒に返す」スイッチ。**説明で撮り直しを不要にする**まで書く ——
    /// 書かないと、読み手は木を受け取ったうえで習慣的に ft_snapshot を撃つ
    static let snapshotAfterProperty: [String: Any] = [
        "type": "boolean",
        "description": "Append the element list of the resulting screen, exactly as ft_snapshot "
            + "would return it — saves the follow-up ft_snapshot call. It is read immediately "
            + "after the action with no settling wait, so if an animation is still running use "
            + "ft_snapshot with waitFor instead of repeating the action",
    ]
    /// ft_snapshot と ft_scroll_to が共有する木の畳み方(2つ目の定義を作らない)。
    /// 両ツールとも既定は畳む・隠さないなので、説明文もそのまま両方で通用する
    static let expandBulkProperty: [String: Any] = [
        "type": "boolean", "description": "List every element of a large "
            + "same-id group individually. By default 20+ non-interactive leaves sharing one "
            + "id (map pins and the like) are folded into one line plus a label/ref index; "
            + "turn this on when you need their frames",
    ]
    static let interactiveOnlyProperty: [String: Any] = [
        "type": "boolean", "description": "Hide layout-only lines "
            + "(elements with no label/value that are neither operable nor scroll containers) "
            + "— typically half to two thirds of a dense screen. Refs and frames of the "
            + "remaining lines are unchanged, and a hidden element can still be tapped by ref; "
            + "the notes above the tree are computed from the full tree either way",
    ]
    /// 全ツール共通のデバイス選択プロパティ。tool() が無条件で足す
    static let commonDeviceProperties: [(String, [String: Any])] = [
        ("platform", platformProperty),
        ("port", portProperty),
        ("serial", serialProperty),
        ("profile", profileProperty),
        ("project", projectProperty),
        ("allowVersionSkew", allowVersionSkewProperty),
        ("udid", udidProperty),
    ]

    /// 版ズレの押し通し(G-3)。**押し通した回の応答には毎回警告が付く**ことまで書く ——
    /// 「一度断られたから付けておく」という使い方をされると、拒否そのものが無意味になる
    static let allowVersionSkewProperty: [String: Any] = [
        "type": "boolean",
        "description": "Operate even when the bridge's protocol version differs from this build's. "
            + "Off by default because a stale bridge answers with its own version's behaviour and "
            + "notes, and selectors written from those notes are silently wrong. Every response "
            + "then carries a warning.",
    ]

    /// ft_screenshot の既定。**費用は画素数で決まる**(バイト数ではない) —— 平坦な UI では
    /// 原寸 PNG のほうが JPEG より小さいことすらあるので、バイト比較で選ぶと逆に損をする。
    /// 600 は実測で決めた: iPhone 17 Pro(1179px)の E2E 画面で CJK 本文もステータスバーも読め、
    /// 画素は 1/2.4。地図のような密な画面はこれでは潰れうるので maxWidth / fullSize で逃がす
    static let screenshotMaxWidth = 600
    static let screenshotQuality = 0.6

    static let toolDefinitions: [[String: Any]] = [
        tool("ft_status", "Check the device/bridge connection state", [:]),
        tool("ft_list_devices", "List the devices this Mac can drive (simulators, emulators and "
            + "physical devices) with the udid/serial the other tools take. It works before any "
            + "profile exists — without a machine profile it lists what is booted or connected now", [
            "platform": ["type": "string", "enum": ["ios", "android"],
                         "description": "Only this platform (default: both)"],
            "profile": profileProperty,
        ], scope: .project),
        tool("ft_list_apps", "List the apps installed on the device. Use it to find the bundle ID "
            + "(iOS) / package name (Android) that ft_launch takes. By default it lists user apps "
            + "only — the maps, browser and other preinstalled apps are system apps, so reach for "
            + "filter or includeSystem when the app you want is not in the list", [
            "filter": ["type": "string", "description": "Only apps whose bundle ID or display name "
                + "contains this (case-insensitive). Passing it searches system apps too, unless "
                + "you also pass includeSystem: false"],
            "includeSystem": ["type": "boolean", "description": "List system apps as well, marked "
                + "[system]. Display names are iOS-only — Android's package manager reports "
                + "package names only"],
        ]),
        tool("ft_logs", "Read why the app died. iOS returns the crash report summary and the .ips "
            + "path for a simulator — there is no runtime log on iOS, so a running app yields "
            + "nothing here; Android returns recent logcat lines. It never goes through the bridge, "
            + "so it still answers after a crash took the bridge with it", [
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (Android). "
                + "Defaults to the bundle ID of the last ft_launch"],
            "platform": platformProperty,
            "serial": serialProperty,
            "lines": ["type": "integer", "description": "Android: how many recent lines to return (default 100)"],
            "sinceSeconds": ["type": "integer", "description": "How far back to look (default 300)"],
            "all": ["type": "boolean", "description": "Android: read the main buffer too, not just crashes"],
        ], scope: .none),
        tool("ft_install", "Install an app from a package file (iOS: .app bundle / Android: .apk)", [
            "packagePath": ["type": "string", "description": "Absolute path of the package file"],
        ], required: ["packagePath"]),
        tool("ft_launch", "Launch the app (terminating it first if it is already running). The app "
            + "itself may restore its previous UI state on launch — system apps such as Maps often "
            + "do — so do not assume the first screen: check with ft_snapshot. "
            + "iOS: com.apple.springboard attaches to the home screen instead, without launching "
            + "anything — that is how you read the home screen or a system dialog", [
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (Android)"],
        ], required: ["bundleId"]),
        tool("ft_open_url", "Deliver a URL (deep link) to the app WITHOUT restarting it — unlike "
            + "ft_launch, the app keeps running and whatever it navigates to is pushed on top of the "
            + "current screen. Use this to jump into a specific screen of an already-running app; use "
            + "ft_launch when you need it from the first screen instead", [
            "url": ["type": "string", "description": "The URL/deep link to deliver"],
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name — the Android "
                + "intent target. Defaults to the bundle ID of the last ft_launch"],
        ], required: ["url"]),
        tool("ft_snapshot", "Get the element list of the current screen. Each line: [ref] Type \"label\" id=... (x,y WxH). "
            + "A line marked scroll is a scrolling container you can pass as scrollFrame. "
            + "Use these refs for tap/type. With waitFor it polls for you instead of you calling this again", [
            "waitFor": ["type": "string", "description": "Wait until this selector is on screen. Same syntax as the DSL: #id, a label, .type, a||b"],
            "timeout": ["type": "number", "description": "Seconds to wait for waitFor (default 5, same as the DSL)"],
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ]),
        tool("ft_tap", "Tap an element (ref) or a coordinate (x,y). x/y match the ft_snapshot frames (iOS=pt / Android=px), not screenshot pixels. "
            + "A ref is re-checked against a fresh tree before the tap, so a ref that moved is retargeted and "
            + "one that is gone is refused; a scroll leftover is tapped with a warning naming what "
            + "it may have hit instead. " + coordinateCaveat, [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "snapshotAfter": snapshotAfterProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
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
            "snapshotAfter": snapshotAfterProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
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
            "scrollFrame": ["type": ["string", "integer"],
                            "description": "Selector of the scrolling container to search inside (e.g. #list_rows), "
                                + "or its ft_snapshot ref (an integer) when the container has no unique id — "
                                + "a duplicated or missing id makes a selector unusable. Pass it when the screen "
                                + "has more than one scrollable area — ft_snapshot marks those lines scroll and "
                                + "says so at the top"],
            "maxSwipes": ["type": "integer", "description": "Swipe limit (default 8, same as the DSL)"],
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
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
        tool("ft_draft_scenario", "Turn the operations you just performed with ft_* into a Swift "
            + "scenario draft and return it as text (it writes no file — place it yourself under "
            + "TestProjects/<project>/scenarios/). Every step is written with the selector this "
            + "server recommended at the time; a step that had no stable selector is kept as a TODO "
            + "comment so the draft still matches what you did. The expectation block comes back "
            + "EMPTY on purpose — assertions are never guessed, and ft_dry_run reports the empty "
            + "block so it cannot be forgotten. The reply lists the steps it used, numbered — an "
            + "exploration records dead ends and retries as faithfully as the real path, so read "
            + "that listing and call again with drop:/lastN: to cut the detours", [
            "all": ["type": "boolean", "description": "Draft from every recorded interaction "
                + "instead of only those since the last ft_launch (the default)"],
            "className": ["type": "string", "description": "Name of the generated class "
                + "(default: DraftedScenario)"],
            "drop": ["type": "array", "items": ["type": "integer"],
                     "description": "Step numbers (1-based, as printed in the listing) to leave "
                        + "out — use it to remove dead-end taps and retries. Applied after lastN"],
            "lastN": ["type": "integer", "description": "Keep only the last N recorded steps "
                + "before applying drop. Use it when the useful part is at the end of a long "
                + "exploration"],
            "scenes": ["type": "array", "items": ["type": "integer"],
                       "description": "Step numbers (as printed in the listing) that START a new "
                        + "scene — e.g. [9, 13] gives scene 1 = steps 1-8, scene 2 = 9-12, "
                        + "scene 3 = 13-end. Each scene gets its own empty expectation, so "
                        + "dry-run asks what every one of them proves. Scene boundaries are never "
                        + "guessed: they say what a scene is for, which the recording cannot know"],
            "title": ["type": "string", "description": "Text put in @Test(...)"],
        ], scope: .none),
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
        tool("ft_drag", "Drag from a point to a point — the only way to pan diagonally (set both axes), "
            + "and the way to expand a half-open bottom sheet (drag its grabber upward). "
            + "Start from fromRef (an element, re-checked against a fresh tree) or fromX/fromY; "
            + "end at toX/toY, or dx/dy to move by that much. "
            + "Coordinates use the same system as the ft_snapshot frames (iOS=pt / Android=px). "
            + "A long durationSeconds drags slowly and leaves no inertia; a short one flicks. "
            + coordinateCaveat, [
            "fromRef": ["type": "integer", "description": "Reference number to start the drag from (its centre). Use it for a sheet grabber instead of reading its frame yourself"],
            "fromX": ["type": "number"],
            "fromY": ["type": "number"],
            "toX": ["type": "number"],
            "toY": ["type": "number"],
            "dx": ["type": "number", "description": "Horizontal travel from the start point (ignored when toX is given)"],
            "dy": ["type": "number", "description": "Vertical travel from the start point — negative moves up (ignored when toY is given)"],
            "durationSeconds": ["type": "number", "description": "Travel time in seconds (default 1.5)"],
            "snapshotAfter": snapshotAfterProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ]),
        tool("ft_pinch","Pinch to zoom. scale > 1 zooms in, 0 < scale < 1 zooms out. Target it with ref, "
            + "or with x/y on a map or canvas that has no element of its own — without either, the fingers "
            + "span the whole screen, so a bottom sheet on top of it may take the gesture instead. "
            + "The actual zoom can be smaller than requested (fingers stay inside the target). "
            + "Pass profile: on iOS — without it Flutter apps do not zoom (see docs/commands.md).", [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "Centre of the pinch, iOS=pt / Android=px (same coordinate system as the snapshot frames). "
                + "Android and the iOS in-app engine honour it; the iOS XCUITest engine cannot (XCTest has no coordinate pinch) and says so"],
            "y": ["type": "number", "description": "Centre of the pinch, iOS=pt / Android=px"],
            "radius": ["type": "number", "description": "Half the width of the pinched area around x/y "
                + "(default: 22% of the screen's short side, clamped to stay on screen)"],
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
        tool("ft_screenshot", "Take a screenshot (returns an image). Use it for visual verification. "
            + "It comes back downscaled — the pixels are NOT the coordinate system, so read x/y off "
            + "ft_snapshot (iOS=pt / Android=px) and never off this image", [
            "maxWidth": ["type": "integer", "description": "Width limit in pixels (default 600). "
                + "Raise it for dense screens where small labels stop being readable"],
            "quality": ["type": "number", "description": "JPEG quality 0-1 (default 0.6)"],
            "fullSize": ["type": "boolean", "description": "Return the original PNG at full "
                + "resolution instead, for when fine detail matters"],
        ]),
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
        guard let value = field.value.map(FlowMatchMode.normalizeInvisibleCharacters), !value.isEmpty
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

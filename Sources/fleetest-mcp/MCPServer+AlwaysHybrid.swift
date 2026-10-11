// MCP の iOS シミュレータは**常に hybrid**(ユーザー決定)。in-app は起動時の注入でしか作れないので、
// ft_launch のたびに起動するアプリへ注入して hybrid を組む(Apple のシステムアプリもシミュレータでは注入できる =
// マップで実測)。実機(注入できない)・SpringBoard・profile 指定(プロファイルのエンジンに従う)は対象外。

import Foundation
import FTBridgeClient
import FTCore

extension MCPServer {

    /// `bundleID` を起動する前に、それへ注入した hybrid へ組み替える。組み替えたら**以後この呼び出しが使う args**
    /// (port = 新しい in-app のポート)を返す。組み替え不要・不可なら nil(今のドライバのまま起動する)。
    ///
    /// **鍵は主(in-app)のポート**: XCUITest のポートを鍵のままにすると、エンジンの照合(`primaryEngineDrift`)が
    /// XCUITest のポートを読んで「エンジンが変わった」と断る。**記憶は移さずに捨てる**(ref と木はエンジンを
    /// またがない = `primaryEngineCheck` と同じ規律。下書きの記録 `interactions` はサーバ全体なので失われない)。
    /// **同じ端末の古いポートは名指しの記憶から外す** —— 残すと `seenExplicitIOSPorts` が2本になり、宛先を書かない
    /// 呼び出しが「どの端末か曖昧」で断られる。戻り値の `previous` は起動に失敗したときの巻き戻し用
    func hybridUpgradeArgs(bundleID: String, args: [String: Any], current: AppDriver) async throws
        -> (args: [String: Any], previous: HybridUpgradeRollback)? {
        guard makeDriver == nil, args["profile"] == nil, Self.platformName(args) == "ios",
              bundleID != Self.springboardBundleID else { return nil }
        let key = Self.engineKey(args)
        guard let udid = udids[key] ?? nil, Self.isBootedSimulator(udid) else { return nil }
        let engine = engines[key]
        if engine == "hybrid", (current as? HybridFallbackDriver)?.ownBundleID == bundleID { return nil }
        let xcuiPort: UInt16? = switch engine {
        case "xcuitest": connectedPorts[key]
        case "hybrid": hybridFallbackPorts[key] ?? nil
        default: nil
        }
        guard let xcuiPort, let repoRoot = try? RepoRoot.find() else { return nil }
        let inAppPort = try await Self.inAppPort(for: bundleID, udid: udid, xcuiPort: xcuiPort, repoRoot: repoRoot)
        try InAppLauncher(repoRoot: repoRoot, udid: udid, port: inAppPort).buildIfNeeded()
        let xcuiEndpoint = BridgeEndpoint.load(port: xcuiPort, repoRoot: repoRoot)
        let attach = AppAttachDriver(port: xcuiPort, host: xcuiEndpoint.host, bundleID: bundleID, physicalUDID: nil)
        let hybrid = HybridDriverComposition.inAppFirst(
            inApp: InAppDriver(repoRoot: repoRoot, udid: udid, port: inAppPort), attach: attach,
            foreignApp: SessionRecoveryDriver(base: BridgeClient(endpoint: xcuiEndpoint)), bundleID: bundleID)
        var out = args
        out["port"] = Int(inAppPort)
        let newKey = Self.engineKey(out)
        let oldPort = connectedPorts[key]
        let previous = HybridUpgradeRollback(
            key: key, session: sessions[key], newKey: newKey, newKeySession: sessions[newKey],
            lastExplicitIOSTarget: lastExplicitIOSTarget, seenExplicitIOSPorts: seenExplicitIOSPorts,
            inAppPort: inAppPort, udid: udid, repoRoot: repoRoot)
        forgetDeviceState(key)
        forgetDeviceState(newKey)
        drivers[newKey] = hybrid
        engines[newKey] = "hybrid"
        udids[newKey] = udid
        connectedPorts[newKey] = inAppPort
        hybridFallbackPorts[newKey] = xcuiPort
        connections[newKey] = Self.connectionLabel(port: inAppPort, udid: udid)
        if let oldPort, oldPort != inAppPort { seenExplicitIOSPorts.remove(oldPort) }
        rememberResolvedTarget(platform: "ios", args: out, iosPort: inAppPort, iosUDID: udid, androidSerial: nil)
        Self.logStderr("launching \(bundleID) with the in-app bridge on port \(inAppPort) and the XCUITest"
            + " bridge (port \(xcuiPort)) as fallback — the hybrid engine, matching the run default")
        return (out, previous)
    }

    /// ft_launch の内部の印(再帰で呼ぶときだけ付ける。MCP の引数ではないので call() の入口を通らない)
    static let skipsHybridUpgrade = "__skipsHybridUpgrade"

    /// 応答の先頭の text に1行足す
    static func prependingText(_ line: String, to content: [[String: Any]]) -> [[String: Any]] {
        guard let index = content.firstIndex(where: { $0["text"] is String }) else {
            return [["type": "text", "text": line]] + content
        }
        var out = content
        out[index]["text"] = line + (out[index]["text"] as? String ?? "")
        return out
    }

    /// 注入した起動に失敗したときに、組み替える前へ戻すための控え(端末の記憶と名指しの記憶)
    struct HybridUpgradeRollback {
        let key: String
        let session: DeviceSession?
        let newKey: String
        let newKeySession: DeviceSession?
        let lastExplicitIOSTarget: (port: UInt16, udid: String?)?
        let seenExplicitIOSPorts: Set<UInt16>
        let inAppPort: UInt16
        let udid: String
        let repoRoot: URL
    }

    /// 組み替えで注入した in-app が、同じ端末・同じアプリとして答えるか(= 起動は通った)
    func injectedBridgeAnswers(_ previous: HybridUpgradeRollback, bundleID: String) async -> Bool {
        guard let status = try? await BridgeClient(endpoint: BridgeEndpoint.load(
            port: previous.inAppPort, repoRoot: previous.repoRoot)).status(timeout: 2) else { return false }
        return Self.ledgerPortIsReusable(refused: false, status: status, udid: previous.udid, bundleID: bundleID)
    }

    /// **組み替える前へ戻す**(起動に失敗した hybrid のまま残さない。残すと次の ft_launch も「もう hybrid」と読んで
    /// 同じ失敗を繰り返し、元の XCUITest のドライバへ戻る口が MCP の起動し直ししか無くなる)。
    /// 注入した側の後始末(アプリの終了と台帳の削除)もここで行う = 供給(BridgeProvisioner)の失敗時と同じ
    func rollBackHybridUpgrade(_ previous: HybridUpgradeRollback) {
        sessions[previous.newKey] = previous.newKeySession
        sessions[previous.key] = previous.session
        lastExplicitIOSTarget = previous.lastExplicitIOSTarget
        seenExplicitIOSPorts = previous.seenExplicitIOSPorts
        InAppBridgeState.terminateAndRemove(at: InAppBridgeState.url(
            stateDir: previous.repoRoot.appendingPathComponent(".fleetest"), port: previous.inAppPort))
    }

    /// 注入先のポート。**同じ端末・同じアプリの台帳があり、今そのポートを使っているのが自分だと言えるときだけ使い回す**
    /// (`ledgerPortIsReusable`)。無ければ空きポート(`XCUIBridgeResolver.freePort` = 供給と同じ採番・in-app の台帳が
    /// 残るポートは後回し)を、実際に誰も待ち受けていない(接続拒否)と確かめてから採る
    static func inAppPort(for bundleID: String, udid: String, xcuiPort: UInt16, repoRoot: URL) async throws -> UInt16 {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        for port in BridgeDiscovery.portRange where port != xcuiPort {
            guard let record = InAppBridgeState.record(stateDir: stateDir, port: port),
                  record.udid.caseInsensitiveCompare(udid) == .orderedSame, record.bundleID == bundleID else { continue }
            let refused = BridgeDiscovery.connectProbe(port: port, repoRoot: repoRoot) == .refused
            let status = refused ? nil : try? await BridgeClient(
                endpoint: BridgeEndpoint.load(port: port, repoRoot: repoRoot)).status(timeout: 2)
            if ledgerPortIsReusable(refused: refused, status: status, udid: udid, bundleID: bundleID) { return port }
        }
        var occupied: Set<UInt16> = [xcuiPort]
        while let candidate = XCUIBridgeResolver.freePort(
            repoRoot: repoRoot, occupied: occupied,
            refusesConnection: { BridgeDiscovery.connectProbe(port: $0, repoRoot: repoRoot) == .refused }) {
            if BridgeDiscovery.connectProbe(port: candidate, repoRoot: repoRoot) == .refused { return candidate }
            occupied.insert(candidate)
        }
        throw MCPError("no free port for the in-app bridge of \(bundleID) — stop unused bridges"
            + " (fleetest bridge down --port <N>) and try again")
    }

    /// 台帳のポートを使い回してよいか(純粋関数)。**台帳はポートしか持たず古いまま残る**ので、ポートの番号だけで
    /// 「自分のもの」と決めない(bridge-provision.md)。よいのは ①誰も待ち受けていない ②同じ端末・同じアプリの in-app が
    /// 答える、の2つだけ。**答えない相手は使わない**(背面で止まった自アプリかもしれないが、塞がった別の端末の
    /// ランナーと区別できない。使わなければ空きポートを採るだけで済む)
    static func ledgerPortIsReusable(refused: Bool, status: StatusResponse?, udid: String, bundleID: String) -> Bool {
        if refused { return true }
        guard let status else { return false }
        return status.engine == "inapp" && status.sessionBundleID == bundleID
            && status.udid?.caseInsensitiveCompare(udid) == .orderedSame
    }

    static func isBootedSimulator(_ udid: String) -> Bool {
        ((try? SimulatorCatalog.devices()) ?? []).contains { $0.booted && $0.udid == udid }
    }

    /// hybrid の `resume: true`(状態を保ったまま前面へ)。**自アプリは XCUITest で前面へ出してから attach で向け直す** ——
    /// in-app の activate は既定実装から launch = 注入付きの起動し直しへ落ちる。前面へ出た後に in-app が答えなければ
    /// 注入の無いプロセス(落ちていた等)なので false を返し、呼び手は普通の起動(注入)へ落ちる。
    /// 別アプリは hybrid が XCUITest 側へ寄せる(HybridFallbackDriver.activate)ので true
    func resumeOnHybrid(bundleID: String, driver: AppDriver, key: String) async throws -> Bool {
        guard let hybrid = driver as? HybridFallbackDriver, hybrid.ownBundleID == bundleID else {
            try await driver.activate(bundleID: bundleID)
            return true
        }
        guard let xcuiPort = hybridFallbackPorts[key] ?? nil, let inAppPort = connectedPorts[key],
              let repoRoot = try? RepoRoot.find() else { return false }
        // **待受が無ければ注入したプロセスは居ない**(背面で止まった in-app も待受は持ったまま)。ここで XCUITest の
        // activate を撃つと注入の無い起動が1回挟まってから、呼び手の注入付き起動がもう1回走る
        guard BridgeDiscovery.connectProbe(port: inAppPort, repoRoot: repoRoot) != .refused else { return false }
        try await BridgeClient(endpoint: BridgeEndpoint.load(port: xcuiPort, repoRoot: repoRoot))
            .activate(bundleID: bundleID)
        guard (try? await BridgeClient(endpoint: BridgeEndpoint.load(port: inAppPort, repoRoot: repoRoot))
            .status(timeout: 3)) != nil else { return false }
        try await driver.attach(bundleID: bundleID)
        return true
    }
}

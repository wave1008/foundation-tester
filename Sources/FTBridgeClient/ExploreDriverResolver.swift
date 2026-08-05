// profile を渡さない探索(MCP の ft_*)向けのドライバ組み立て。
//
// **稼働中の in-app ブリッジを見つけたら、それを主にした hybrid を組む**(2026-08-05)。
// それ以前は XCUITest へ振り替えていた(XCUIBridgeResolver 冒頭の 2026-07-28 決定)。
// 振り替えの根拠は「in-app は home/appSwitcher/drag/座標 press を実装できず、ft_* は
// StepExecutor を通らないので素の 501 で落ちる」だったが、その穴は HybridFallbackDriver が
// 埋めた(2026-08-04)ので前提が消えた。**利用者の実行既定は hybrid** なので、揃えないと
// 探索と実行で snapshot の中身もジェスチャの成否も変わる(Compose のダブルタップ・
// Flutter のピンチは XCUITest では届かない)。
//
// 合成できないとき(実機・同名デバイスが複数・XCUITest ブリッジを用意できない)は
// **従来の振り替え/素通しへ落とす** —— 機能が減る方向には倒さない。

import FTCore
import Foundation

public enum ExploreDriverResolver {

    /// 何を組むかの決定だけ(IO 無し)。判断材料は呼び出し側が集める
    public enum Plan: Equatable, Sendable {
        /// 指定ポートをそのまま使う(xcuitest・無応答)
        case direct(port: UInt16)
        /// in-app を主に、XCUITest を WebView 委譲先兼フォールバックにする(実行側と同じ形)
        case hybrid(inappPort: UInt16, xcuiPort: UInt16, bundleID: String)
        /// in-app しか用意できない(XCUITest ブリッジが立てられなかった)
        case inappOnly(port: UInt16)
        /// in-app だが合成できないので XCUITest へ振り替える(従来挙動)
        case rerouteToXCUI(port: UInt16)
    }

    /// - Parameters:
    ///   - engine: 指定ポートの /status.engine(nil = 無応答・申告なし)
    ///   - udid: デバイス名から一意に引けた simulator の udid(nil = 実機・同名複数・不明)
    ///   - xcuiPort: 同じデバイスの XCUITest ブリッジ(nil = 見つからず起動もできなかった)
    public static func plan(preferred: UInt16, engine: String?, sessionBundleID: String?,
                            udid: String?, xcuiPort: UInt16?) -> Plan {
        guard engine == "inapp" else { return .direct(port: preferred) }
        // 注入は simulator にしかできない。**engine の申告だけで in-app を作らない**
        // (実機で作ると dylib 注入を試みて必ず失敗する。MCPEngineFollowingTests と同じ規律)
        guard udid != nil, let bundleID = sessionBundleID else {
            return xcuiPort.map { Plan.rerouteToXCUI(port: $0) } ?? .direct(port: preferred)
        }
        guard let xcuiPort else { return .inappOnly(port: preferred) }
        return .hybrid(inappPort: preferred, xcuiPort: xcuiPort, bundleID: bundleID)
    }

    public struct Resolved {
        public let driver: AppDriver
        /// 実際に主となったエンジン。**呼び出し側の助言文がこれで変わる**
        /// (xcuitest のときだけ「Compose のダブルタップは届かない」と言う)
        public let engine: String
    }

    /// 稼働中ブリッジを見て組み立てる。XCUITest ブリッジが要るケースでは
    /// XCUIBridgeResolver に探索/起動を任せる(起動を伴うと分単位ブロックし得る)
    public static func resolve(preferred: UInt16, repoRoot: URL?,
                               logger: @Sendable (String) -> Void = { _ in }) async -> Resolved {
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: preferred, repoRoot: $0) }
            ?? BridgeEndpoint(port: preferred)
        // timeout を明示する(引数なしは sessionTimeout=45s に上書きされる。XCUIBridgeResolver と同じ)
        let status = try? await BridgeClient(port: endpoint.port, timeoutSeconds: 3,
                                             host: endpoint.host).status(timeout: 3)
        guard status?.engine == "inapp" else {
            // **XCUITest はセッション制**(ランナー再起動で全操作が 409)。実行側と同じ回復を
            // 与えておく = 探索中にランナーが落ちても次の操作から戻れる
            return Resolved(driver: SessionRecoveryDriver(
                base: BridgeClient(port: endpoint.port, host: endpoint.host)),
                            engine: status?.engine ?? "xcuitest")
        }
        let udid = (status?.device).flatMap(bootedSimulatorUDID)
        // in-app が居る時点で XCUITest 側は必ず要る(合成のフォールバック先 or 振り替え先)
        let resolution = await XCUIBridgeResolver.resolve(preferred: preferred, repoRoot: repoRoot,
                                                         logsReroute: false, logger: logger)
        // 用意できなかったときは指定ポート(= in-app 自身)が返る
        let xcuiPort: UInt16? = resolution.endpoint.port == preferred ? nil : resolution.endpoint.port

        switch plan(preferred: preferred, engine: status?.engine,
                    sessionBundleID: status?.sessionBundleID, udid: udid, xcuiPort: xcuiPort) {
        case .direct(let port), .rerouteToXCUI(let port):
            // ここへ来るのは in-app に注入し直せないとき(実機・同名デバイス複数・アプリ不明)。
            // **理由まで出す**: 「hybrid になるはず」で読む側が、なぜならなかったかを追えるように
            logger("port \(preferred) is an in-app bridge, but this device cannot be driven through it"
                + " (\(udid == nil ? "the simulator could not be identified" : "the bridge did not report its app"))"
                + " — using the XCUITest bridge (port \(port))")
            return Resolved(driver: SessionRecoveryDriver(
                base: BridgeClient(port: port, host: resolution.endpoint.host)),
                            engine: "xcuitest")
        case .inappOnly(let port):
            guard let repoRoot, let udid else {
                // **無言で落とさない**: 同名シミュレータが複数だと udid を引けず、エンジンだけが
                // 静かに変わる(ジェスチャの効き方が変わって見える)。上の分岐と同じ扱い
                logger(Self.unidentifiedSimulatorNote(port: port, repoRoot: repoRoot))
                return Resolved(driver: BridgeClient(port: port, host: endpoint.host), engine: "xcuitest")
            }
            logger("port \(port) is an in-app bridge — using it (no XCUITest bridge for fallback:"
                + " home/appSwitcher/drag and coordinate press are unavailable)")
            return Resolved(driver: InAppDriver(repoRoot: repoRoot, udid: udid, port: port),
                            engine: "inapp")
        case .hybrid(let inappPort, let xcuiPort, let bundleID):
            guard let repoRoot, let udid else {
                logger(Self.unidentifiedSimulatorNote(port: inappPort, repoRoot: repoRoot))
                return Resolved(driver: BridgeClient(port: xcuiPort, host: resolution.endpoint.host),
                                engine: "xcuitest")
            }
            logger("port \(inappPort) is an in-app bridge — driving it with the XCUITest bridge"
                + " (port \(xcuiPort)) as fallback, matching the hybrid run engine")
            // attach は**同じインスタンス**を委譲とフォールバックの両方へ(MCPServer.iosDriver と同じ理由)
            let attach = AppAttachDriver(port: xcuiPort, bundleID: bundleID)
            let inapp = InAppDriver(repoRoot: repoRoot, udid: udid, port: inappPort)
            return Resolved(driver: HybridFallbackDriver(
                primary: WebViewDelegatingDriver(primary: inapp, delegated: attach),
                fallback: attach), engine: "hybrid")
        }
    }

    /// 諦めた理由(Xcode はランタイムごとに同名のシミュレータを作るので、同名2台は普通に起きる)
    static func unidentifiedSimulatorNote(port: UInt16, repoRoot: URL?) -> String {
        let cause = repoRoot == nil
            ? "the repository root could not be resolved"
            : "the simulator could not be identified (several booted simulators share its name)"
        return "port \(port) is an in-app bridge, but \(cause)"
            + " — falling back to the XCUITest bridge. Pass profile: to target a device by UDID."
    }

    /// /status はデバイス名しか返さないので名前で引く。**同名が複数起動していたら諦める**
    /// (誤ったデバイスへ注入するより従来どおり振り替える。XCUIBridgeResolver.start と同じ判断)
    private static func bootedSimulatorUDID(_ device: String) -> String? {
        let booted = ((try? SimulatorCatalog.devices()) ?? []).filter { $0.booted && $0.name == device }
        return booted.count == 1 ? booted[0].udid : nil
    }
}

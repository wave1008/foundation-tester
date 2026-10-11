// profile を渡さない探索(MCP の ft_*)向けのドライバ組み立て。
//
// **MCP の iOS は常に XCUITest**(ユーザー決定)。接続先が in-app ブリッジでも、同じデバイスの XCUITest ブリッジへ
// 振り替える(無ければ XCUIBridgeResolver が起動する)。in-app を主にした hybrid は組まない —— in-app の合成タッチは
// 注入される前提で作られていないアプリ(Apple マップの経路カード等)で効かないまま ok を返し、別アプリ・システムアラートの
// 扱いでもエンジンを意識させた。XCUITest を用意できなければ in-app へは落とさず断る。

import FTCore
import Foundation

public enum ExploreDriverResolver {

    /// 何を組むかの決定だけ(IO 無し)。判断材料は呼び出し側が集める
    public enum Plan: Equatable, Sendable {
        /// 指定ポートをそのまま使う(xcuitest・無応答)
        case direct(port: UInt16)
        /// in-app だったので同じデバイスの XCUITest へ振り替える
        case rerouteToXCUI(port: UInt16)
        /// in-app だったが XCUITest ブリッジを用意できなかった(in-app へは落とさない)
        case noXCUITest(inAppPort: UInt16)
    }

    /// - Parameters:
    ///   - engine: 指定ポートの /status.engine(nil = 無応答・申告なし)
    ///   - xcuiPort: 同じデバイスの XCUITest ブリッジ(nil = 見つからず起動もできなかった)
    public static func plan(preferred: UInt16, engine: String?, xcuiPort: UInt16?) -> Plan {
        guard engine == "inapp" else { return .direct(port: preferred) }
        return xcuiPort.map { .rerouteToXCUI(port: $0) } ?? .noXCUITest(inAppPort: preferred)
    }

    public struct Resolved {
        public let driver: AppDriver
        /// 実際に主となったエンジン。**呼び出し側の助言文がこれで変わる**
        /// (xcuitest のときだけ「Compose のダブルタップは届かない」と言う)
        public let engine: String
        /// 特定できたシミュレータの udid(MCP が xcuitest でもバンドルマーカー判定
        /// = AppBundleInspector を使えるように運ぶ)、実機なら `.device` 記録由来の UDID。
        /// どちらも特定できなければ nil
        public let udid: String?
        /// **実際に繋いだポート**(in-app から振り替えたときは XCUITest 側)。呼び手はこれを「繋いだ先」として覚える ——
        /// 指定ポート(in-app)を覚えると、エンジンの照合がそちらへ問い合わせて毎回「エンジンが変わった」と読み、
        /// 呼び出しのたびにドライバを作り直す(実地で踏んだ)
        public let port: UInt16

        public init(driver: AppDriver, engine: String, udid: String?, port: UInt16) {
            self.driver = driver
            self.engine = engine
            self.udid = udid
            self.port = port
        }
    }

    /// 稼働中ブリッジを見て組み立てる。XCUITest ブリッジが要るケースでは
    /// XCUIBridgeResolver に探索/起動を任せる(起動を伴うと分単位ブロックし得る)
    public static func resolve(preferred: UInt16, repoRoot: URL?,
                               logger: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Resolved {
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: preferred, repoRoot: $0) }
            ?? BridgeEndpoint(port: preferred)
        // timeout を明示する(引数なしは sessionTimeout=45s に上書きされる。XCUIBridgeResolver と同じ)
        let status = try? await BridgeClient(endpoint: endpoint, timeoutSeconds: 3).status(timeout: 3)
        // **答えないポートが、背面で止まった in-app ブリッジのことがある**(in-app はアプリの中に住むので、
        // アプリが suspend すると HTTP に答えない)。そのポートの in-app 台帳と起動中のシミュレータが一致すれば、
        // そのシミュレータの XCUITest ブリッジへ振り替える(答えない XCUITest として扱うと 49 秒待った末に断る)
        let suspended = status == nil
            ? Self.suspendedInAppRecord(
                record: repoRoot.flatMap { InAppBridgeState.read(at: InAppBridgeState.url(
                    stateDir: $0.appendingPathComponent(".fleetest"), port: endpoint.port)) }
                    .map { (udid: $0.udid, bundleID: $0.bundleID) },
                bootedSimulators: ((try? SimulatorCatalog.devices()) ?? []).filter(\.booted)
                    .map { (udid: $0.udid, name: $0.name) })
            : nil
        let udid = (status?.device).flatMap(bootedSimulatorUDID) ?? suspended?.udid
        guard status?.engine == "inapp" || suspended != nil else {
            // **実機は `/status.udid` を自己申告できない**(SIMULATOR_UDID が無い)ので、
            // 名前引きも当たらない実機はここまで `udid == nil` のまま。`.device` ファイルは
            // 実機の物理トランスポート確立時にしか書かれない(BridgeDeviceRecord 宣言)ので、
            // 読めれば「この bare port は実機」と分かる。ここで拾って BridgeClient へ渡すと、
            // install/uninstall/clearAppData の対象特定(BridgeClient.resolveTarget(status:...))が
            // 申告に頼らず devicectl 経路へ回せる
            // `status.udid` の自己申告があれば必ずシミュレータ(申告は記録より新しい)。
            // 名前引きの失敗だけで記録を読むと、実機ポートを使い回したシミュレータが古い記録で
            // 実機と誤認され、knownTarget で最優先されてしまう
            let physicalUDID = (status?.udid == nil && udid == nil)
                ? repoRoot.flatMap { BridgeDeviceRecord.load(port: endpoint.port, repoRoot: $0) }
                : nil
            // **XCUITest はセッション制**(ランナー再起動で全操作が 409)。実行側と同じ回復を
            // 与えておく = 探索中にランナーが落ちても次の操作から戻れる
            // launch はシナリオ実行と同じく FastLaunchDriver(シミュレータと分かったときだけ。判定は wrapping の1箇所)
            let client = BridgeClient(port: endpoint.port, host: endpoint.host, physicalUDID: physicalUDID)
            return Resolved(driver: SessionRecoveryDriver(
                base: FastLaunchDriver.wrapping(client, simulatorUDID: physicalUDID == nil ? udid : nil)),
                            engine: status?.engine ?? "xcuitest", udid: udid ?? physicalUDID, port: endpoint.port)
        }
        // in-app だった(または背面で止まった in-app)= 同じデバイスの XCUITest ブリッジへ振り替える(無ければ起動する)
        let resolution = if let suspended {
            await XCUIBridgeResolver.resolve(preferred: preferred, inAppDevice: suspended.name,
                                             sessionBundleID: suspended.bundleID, repoRoot: repoRoot,
                                             logsReroute: false, logger: logger)
        } else {
            await XCUIBridgeResolver.resolve(preferred: preferred, repoRoot: repoRoot,
                                             logsReroute: false, logger: logger)
        }
        // 用意できなかったときは指定ポート(= in-app 自身)が返る
        let xcuiPort: UInt16? = resolution.endpoint.port == preferred ? nil : resolution.endpoint.port
        switch plan(preferred: preferred, engine: "inapp", xcuiPort: xcuiPort) {
        case .rerouteToXCUI(let port):
            logger("port \(preferred) is an in-app bridge — MCP drives iOS through XCUITest, so using the"
                + " XCUITest bridge of the same device (port \(port))")
            // endpoint をそのまま渡す(host だけ渡すと usb トンネルの token を落とす)
            return Resolved(driver: SessionRecoveryDriver(
                base: FastLaunchDriver.wrapping(BridgeClient(endpoint: resolution.endpoint), simulatorUDID: udid)),
                            engine: "xcuitest", udid: udid, port: port)
        case .noXCUITest, .direct:   // engine: "inapp" を渡しているので .direct は来ない
            throw ExploreDriverResolverError.noXCUITestBridge(inAppPort: preferred)
        }
    }

    /// 答えないポートを「背面で止まった in-app ブリッジ」と読んでよいか(純粋関数)。台帳の udid が**起動中の**
    /// シミュレータで、その名前が起動中のシミュレータの中で一意なときだけ(XCUITest の相方はデバイス名で探すので、
    /// 同名2台では別の機の相方を掴む)。台帳が無い・止まったシミュレータの残骸は nil = 従来どおり答えないポートとして扱う
    static func suspendedInAppRecord(record: (udid: String, bundleID: String)?,
                                     bootedSimulators: [(udid: String, name: String)])
        -> (udid: String, bundleID: String, name: String)? {
        guard let record,
              let name = bootedSimulators.first(where: { $0.udid == record.udid })?.name,
              bootedSimulators.filter({ $0.name == name }).count == 1 else { return nil }
        return (record.udid, record.bundleID, name)
    }

    /// /status はデバイス名しか返さないので名前で引く。**同名が複数起動していたら諦める**
    /// (誤ったデバイスへ向けない。XCUIBridgeResolver.start と同じ判断)
    private static func bootedSimulatorUDID(_ device: String) -> String? {
        let booted = ((try? SimulatorCatalog.devices()) ?? []).filter { $0.booted && $0.name == device }
        return booted.count == 1 ? booted[0].udid : nil
    }
}

public enum ExploreDriverResolverError: Error, LocalizedError {
    case noXCUITestBridge(inAppPort: UInt16)

    public var errorDescription: String? {
        switch self {
        case .noXCUITestBridge(let port):
            "port \(port) is an in-app bridge, and no XCUITest bridge could be prepared on the same device —"
                + " MCP drives iOS only through XCUITest. Start one with `fleetest bridge up --device <name>`"
                + " and try again"
        }
    }
}

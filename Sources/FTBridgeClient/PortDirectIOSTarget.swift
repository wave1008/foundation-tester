// `--port` 直指定(プロファイル無し)経路の iOS ワーカー。provision を通らないので、宛先も
// 実機かどうかも establish が残した記録から引く。`fleetest run` と `fleetest api run` は
// オプションも配線も別の2実装(CLAUDE.md)だが、この判定は共有する —— 片方だけ直すと
// もう片方が usb トンネルの実機で 401 のまま残る。

import FTCore
import Foundation

public struct PortDirectIOSTarget: Sendable {
    public let endpoint: BridgeEndpoint
    /// `.fleetest/bridge-<port>.device` があれば実機(IOSDeviceTransport.establish しか書かない)。
    /// 渡さないと子プロセスは `physical=false` で走り、usb トンネルの token を引かず
    /// (ScenarioRunnerMain の physicalUDID)、install も simctl 経路へ落ちる
    public let physicalUDID: String?

    public init(port: UInt16) {
        endpoint = BridgeEndpoint.resolved(port: port)
        physicalUDID = BridgeDeviceRecord.resolved(port: port)
    }

    public var port: UInt16 { endpoint.port }
    public var physical: Bool { physicalUDID != nil }

    public func makeDriver(timeoutSeconds: TimeInterval = 120) -> BridgeClient {
        BridgeClient(endpoint: endpoint, timeoutSeconds: timeoutSeconds, physicalUDID: physicalUDID)
    }

    /// simulatorUDID: 呼び手がシミュレータの同名一意から解決した UDID(実機なら無視して記録の udid)
    public func connection(simulatorUDID: String?) -> DriverConnection {
        DriverConnection(platform: "ios", port: port, udid: physicalUDID ?? simulatorUDID,
                         physical: physical, host: endpoint.host)
    }

    /// 呼び手が渡した udid を優先し、無ければブリッジが /status で申告した Simulator の udid
    /// (`SIMULATOR_UDID`)。空文字は無いものとして扱う
    public static func simulatorUDID(explicit: String?, reported: String?) -> String? {
        for candidate in [explicit, reported] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// ポートに結び付いた Simulator の udid をブリッジ自身に聞く(実機は記録の udid を持つので聞かない)。
    /// 答えられない(ブリッジ不達・旧ブリッジ・実機)ときは nil = 呼び手は「鍵が無い」まま進む
    public func reportedSimulatorUDID() async -> String? {
        guard !physical else { return nil }
        return try? await makeDriver(timeoutSeconds: 5).status().udid
    }

    public func makeWorker(label: String, simulatorUDID: String?) -> RunWorker {
        RunWorker(label: label, platform: "ios", driver: makeDriver(),
                  connection: connection(simulatorUDID: simulatorUDID))
    }
}

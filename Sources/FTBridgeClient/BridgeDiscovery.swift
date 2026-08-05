// profile を渡さない MCP(ft_*)が「既定ポートに誰も居ない」ときに使う宛先探索。
//
// **既定 8123 は固定できない**: `bridge up` は稼働中ブリッジの再利用や pid ファイルの残りで
// 別ポート(8124 等)を選ぶ。既定を決め打ちすると全ツールが接続待ちでタイムアウトし、
// 利用者は全呼び出しに port: を書く羽目になる(2026-08-06 の外部フィードバック #2)。
//
// 方針(2026-08-06 ユーザー決定): **生きているブリッジが1本だけなら自動採用**・複数なら
// デバイス名付きで列挙してエラー(取り違えを作らない)・0本なら起動方法を返す。
// **port: を明示した呼び出しでは探索しない** —— 宛先を利用者が決めているため。

import FTCore
import Foundation

public enum BridgeDiscovery {

    /// 応答した1本。device/engine は取り違え防止のため**必ず利用者に見せる**
    public struct Found: Sendable, Equatable {
        public let port: UInt16
        public let device: String
        public let engine: String

        public init(port: UInt16, device: String, engine: String) {
            self.port = port
            self.device = device
            self.engine = engine
        }

        public var label: String { "port \(port) (\(device), \(engine))" }
    }

    public enum Decision: Equatable {
        /// 指定/既定ポートが応答した = 従来どおり
        case usePreferred
        /// 生きているのが1本だけ
        case adopt(Found)
        case none
        /// 複数 = 利用者に選ばせる
        case ambiguous([Found])
    }

    /// 判断だけ(IO 無し)。材料は呼び出し側が集める
    public static func decide(preferredAlive: Bool, found: [Found]) -> Decision {
        if preferredAlive { return .usePreferred }
        let sorted = found.sorted { $0.port < $1.port }
        switch sorted.count {
        case 0: return .none
        case 1: return .adopt(sorted[0])
        default: return .ambiguous(sorted)
        }
    }

    public static let portRange = XCUIBridgeResolver.portRange

    /// 指定ポートが応答するか。**timeout を明示する**(引数なし status() は sessionTimeout=45s に
    /// 上書きされ、ウェッジした孤児ブリッジ1本で待たされる。XCUIBridgeResolver と同じ理由)
    public static func isAlive(port: UInt16, repoRoot: URL?) async -> Bool {
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        let status = try? await BridgeClient(port: endpoint.port, timeoutSeconds: 2,
                                             host: endpoint.host).status(timeout: 2)
        return status != nil
    }

    /// 範囲を並列に走査して応答した全ポートを返す
    public static func scan(excluding preferred: UInt16, repoRoot: URL?) async -> [Found] {
        await withTaskGroup(of: Found?.self) { group in
            for port in portRange where port != preferred {
                group.addTask {
                    let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
                        ?? BridgeEndpoint(port: port)
                    guard let status = try? await BridgeClient(
                        port: endpoint.port, timeoutSeconds: 2, host: endpoint.host).status(timeout: 2),
                        status.ready else { return nil }
                    return Found(port: port, device: status.device,
                                 engine: status.engine ?? "xcuitest")
                }
            }
            var result: [Found] = []
            for await entry in group { if let entry { result.append(entry) } }
            return result
        }
    }

    // MARK: - 文言(1箇所に置く。呼び出し側は throw / ログに載せるだけ)

    public static func adoptedNote(preferred: UInt16, found: Found) -> String {
        "no bridge is listening on the default port \(preferred) — using the only running one:"
            + " \(found.label). Pass port: or profile: to pin it."
    }

    public static func noBridgeMessage(preferred: UInt16) -> String {
        "no iOS bridge is running (scanned ports \(portRange.lowerBound)-\(portRange.upperBound))."
            + " Start one with `ftester bridge up --device \"<simulator name>\"`,"
            + " or pass profile: to use a run profile's device."
    }

    public static func ambiguousMessage(preferred: UInt16, found: [Found]) -> String {
        "no bridge is listening on the default port \(preferred), and several are running:"
            + " \(found.map(\.label).joined(separator: ", "))."
            + " Pass port: to pick one, or profile: to use a run profile's device."
    }
}

// profile を渡さない MCP(ft_*)が「既定ポートに誰も居ない」ときに使う宛先探索。
//
// **既定 8123 は固定できない**: `bridge up` は稼働中ブリッジの再利用や pid ファイルの残りで
// 別ポート(8124 等)を選ぶ。既定を決め打ちすると全ツールが接続待ちでタイムアウトし、
// 利用者は全呼び出しに port: を書く羽目になる(2026-08-06 の外部フィードバック #2)。
//
// 方針(ユーザー決定): **生きているブリッジが1本だけなら自動採用**・複数なら
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
        /// `StatusResponse.udid`(申告しない旧ブリッジ・SIMULATOR_UDID の無い実機は nil)。
        /// **scan が status から埋め、実機だけ BridgeDeviceRecord の記録で補う**(resolveUDID)
        public let udid: String?

        public init(port: UInt16, device: String, engine: String, udid: String? = nil) {
            self.port = port
            self.device = device
            self.engine = engine
            self.udid = udid
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
        /// 待受はしているが応答しない = **死んでいない**。乗り換えてはいけない
        case preferredBusy
    }

    /// 判断だけ(IO 無し)。材料は呼び出し側が集める。
    ///
    /// **`preferredBound` を無視して自動採用してはいけない**: XCUITest の quiescence 待ちで
    /// ブリッジのスレッドは数十秒ブロックする(2026-08-06 のログで実測 33.7s)。この間は
    /// /status が返らないが待受は続いているので、応答なしを死と読むと**別デバイスのブリッジへ
    /// 黙って乗り換える** —— 自動採用が防ぐはずの取り違えを自分で作ることになる
    public static func decide(preferredAlive: Bool, preferredBound: Bool, found: [Found]) -> Decision {
        if preferredAlive { return .usePreferred }
        if preferredBound { return .preferredBusy }
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

    /// 誰かがそのポートを**待受しているか**(応答するかではない)。カーネルが accept するので、
    /// アプリのスレッドがブロックしていても true になる —— そこが `isAlive` との差で、
    /// 「応答なし=死」と読まないための材料になる。
    /// IPv4 のみ(実機ブリッジの宛先も provision が IP で残す)。名前解決が要る宛先は false =
    /// 判定材料にしない側へ倒す
    public static func isBound(port: UInt16, repoRoot: URL?) -> Bool {
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.host, &addr.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        // ECONNREFUSED = 誰も居ない(= 乗り換えてよい)。EINPROGRESS だけ結果を待つ
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 300) > 0 else { return false }
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0 else { return false }
        return soError == 0
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
                    let recorded = repoRoot.flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
                    return Found(port: port, device: status.device, engine: status.engine ?? "xcuitest",
                                 udid: resolveUDID(reported: status.udid, recorded: recorded))
                }
            }
            var result: [Found] = []
            for await entry in group { if let entry { result.append(entry) } }
            return result
        }
    }

    /// 稼働ブリッジ → 端末の引き当て。**規則はここ1箇所**(BridgeDiscovery.scan と
    /// BridgeProvisioner.scanRunningBridges が共有する。2つ目の優先順位を書かない)。
    ///
    /// **申告があれば必ずそちら** —— 仮想デバイスは自分で正しい udid を出すので、記録が古くても
    /// 信じない。記録(BridgeDeviceRecord)は実機のときだけの補完(申告できないランナー向け)。
    /// `matchedByName` は `/status.device` を起動中シミュレータのカタログで引いた結果で、
    /// **最後の手段**(旧ブリッジは udid を申告せず記録も持たない)。名前は同名 sim が複数
    /// booted だと一意にならないので、呼び手は特定できたときだけ渡すこと。
    ///
    /// **実機に名前引きは原理的に当たらない**(`/status.device` は汎用名 "iPhone" を返し、
    /// プロファイルの表示名 "iPhone wave(実機)" とは一致しない)。この段が抜けていたために
    /// **生きている実機ブリッジが同一デバイス判定に当たらず、2本目のランナーが立っていた**
    /// (2026-08-14 実測。1台の実機に2本立てると2本目の起動が1本目を即殺し、
    /// 約5分半後に1本目のハング締切の後始末が2本目を道連れにする)
    static func resolveUDID(reported: String?, recorded: String?,
                            matchedByName: String? = nil) -> String? {
        reported ?? recorded ?? matchedByName
    }

    // MARK: - 文言(1箇所に置く。呼び出し側は throw / ログに載せるだけ)

    public static func adoptedNote(preferred: UInt16, found: Found) -> String {
        "no bridge is listening on the default port \(preferred) — using the only running one:"
            + " \(found.label). Pass port: or profile: to pin it."
    }

    public static func noBridgeMessage(preferred: UInt16) -> String {
        "no iOS bridge is running (scanned ports \(portRange.lowerBound)-\(portRange.upperBound))."
            + " Start one with `fleetest bridge up --device \"<simulator name>\"`,"
            + " or pass profile: to use a run profile's device."
    }

    /// **乗り換えない理由まで書く**(黙って待たされたように見えないため)
    public static func busyMessage(preferred: UInt16) -> String {
        "the bridge on port \(preferred) is listening but did not answer within 2s — it is busy,"
            + " not gone (XCUITest blocks its thread while waiting for the screen to settle,"
            + " which can take tens of seconds). Retry in a moment."
            + " Another bridge is not used automatically: it would be a different device."
            + " Pass port: or profile: to target one deliberately."
    }

    public static func ambiguousMessage(preferred: UInt16, found: [Found]) -> String {
        "no bridge is listening on the default port \(preferred), and several are running:"
            + " \(found.map(\.label).joined(separator: ", "))."
            + " Pass port: to pick one, or profile: to use a run profile's device."
    }
}

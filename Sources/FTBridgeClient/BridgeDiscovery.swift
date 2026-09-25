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
        let status = try? await BridgeClient(endpoint: endpoint, timeoutSeconds: 2).status(timeout: 2)
        return status != nil
    }

    /// 誰かがそのポートを**待受しているか**(応答するかではない)。カーネルが accept するので、
    /// アプリのスレッドがブロックしていても true になる —— そこが `isAlive` との差で、
    /// 「応答なし=死」と読まないための材料になる。
    /// IPv4 のみ(実機ブリッジの宛先も provision が IP で残す)。名前解決が要る宛先は false =
    /// 判定材料にしない側へ倒す。**"refused" と "300ms では分からない" のどちらも false**
    /// (この関数の既存契約)—— 破壊的な判定(掃除・kill)で「居ない」の根拠にする呼び手は
    /// `connectProbe` を直接見て2つを区別すること
    public static func isBound(port: UInt16, repoRoot: URL?) -> Bool {
        connectProbe(port: port, repoRoot: repoRoot) == .connected
    }

    /// `isBound` の生の接続試行結果(3値)。負荷が高いと accept backlog が溢れて 300ms の poll が
    /// 間に合わないことがあり、それは「busy(=誰か居る)」であって「誰も居ない」ではない。
    /// **`.refused`(ECONNREFUSED。kernel が明示的に断った)だけが「誰も居ない」の確定証拠**——
    /// `.unknown`(名前解決不能・poll timeout・getsockopt 失敗)を「居ない」扱いにしない
    public enum ConnectProbe: Equatable, Sendable {
        case connected
        case refused
        case unknown
    }

    public static func connectProbe(port: UInt16, repoRoot: URL?, timeoutMs: Int32 = 300) -> ConnectProbe {
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.host, &addr.sin_addr) == 1 else { return .unknown }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return .connected }
        if errno == ECONNREFUSED { return .refused }
        guard errno == EINPROGRESS else { return .unknown }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollReady = poll(&pfd, 1, timeoutMs) > 0
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let readable = pollReady && getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0
        return classifyPendingConnect(pollReady: pollReady, soError: readable ? soError : nil)
    }

    /// 非同期 connect(EINPROGRESS)の結末の3値化(純粋関数。時間切れを実ソケットで作れないので切り出す)。
    /// poll が時間切れ・SO_ERROR が読めない・ECONNREFUSED 以外のエラーは **`.unknown`**
    static func classifyPendingConnect(pollReady: Bool, soError: Int32?) -> ConnectProbe {
        guard pollReady, let soError else { return .unknown }
        if soError == 0 { return .connected }
        return soError == ECONNREFUSED ? .refused : .unknown
    }

    /// `probeStatus` の失敗の仕方。**HTTP のステータスコードは問わない** —— 実機ブリッジは token
    /// 不一致で 401 を返すことがあり、これも「ブリッジは生きている」証拠(200 限定にすると
    /// 健全な実機を死と誤判定する)
    public enum StatusProbe: Equatable, Sendable {
        /// HTTP 応答が返った(ステータスコードは問わない)
        case answered
        /// タイムアウト上限まで無応答 = 本当に busy
        case timedOut
        /// TCP connect は通ったが、上限よりはるかに早く応答無しで転送が切れた。
        /// loopback(シミュレータ)側は listener の実体を確かめ、iproxy トンネルでなければ
        /// `.timedOut` へ読み替える(下記 `resolveTransportFailure`。忙しい XCUITest ランナーの
        /// listen backlog が溢れて connect 直後に切れる形が、固まった実機の iproxy と同じ指紋になる)。
        /// ここへ残るのは**実機の固まった iproxy か、listener を確認できなかった場合だけ** ——
        /// 「ブリッジは消えている」と断定しない
        case transportFailed
        /// 誰も listen していない
        case notBound
    }

    /// `timedOut` と `transportFailed` を分ける境界(タイムアウト上限に対する割合)。
    /// 実測(2026-09-22, 実機 iPhone SE3・固まった iproxy 越し): 転送だけが残った切断は
    /// connect 後 ~2.5ms で終わる・本当に busy な XCUITest は上限まで応答を保持する。
    /// 上限の半分を境にしても両実測に大きな余裕がある
    static let transportFailureFraction = 0.5

    /// 1ポートの `/status` を撃ち、**失敗の仕方まで**返す(isBound/scan は「応答したか」しか
    /// 見ない)。ホットパスの isBound/scan のシグネチャ・挙動は変えない。
    /// **時間の計測は壁時計を使わない**(`ContinuousClock`)
    public static func probeStatus(
        port: UInt16, repoRoot: URL?, timeoutSeconds: Double = 2
    ) async -> StatusProbe {
        guard isBound(port: port, repoRoot: repoRoot) else { return .notBound }
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await BridgeClient(endpoint: endpoint, timeoutSeconds: timeoutSeconds)
                .status(timeout: timeoutSeconds)
            return .answered
        } catch {
            switch error {
            case DriverError.bridgeUnreachable, DriverError.bridgeConnectionRefused:
                let classification = classifyNoResponse(
                    elapsedMs: continuousClockMs(clock.now - start), timeoutSeconds: timeoutSeconds)
                // 実測(2026-09-24 負荷テスト): 忙しい XCUITest(同 pid のまま quiescence 待ちで
                // 数十秒ブロック)の listen backlog が溢れると、他クライアントの connect は
                // connect 直後に切れ、固まった実機の iproxy と同じ指紋になる。loopback だけ
                // listener の実体を確かめてから再分類する(LAN 経由の実機はここに来ない)
                guard classification == .transportFailed, endpoint.isLoopback else { return classification }
                let facts = await loopbackListenerFacts(port: port)
                return resolveTransportFailure(
                    classification: classification, isLoopback: endpoint.isLoopback,
                    listenerExists: facts.exists, listenerIsTunnelOnly: facts.isTunnelOnly)
            default:
                // badResponse(401 の token 不一致等)・decode 失敗はどちらも HTTP 応答を
                // 受け取れた証拠 —— ステータスコードを問わず「生きている」側へ倒す
                return .answered
            }
        }
    }

    /// 所要時間から busy / 消失を分ける(純粋関数・テスト用)。実ソケットを使わずに境界の
    /// 両側を表明できるよう、経過時間を入力に取る形で切り出してある
    static func classifyNoResponse(elapsedMs: Int, timeoutSeconds: Double) -> StatusProbe {
        Double(elapsedMs) < timeoutSeconds * 1000 * transportFailureFraction
            ? .transportFailed : .timedOut
    }

    /// `.transportFailed` の再分類(純粋関数・テスト用)。**肯定的に「トンネルではない listener が
    /// 居る」と読めたときだけ** `.timedOut`(= 忙しいだけ)へ倒す ——
    /// listener を確認できない・iproxy トンネルだった・loopback でない、はすべて元の分類のまま
    /// (「わからないから消えたことにする」に倒すと、本当に固まった実機を busy と誤帰属する)
    static func resolveTransportFailure(
        classification: StatusProbe, isLoopback: Bool, listenerExists: Bool, listenerIsTunnelOnly: Bool
    ) -> StatusProbe {
        guard classification == .transportFailed, isLoopback, listenerExists, !listenerIsTunnelOnly else {
            return classification
        }
        return .timedOut
    }

    /// `PortHolder.listenerFacts` は lsof/ps を撃つので、協調スレッドプールで直接 await せず
    /// GCD へ逃がす(`ProvisionLock.acquire` と同じ形)。`.transportFailed` の再分類専用の経路なので、
    /// 速い経路(answered/timedOut/notBound)には触れない
    private static func loopbackListenerFacts(port: UInt16) async -> (exists: Bool, isTunnelOnly: Bool) {
        await withCheckedContinuation { (cont: CheckedContinuation<(exists: Bool, isTunnelOnly: Bool), Never>) in
            DispatchQueue.global().async {
                cont.resume(returning: PortHolder.listenerFacts(port: port))
            }
        }
    }

    /// 複数ポートの `probeStatus` を**並列に**撃つ(1ポートずつ直列に撃つと、上限 2 秒 × ポート数を
    /// 払う)。呼び手(`bridge down` の門)は純粋関数へ結果だけを渡したいので、ここで表にして返す
    public static func probeStatuses(
        ports: [UInt16], repoRoot: URL?, timeoutSeconds: Double = 2
    ) async -> [UInt16: StatusProbe] {
        await withTaskGroup(of: (UInt16, StatusProbe).self) { group in
            for port in ports {
                group.addTask {
                    (port, await probeStatus(port: port, repoRoot: repoRoot,
                                             timeoutSeconds: timeoutSeconds))
                }
            }
            var result: [UInt16: StatusProbe] = [:]
            for await (port, probe) in group { result[port] = probe }
            return result
        }
    }

    /// 範囲を並列に走査して応答した全ポートを返す
    public static func scan(excluding preferred: UInt16, repoRoot: URL?) async -> [Found] {
        await withTaskGroup(of: Found?.self) { group in
            for port in portRange where port != preferred {
                group.addTask {
                    let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
                        ?? BridgeEndpoint(port: port)
                    guard let status = try? await BridgeClient(
                        endpoint: endpoint, timeoutSeconds: 2).status(timeout: 2),
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

    /// 本人確認(`FTCore.BridgeIdentityCheck`)に渡す前の status。**申告が無いときだけ**記録で udid を
    /// 補う(規則は `resolveUDID`)。補わずに渡すと、実機の XCUITest ランナー(udid を申告しない)は
    /// 「udid 不明・エンジン一致 = 一致」に倒れ、**既定ポートに居る別の実機のブリッジを自分のものとして
    /// 掴む**(実地 2026-09-24: iPhone wave のライブ操作に 8123 の iPhone SE3 の画面が出た)
    public static func statusForIdentityCheck(_ status: StatusResponse, port: UInt16, repoRoot: URL?) -> StatusResponse {
        guard status.udid == nil,
              let recorded = repoRoot.flatMap({ BridgeDeviceRecord.load(port: port, repoRoot: $0) }) else {
            return status
        }
        var filled = status
        filled.udid = resolveUDID(reported: nil, recorded: recorded)
        return filled
    }

    // MARK: - 文言(1箇所に置く。呼び出し側は throw / ログに載せるだけ)

    public static func adoptedNote(preferred: UInt16, found: Found) -> String {
        "no bridge is listening on the default port \(preferred) — using the only running one:"
            + " \(found.label). Pass port: or profile: to pin it."
    }

    /// 走査したポート範囲の名乗り。**描くのはここ1箇所**(同じ事実を2箇所の文字列で描いていて、
    /// 片方が `upperBound - 1` で1本狭く名乗っていた。portRange は ClosedRange = 上端も走査対象)。
    /// 呼び手: このファイルの noBridgeMessage / fleetest の BridgeStatusReport.render
    public static var scannedPortsDescription: String {
        "\(portRange.lowerBound)-\(portRange.upperBound)"
    }

    public static func noBridgeMessage(preferred: UInt16) -> String {
        "no iOS bridge is running (scanned ports \(scannedPortsDescription))."
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

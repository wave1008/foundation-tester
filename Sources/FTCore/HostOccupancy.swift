// HostOccupancy.swift
// 「今このランナー機で誰かのディスパッチが走っているか」を、**その機械の上のローカルなファイル
// 読みだけで**判定する(docs/remote-runner.md §18.2 の M2「占有表示・配信の自動退避」)。
//
// dispatch.lock はホストに1本(RemoteDispatchLock)で、その info.json はランナーのディスクにある。
// ランナーで動いている子プロセス(fan-out の `api monitor` / `api device-stream`)は **ssh を
// 1本も足さずに**読めるので、手元から監視間隔ごとに覗きに行く形にはしない(ssh の churn を
// 作らない = docs/remote-runner.md §13 の規律)。
//
// **保持者が誰かは表示専用**(RemoteDispatchLockInfo と同じ規律 —— pid も issuer も自己申告)。
// 配信の退避は**保持者が誰かによらず**効かせる: 配信とテストの干渉は他人の run でも自分の run
// でも同じように起きる(docs/verification.md「8台に配信を張った状態のフル E2E は Android が
// 実際に赤になった」)。`mine` は文言と破壊的操作の確認にだけ使う。
//
// **この判定は「出れば占有」であって「出なければ空き」ではない**: dispatch.lock を取らない
// 経路(ランナー機で人が直に打った `fleetest run`)は写らない。

import Foundation

/// ランナー機の占有状態(dispatch.lock 1本の要約)。NDJSON へそのまま載せるので Codable。
public struct HostOccupancy: Equatable, Sendable, Codable {
    public let held: Bool
    /// 保持者の自己申告 issuerId。旧 info.json(issuer キーが無い)や読めなかったときは nil
    public let issuer: String?
    /// 発行元マシンのホスト名(表示専用)
    public let issuerHost: String?
    /// 取得時刻(UTC, ISO8601 文字列のまま運ぶ = 解釈は表示側)
    public let acquiredAt: String?
    /// 保持者がこの発行者か。**false は「他人」と「不明」の両方**(断定できないときは他人側に
    /// 倒す —— 他人の run を自分のものと誤認すると、破壊的操作の確認が警告を出さなくなる)
    public let mine: Bool

    public init(held: Bool, issuer: String? = nil, issuerHost: String? = nil,
                acquiredAt: String? = nil, mine: Bool = false) {
        self.held = held
        self.issuer = issuer
        self.issuerHost = issuerHost
        self.acquiredAt = acquiredAt
        self.mine = mine
    }

    public static let free = HostOccupancy(held: false)

    /// ロックの中身から占有状態を組む(純粋)。`lockDirExists` はロックディレクトリの有無、
    /// `infoJSON` はその中の info.json(読めなければ nil)。**info が読めなくても held は保つ**
    /// (「情報が読めなくてもロック自体は尊重する」= RemoteDispatchLock の既存規則と同じ向き)
    public static func interpret(lockDirExists: Bool, infoJSON: String?, myIssuer: String) -> HostOccupancy {
        guard lockDirExists else { return .free }
        guard let infoJSON, let info = RemoteDispatchLock.decode(infoJSON) else {
            return HostOccupancy(held: true)
        }
        return HostOccupancy(held: true, issuer: info.issuer, issuerHost: info.issuerHost,
                             acquiredAt: info.acquiredAt,
                             mine: info.issuer.map { $0 == myIssuer } ?? false)
    }

    /// ランナー機のディスクから読む(I/O はここだけ。判定は interpret)。
    /// base が nil(= 手元で走っている。FT_RUNNER_BASE 未設定)なら nil を返し、
    /// 呼び出し側は「占有の概念が無い」として何も出さない
    public static func read(base: String?, myIssuer: String,
                            fileManager: FileManager = .default) -> HostOccupancy? {
        guard let base else { return nil }
        let dir = RemoteDispatchLock.lockDirPath(base: base)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: dir, isDirectory: &isDirectory) && isDirectory.boolValue
        let json = exists ? try? String(contentsOfFile: RemoteDispatchLock.infoFilePath(base: base),
                                        encoding: .utf8) : nil
        return interpret(lockDirExists: exists, infoJSON: json, myIssuer: myIssuer)
    }
}

/// **他人(あるいは自分)の run を巻き添えにする操作の前に、占有を見る**(docs/remote-runner.md
/// §18.1 #6)。`remote clean` の `devices down` はブリッジ停止 + シャットダウンなので、
/// 走っているディスパッチがあれば必ずその run を殺す。
///
/// **判定は保持者が誰かによらない** —— 自分の run でも殺されることに変わりはない。
/// 誰が保持しているかは文言にだけ出す(RemoteDispatchLock.holderSummary)。
public enum RemoteDestructiveGuard {
    public enum Decision: Equatable, Sendable {
        case proceed
        /// 中止(理由 = 保持者の説明 + どうすればよいか)
        case refuse(String)
        /// 明示フラグで押し切った(警告を1行出してから続行する)
        case proceedWithWarning(String)
    }

    /// - Parameter probe: nil = ロックを読めなかった(ssh 失敗など)。**読めないときは通す** ——
    ///   掃除そのものが永久にできなくなるほうが害が大きく、ロック照会は助言だから
    ///   (RemoteDispatchLock の「読めなくてもロックは尊重する」は取得側の規律で、こちらは別)
    public static func decide(probe: RemoteDispatchLock.Probe?, ignoreLock: Bool) -> Decision {
        guard let probe else { return .proceed }
        switch probe {
        case .absent:
            return .proceed
        case .held(let info):
            let holder = RemoteDispatchLock.holderSummary(info)
            if ignoreLock {
                return .proceedWithWarning(
                    "--ignore-lock: a dispatch is running on this host (\(holder))"
                        + " — stopping its bridges and simulators will kill it")
            }
            return .refuse(
                "a dispatch is running on this host (\(holder)) — stopping its bridges and simulators"
                    + " would kill that run. Wait for it to finish, or pass --ignore-lock if you know"
                    + " it is stale (docs/remote-runner.md §18.1)")
        }
    }
}

/// リモートで走る子プロセスへ、発行側が渡すランナー機の base ディレクトリ。
/// **手元実行では未設定**なので、この値の有無がそのまま「ランナー機の文脈か」の判定になる。
/// 発行側の export は RemoteShell.remoteRunCommand / remoteExecCommand の1箇所。
public enum RunnerBase {
    public static let environmentKey = "FT_RUNNER_BASE"

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let value = environment[environmentKey], !value.isEmpty else { return nil }
        return value
    }
}

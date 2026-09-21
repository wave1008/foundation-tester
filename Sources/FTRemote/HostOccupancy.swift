// HostOccupancy.swift
// 「今この機械で誰かの run が走っているか」を、**その機械の上のローカルなファイル読みだけで**
// 判定する(docs/remote-runner.md §18.7 の M2「占有表示・配信の自動退避」)。
//
// dispatch.lock は機械に1本(RemoteDispatchLock。`~/.fleetest/`)で、**リモートへのディスパッチも
// ローカル run も同じ1本を取る**(CLAUDE.md「1マシンで同時に走る run は1本」)。
// だから**手元も観測の対象**で、「ランナー機の文脈か」(FT_RUNNER_BASE)は占有を配るかどうかの
// 条件にしない —— 手元の run も占有である。
// その機械で動いているプロセス(手元の `api monitor` / fan-out の子)は **ssh を1本も足さずに**
// 読めるので、手元から監視間隔ごとに覗きに行く形にはしない(ssh の churn を作らない =
// docs/remote-runner.md §13 の規律)。
//
// **保持者が誰かは表示専用**(RemoteDispatchLockInfo と同じ規律 —— pid も issuer も自己申告)。
// 配信の退避は**保持者が誰かによらず**効かせる: 配信とテストの干渉は他人の run でも自分の run
// でも同じように起きる(docs/verification.md「8台に配信を張った状態のフル E2E は Android が
// 実際に赤になった」)。`mine` は文言と破壊的操作の確認にだけ使う。
//
// **この判定は「出れば占有」であって「出なければ空き」ではない**: dispatch.lock を取らない
// 経路(`--force-lock` で押し切った run・MCP の `ft_*`)は写らない。

import Foundation
import FTCore

/// 機械の占有状態(その機械の dispatch.lock 1本の要約)。NDJSON へそのまま載せるので Codable。
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

    /// この機械のディスクから読む(I/O はここだけ。判定は interpret)。**読むのは自分の `$HOME`**
    /// —— ロックは機械グローバルな `~/.fleetest` に1本(`RemoteDispatchLock.lockDirPath`)で、
    /// 手元でもランナー機でも同じ1本。**「ランナー機の文脈か」(`RunnerBase`)は条件にしない**
    /// = 手元の run も占有なので、ここで黙ると錠前も配信の退避も手元にだけ効かなくなる。
    /// `home` / `fileManager` はテスト用の差し替え口
    public static func read(myIssuer: String,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            fileManager: FileManager = .default) -> HostOccupancy {
        let dir = RemoteDispatchLock.lockDirPath(home: home.path)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: dir, isDirectory: &isDirectory) && isDirectory.boolValue
        let json = exists ? try? String(contentsOfFile: RemoteDispatchLock.infoFilePath(home: home.path),
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
///
/// **役割は1つだけになった**: 配信の控え(`FTCore.StreamLease`)の置き場。
/// dispatch.lock / dispatch.queue は機械グローバルな `~/.fleetest` にあるので**この値から場所を
/// 導く読み手は居ない**し、**占有(`HostOccupancy`)を配るかどうかの判定にも使わない** ——
/// ロックが機械に1本で手元の run も同じ1本を取る以上、「ランナー機の文脈か」は占有の有無と
/// 無関係(手元で黙ると錠前と配信の退避が手元にだけ効かない)。
public enum RunnerBase {
    public static let environmentKey = "FT_RUNNER_BASE"

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let value = environment[environmentKey], !value.isEmpty else { return nil }
        return value
    }
}

// RemoteDispatchWait.swift
// dispatch.lock の待機列(RemoteDispatchQueue)を **呼ぶ側** が使う純粋ロジック:
// ①このディスパッチのチケットを決める ②待っている間の状態を1つの値型にまとめる。
// ssh 実行・sleep はここに置かない(呼び出し側 = Sources/fleetest/RemoteRunDispatcher.swift)。

import Foundation

extension RemoteDispatchQueue {

    /// このディスパッチが並ぶチケットを決める。
    ///
    /// **環境変数 `FT_DISPATCH_TICKET` にチケットがあれば、そのまま使う** —— 親プロセスが1回だけ
    /// 採った時刻を全機械へ運ぶため。**機械ごとに採り直すと同じ run の前後関係が機械によって
    /// 食い違う**(フリート分担の run が機械 A では先・機械 B では後になる)。
    /// 壊れていて parse できなければ自分で採る(失うのは順番だけなので、黙って落とさない)
    public static func resolveTicket(environment: [String: String], issuer: String,
                                     runGroup: String?, pid: Int32, now: Date) -> DispatchTicket {
        if let inherited = DispatchTicket.fromEnvironment(environment) { return inherited }
        // runGroup が無い単発の run は pid で区別する(同じ発行者の同時 run を別チケットにする鍵)
        return DispatchTicket.now(issuer: issuer, group: runGroup ?? String(pid), date: now)
    }
}

/// dispatch.lock の待機列に並んでいる間の状態。**進行ログも `fleetest api run` の NDJSON イベントも
/// この1つの値から組み立てる** —— 組み立てを2箇所に散らすと、拡張に出る数字と端末に出る数字が
/// 食い違う(「共有するのは判定であって文言ではない」の裏返しで、こちらは同じ**事実**を配る)
public struct DispatchWaitStatus: Equatable, Sendable {
    /// 待っている相手。呼び出し側は既存のログと同じ ssh 宛先(`RemoteHostSpec.sshTarget`)を入れる
    public let target: String
    /// 待機列での自分の位置(1始まり)
    public let position: Int
    /// 生きているチケットの総数(自分を含む)
    public let total: Int
    /// いまロックを掴んでいる人。**nil は「読めなかった」であって「空き」でも「占有」でもない**
    /// —— 自分の前に並んでいる人が居るだけでロックは空いている、という形でも nil になるので、
    /// **nil のときに「誰かの run が走っている」と言ってはいけない**
    /// (docs/remote-runner.md §18.7「不明と空きを混ぜない」の同型)
    public let holder: RemoteDispatchLockInfo?
    /// 待ち始めてからの経過(秒)。待たない(`--wait-lock` 無し)なら 0
    public let elapsedSeconds: Int
    /// `--wait-lock <秒>`。フラグが無ければ nil
    public let limitSeconds: Int?
    /// 文言だけを分ける(既定はリモート = 従来の出力と1バイトも変わらない)。
    /// 判定・数え方・刻みは scope で変えない
    public let scope: DispatchLockScope

    public init(target: String, position: Int, total: Int, holder: RemoteDispatchLockInfo?,
                elapsedSeconds: Int, limitSeconds: Int?,
                scope: DispatchLockScope = .remoteHost) {
        self.target = target
        self.position = position
        self.total = total
        self.holder = holder
        self.elapsedSeconds = elapsedSeconds
        self.limitSeconds = limitSeconds
        self.scope = scope
    }

    /// 自分より前に並んでいる人数
    public var aheadCount: Int { max(0, position - 1) }

    /// 待ち始めた1行(初回だけ)
    public var queuedLine: String {
        var line = "==> queued for the dispatch lock on \(target) — position \(position) of \(total)"
        if let holder { line += ", held by \(RemoteDispatchLock.holderSummary(holder))" }
        if let limitSeconds { line += " — waiting up to \(limitSeconds)s" }
        return line
    }

    /// 経過ログ(`WaitLockPolling.progressIntervalSeconds` ごと)
    public var stillQueuedLine: String {
        var progress = "position \(position) of \(total), \(elapsedSeconds)s"
        if let limitSeconds { progress += " of \(limitSeconds)s" }
        return "==> still queued on \(target) (\(progress))"
    }

    /// 取れずに諦めたときの1行(呼び手はこれをそのまま throw する)。
    /// **「誰かの run が走っている」と言ってよいのは保持者を読めたときだけ** —— 読めずに
    /// 自分の前へ並んでいる人が居るだけなら、走っているとは限らない(その人もまだ待っている)
    public var refusalMessage: String {
        guard holder == nil, aheadCount > 0 else {
            return RemoteDispatchLock.heldMessage(holder, scope: scope) + refusalSuffix
        }
        var line = "\(aheadCount) earlier request(s) are queued ahead of yours for the dispatch lock"
            + " on \(target) — wait for them to finish"
        if limitSeconds == nil { line += ", or pass --wait-lock <seconds> to wait your turn" }
        if elapsedSeconds > 0 { line += " (waited \(elapsedSeconds)s)" }
        return line
    }

    /// `RemoteDispatchLock.heldMessage` の後ろへ足す1句(**heldMessage 自体は変えない** ——
    /// 待機列は判定を足しただけで、ロックの文言は従来のまま)。
    /// 足すものが無ければ空文字 = 従来と1バイトも変わらない
    public var refusalSuffix: String {
        var parts: [String] = []
        if aheadCount > 0 { parts.append("\(aheadCount) ahead in the queue") }
        if elapsedSeconds > 0 { parts.append("waited \(elapsedSeconds)s") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }
}

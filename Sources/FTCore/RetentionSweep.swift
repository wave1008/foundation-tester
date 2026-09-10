// RetentionSweep.swift
// 保持容量の掃除計画(純粋関数。**I/O を持たない** —— セッションの採取と実削除は
// Sources/fleetest/RetentionSweeper.swift が担う)。
//
// 中核の不変条件は2つ:
//   ①`guarded`(生きている = ブリッジが動いている / 進行中の run)は**絶対に delete に入らない**
//   ②guarded のバイト数も**累計に加える** —— 消せないものが容量を占めている事実を隠すと、
//     上限を守れていない理由が呼び出し側から見えなくなる(`overCapAfterGuards` が唯一の合図)

import Foundation

public enum RetentionSweep {

    /// 掃除の最小単位。1セッション = まとめて消すか、まとめて残すかのどちらかになる塊
    /// (run 1件の recordings / ログ1本 / 1デバイスの添付の一区間)
    public struct Session: Equatable, Sendable {
        /// 診断表示用(runID / ポート / 日付など)。**同着の並びを決める鍵でもある**ので
        /// 実行ごとに変わらない値にすること
        public let id: String
        public let bytes: Int64
        /// 新しい順に積む鍵(配下の最新 mtime)
        public let newestModified: Date
        /// 実際に消すもの。**ディレクトリを消してよいのは呼び手が「丸ごと消える」と
        /// 分かっている場合だけ**(添付はディレクトリを残して直下のファイルだけを入れる)
        public let paths: [URL]
        /// 生きている = 絶対に消さない
        public let guarded: Bool

        public init(id: String, bytes: Int64, newestModified: Date, paths: [URL], guarded: Bool) {
            self.id = id
            self.bytes = bytes
            self.newestModified = newestModified
            self.paths = paths
            self.guarded = guarded
        }
    }

    public struct Plan: Equatable, Sendable {
        public let delete: [Session]
        /// 掃除後に残るバイト数(全セッションの合計 − freedBytes)
        public let keptBytes: Int64
        public let freedBytes: Int64
        /// guarded だけで上限を超えている。**呼び出し側が警告を出すための欄**
        /// (掃除しても上限に収まらないので、放置すると容量が増え続ける)
        public let overCapAfterGuards: Bool

        public init(delete: [Session], keptBytes: Int64, freedBytes: Int64,
                    overCapAfterGuards: Bool) {
            self.delete = delete
            self.keptBytes = keptBytes
            self.freedBytes = freedBytes
            self.overCapAfterGuards = overCapAfterGuards
        }
    }

    /// 新しい順に積み、上限を超えた時点から後ろを delete にする。
    ///
    /// - 上限**ちょうど**は残す(超えたセッション自身から消える)
    /// - `maxBytes <= 0` は「保持しない」= guarded 以外すべて delete
    /// - guarded だけで上限を超えるときも**消せるものは全部消す**(`overCapAfterGuards` を立てて
    ///   呼び手に警告させる)。**「上限に届かないから1バイトも消さない」にしてはいけない** ——
    ///   進行中の run が上限より大きい添付を抱えているだけで、無関係な数百 GB が残り続ける
    /// - 同着(`newestModified` が同値)は `id` 昇順。run ごとに結果が変わらないため
    public static func plan(sessions: [Session], maxBytes: Int64) -> Plan {
        let sorted = sessions.sorted {
            if $0.newestModified != $1.newestModified { return $0.newestModified > $1.newestModified }
            return $0.id < $1.id
        }
        let total = sorted.reduce(Int64(0)) { $0 + $1.bytes }
        let guardedTotal = sorted.reduce(Int64(0)) { $0 + ($1.guarded ? $1.bytes : 0) }
        let overCap = guardedTotal > maxBytes

        if maxBytes <= 0 || overCap {
            let delete = sorted.filter { !$0.guarded }
            let freed = delete.reduce(Int64(0)) { $0 + $1.bytes }
            return Plan(delete: delete, keptBytes: total - freed, freedBytes: freed,
                        overCapAfterGuards: overCap)
        }

        var running: Int64 = 0
        var overflowed = false
        var delete: [Session] = []
        for session in sorted {
            running += session.bytes
            // 累計は単調増加なので、一度超えたら以降はすべて上限の外
            if running > maxBytes { overflowed = true }
            guard overflowed, !session.guarded else { continue }
            delete.append(session)
        }
        let freed = delete.reduce(Int64(0)) { $0 + $1.bytes }
        return Plan(delete: delete, keptBytes: total - freed, freedBytes: freed,
                    overCapAfterGuards: false)
    }
}

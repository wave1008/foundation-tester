// FM(Foundation Models)呼び出しの機械グローバルな控え。
//
// FM は CPU/GPU と同じ「ホストの性質」(呼び出しは FMGate/FMLock がホスト全体で直列化する)だが、
// OS に「このホストで今 FM を何回呼んでいるか」を訊く API は無い。host-metrics 自身が FM を
// 叩いて測ると測定対象を自分で消費してしまうため、FM を実際に呼んでいる各プロセス
// (FMHealth.record 経由)がここへ書き、host-metrics が毎 tick 読む形にする。NDJSON の
// fmCalls/fmFailures/fmTotalMs は vscode-fleetest/src/monitorProcessManager.ts の
// HostMetricsRawEvent と対。
//
// 中身の実装(pid ごとの JSON・アトミック rename・基準取り・pid 再利用の扱い・死んだ pid の
// reap・複数読み手の規律)は UsageLedger.swift に共通化してある(OCRUsageLedger と共有。
// コピーしない)。ここは FM 専用の薄いファサード。
//
// 置き場は ~/.fleetest/fm-usage/(FT_FM_USAGE_DIR で差し替え。テスト用)。

import Foundation

public enum FMUsageLedger {
    public typealias Counters = UsageLedger.Counters
    public typealias Delta = UsageLedger.Delta

    private static let ledger = UsageLedger(subdirectory: "fm-usage", directoryOverrideKey: "FT_FM_USAGE_DIR")

    /// 書き込み先。nil = 書かない(UsageLedger.writeDirectory 参照)。
    /// **`private` を外してあるのはテストのため**
    static var writeDirectory: URL? { ledger.writeDirectory }

    /// FM 呼び出し1件を記録する。**必ず FMHealth の NSLock の外側から呼ぶこと**
    /// (ここでファイル I/O をするため、呼び出し側のロック内で呼ぶと I/O をロック内に持ち込む)。
    /// 書き込み失敗は握りつぶす —— FM の実行そのものを絶対に止めない
    public static func record(ok: Bool, ms: Double) {
        ledger.record(ok: ok, ms: ms)
    }

    /// 直近スナップショットからの増分を返す。呼び出し側(host-metrics のサンプリングループ)が
    /// ローカル変数として `previous` を持ち回すこと。挙動の詳細(基準取り・死んだ pid の計上・
    /// pid 再利用の扱い)は UsageLedger.drain 参照
    public static func drain(previous: inout [Int32: Counters]?) -> Delta? {
        ledger.drain(previous: &previous)
    }

    /// テスト用(UsageLedger.reapDead 参照)
    static func reapDead(in dir: URL) {
        ledger.reapDead(in: dir)
    }

    /// テスト用(UsageLedger.reapStaleOwnEntry 参照)
    static func reapStaleOwnEntry(in dir: URL, pid: Int32) {
        ledger.reapStaleOwnEntry(in: dir, pid: pid)
    }

    /// テスト専用。インスタンスの状態(累計・書き込み済み累計・掃除の門)を初期値へ戻す
    static func resetForTesting() {
        ledger.resetForTesting()
    }
}

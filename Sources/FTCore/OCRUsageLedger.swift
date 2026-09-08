// OCR(Vision の文字認識。RegionText が occlusion-guard Tier-2 で使う)呼び出しの機械グローバルな控え。
//
// FMUsageLedger と同じ理由・同じ形: host-metrics 自身が Vision を叩いて測ると測定対象を自分で
// 消費してしまうため、実際に OCR を呼んでいる各プロセス(RegionText.read 経由)がここへ書き、
// host-metrics が毎 tick 読む。NDJSON の ocrCalls/ocrFailures/ocrTotalMs は
// vscode-fleetest/src/monitorProcessManager.ts の HostMetricsRawEvent と対。
//
// 中身の実装は UsageLedger.swift に共通化してある(FMUsageLedger と共有。コピーしない)。
// **暖機(RegionText.prewarmOnce)は記録しない** —— ガードの実仕事ではなく初回ロードは
// 25〜47 秒かかるので、数えると実測が化ける。
//
// 置き場は ~/.fleetest/ocr-usage/(FT_OCR_USAGE_DIR で差し替え。テスト用)。

import Foundation

public enum OCRUsageLedger {
    public typealias Counters = UsageLedger.Counters
    public typealias Delta = UsageLedger.Delta

    private static let ledger = UsageLedger(subdirectory: "ocr-usage", directoryOverrideKey: "FT_OCR_USAGE_DIR")

    /// 書き込み先。nil = 書かない(UsageLedger.writeDirectory 参照)。
    /// **`private` を外してあるのはテストのため**
    static var writeDirectory: URL? { ledger.writeDirectory }

    /// OCR(`recognize`)呼び出し1件を記録する。**必ず呼び出し側の他のロックの外側から呼ぶこと**
    /// (ここでファイル I/O をするため)。書き込み失敗は握りつぶす —— OCR の実行そのものを
    /// 絶対に止めない
    public static func record(ok: Bool, ms: Double) {
        ledger.record(ok: ok, ms: ms)
    }

    /// 直近スナップショットからの増分を返す。呼び出し側(host-metrics のサンプリングループ)が
    /// ローカル変数として `previous` を持ち回すこと。挙動の詳細は UsageLedger.drain 参照
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

// FM(Foundation Models)呼び出しの機械グローバルな控え。
//
// FM 呼び出しはホスト全体で直列化する(実測: 並列度によらず約1回/秒で頭打ち。FMHealth.swift 参照)
// ので、本来 CPU/GPU と同じ「ホストの性質」だが、OS に「このホストで今 FM を何回呼んでいるか」を
// 訊く API は無い。host-metrics 自身が FM を叩いて測ると測定対象を自分で消費してしまうため、
// FM を実際に呼んでいる各プロセス(FMHealth.record 経由)がここへ書き、host-metrics が毎 tick
// 読む形にする。NDJSON の fmCalls/fmFailures/fmTotalMs は
// vscode-fleetest/src/monitorProcessManager.ts の HostMetricsRawEvent と対。
//
// 置き場は ~/.fleetest/fm-usage/(FT_FM_USAGE_DIR で差し替え。テスト用)。
// **プロジェクトに依存させない** —— api host-metrics に --project が無いのは意図的
// (Sources/fleetest/ApiHostMetricsCommand.swift 冒頭コメント)。ここもその性質を壊さないよう
// 機械グローバルな場所に置く(~/.fleetest は ftbridge.apk 等が既に居る既存の機械グローバル置き場)。

import Foundation

public enum FMUsageLedger {
    /// pid 1件ぶんの、そのプロセスが生きている間の単調増加累計
    public struct Counters: Equatable {
        public var calls: Int
        public var failures: Int
        public var totalMs: Int

        public init(calls: Int, failures: Int, totalMs: Int) {
            self.calls = calls
            self.failures = failures
            self.totalMs = totalMs
        }
    }

    /// 直近の drain からの増分(ホスト全プロセス合計)
    public struct Delta {
        public let calls: Int
        public let failures: Int
        public let totalMs: Int

        public init(calls: Int, failures: Int, totalMs: Int) {
            self.calls = calls
            self.failures = failures
            self.totalMs = totalMs
        }
    }

    private struct FileEntry: Codable {
        let pid: Int32
        let calls: Int
        let failures: Int
        let totalMs: Int
        let updatedAt: Double
    }

    private static let lock = NSLock()
    private static var calls = 0
    private static var failures = 0
    private static var totalMs = 0
    private static let writeLock = NSLock()
    private static var lastWrittenCalls = 0
    private static let reapLock = NSLock()
    private static var reaped = false

    private static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["FT_FM_USAGE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest", isDirectory: true)
            .appendingPathComponent("fm-usage", isDirectory: true)
    }

    /// 書き込み先。nil = 書かない。
    /// **XCTest のプロセスからは書かない** —— FMHealth.record は単体テストが合成値で直接叩くので、
    /// FM を1回も呼んでいないのに監視の FM 行が動く(偽の実測がユーザーに見える)。
    /// 控え自体を検証するテストは FT_FM_USAGE_DIR を明示するので影響を受けない
    private static var writeDirectory: URL? {
        if let override = ProcessInfo.processInfo.environment["FT_FM_USAGE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return directory
    }

    /// FM 呼び出し1件を記録する。**必ず FMHealth の NSLock の外側から呼ぶこと**
    /// (ここでファイル I/O をするため、呼び出し側のロック内で呼ぶと I/O をロック内に持ち込む)。
    /// 書き込み失敗は握りつぶす —— FM の実行そのものを絶対に止めない
    public static func record(ok: Bool, ms: Double) {
        reapOnce()
        lock.lock()
        calls += 1
        if !ok { failures += 1 }
        totalMs += Int(ms.rounded())
        let entry = FileEntry(
            pid: ProcessInfo.processInfo.processIdentifier,
            calls: calls, failures: failures, totalMs: totalMs,
            updatedAt: Date().timeIntervalSince1970)
        lock.unlock()
        write(entry)
    }

    /// 一時ファイルに書いてから同一ディレクトリ内で rename する(rename(2) は同一ファイル
    /// システム内でアトミック。読み手に途中まで書かれた JSON を見せない)
    private static func write(_ entry: FileEntry) {
        guard let dir = writeDirectory else { return }
        // 書き込みは直列化し、**古い累計で新しい累計を上書きしない**。counters のロックを抜けてから
        // 書くので、並行呼び出しでは後発の entry が先に着地しうる。上書きすると読み手の差分が
        // 1回ぶん落ちる —— 差分は負にしない(max(0,…))ので、その1回は永久に取り戻せない
        writeLock.lock()
        defer { writeLock.unlock() }
        guard entry.calls > lastWrittenCalls else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let target = dir.appendingPathComponent("\(entry.pid).json")
        let tmp = dir.appendingPathComponent(".\(entry.pid).\(UUID().uuidString).tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        guard rename(tmp.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        lastWrittenCalls = entry.calls
    }

    /// 直近スナップショットからの増分を返す。呼び出し側(host-metrics のサンプリングループ)が
    /// ローカル変数として `previous` を持ち回すこと。
    ///
    /// - ディレクトリが読めない/存在しないときは nil(**不明**。呼び出しが0件だった `calls: 0` と
    ///   混ぜない)
    /// - **この関数はファイルを消さない**(読み手が複数居るため。掃除は reapOnce())
    /// - **`previous` が nil の回は基準取り(全ファイルを控えるだけで増分は 0)**。監視を始めた
    ///   時点で既に走っていたプロセスの累計を、丸ごとこの1 tick の増分として出さないため。
    ///   **2回目以降に現れた pid は全量が増分**(= その控えは監視を始めた後に作られたので、
    ///   その呼び出しは全部この窓の中で起きている)。ここを常に0にすると、シナリオごとに
    ///   立ち上がるランナープロセスの呼び出しが毎回1 tick ぶん落ちる(実測で 61 回中 12 回を落とした)
    /// - **死んだ pid のぶんも計上する**。ランナーはシナリオを終えるとすぐ死ぬので、
    ///   生きている pid だけを数えると**最後の呼び出しがまるごと消える**
    public static func drain(previous: inout [Int32: Counters]?) -> Delta? {
        let dir = directory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            // ディレクトリが**無い**のは「この機械でまだ一度も FM を呼んでいない」= 0件。
            // 不明(nil)にすると、FM を使っていない機械の行が永久に「–」になり壊れて見える。
            // 旧 CLI(控えを書かない版)は欄ごと出さないので、ここを0にしても偽の断定にはならない
            if !FileManager.default.fileExists(atPath: dir.path) {
                previous = [:]
                return Delta(calls: 0, failures: 0, totalMs: 0)
            }
            return nil
        }
        let baseline = previous == nil
        var current: [Int32: Counters] = [:]
        var deltaCalls = 0, deltaFailures = 0, deltaTotalMs = 0

        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(".json".count)), pid > 0 else { continue }
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(FileEntry.self, from: data) else { continue }

            let counters = Counters(calls: entry.calls, failures: entry.failures, totalMs: entry.totalMs)
            if !baseline {
                // 新出の pid は prior が無い = 全量が増分(控えは監視開始後に作られている)
                let prior = previous?[pid] ?? Counters(calls: 0, failures: 0, totalMs: 0)
                deltaCalls += max(0, counters.calls - prior.calls)
                deltaFailures += max(0, counters.failures - prior.failures)
                deltaTotalMs += max(0, counters.totalMs - prior.totalMs)
            }
            // **読みでは消さない**。読み手は複数居る(拡張の api host-metrics と、run 自身の
            // HostMetricsRecorder は既定で両方走る)ので、読んだ側が消すと**先に消したほうだけが
            // 数え、もう片方はそのプロセスのぶんを丸ごと落とす**。控えは残し続けてよい ——
            // 各読み手は自分の previous との差分しか見ないので、残っていても二重計上にならない。
            // 掃除は reapOnce()(書き手がプロセスにつき1回)
            current[pid] = counters
        }

        previous = current
        return Delta(calls: deltaCalls, failures: deltaFailures, totalMs: deltaTotalMs)
    }

    /// 死んだ pid の控えを消す。**プロセスにつき1回だけ**(書き手が最初の record で呼ぶ)。
    /// 読みから外してあるのは読み手が複数居るため(drain の doc 参照)。掃除する者が居なくても
    /// 集計は壊れない —— 残った控えは各読み手の基準に入って増分 0 になるだけ。
    /// pid 再利用で自分の番号の古い控えが残っていると、こちらの累計のほうが小さく見えて
    /// その増分が落ちるので、**自分が書き始める前に**掃除する
    private static func reapOnce() {
        reapLock.lock()
        defer { reapLock.unlock() }
        guard !reaped else { return }
        reaped = true
        reapDead(in: directory)
    }

    /// 一度きりの門(`reaped`)と分けてあるのはテストのため —— 門は プロセス全体の状態なので、
    /// 掃除そのものを直接呼べないと「掃除しない」変異を殺せるテストが書けない
    static func reapDead(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(".json".count)), pid > 0, !isAlive(pid) else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

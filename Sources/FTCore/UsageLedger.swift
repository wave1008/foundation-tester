// 「呼び出し回数の機械グローバルな控え」の共通実装。FM(FMUsageLedger)と OCR(OCRUsageLedger)は
// この上に乗る薄いファサードで、中身(pid ごとの JSON・アトミック rename・基準取り・pid 再利用の
// 扱い・死んだ pid の reap・複数読み手の規律)はここ1箇所に持つ(コピーしない。互いの状態は
// インスタンスごとに分離)。
//
// 呼び出し元プロセス(FM を叩く各シナリオランナー・OCR を叩く RegionText 等)がここへ書き、
// host-metrics 常駐プロセスが毎 tick 読む形にする。host-metrics 自身が対象を叩いて測ると
// 測定対象を自分で消費してしまうため、実仕事をしているプロセス自身が書く。
//
// 置き場は ~/.fleetest/<subdirectory>/(directoryOverrideKey の環境変数で差し替え。テスト用)。
// **プロジェクトに依存させない** —— api host-metrics に --project が無いのは意図的
// (Sources/fleetest/ApiHostMetricsCommand.swift 冒頭コメント)。ここもその性質を壊さないよう
// 機械グローバルな場所に置く(~/.fleetest は ftbridge.apk 等が既に居る既存の機械グローバル置き場)。

import Foundation

public final class UsageLedger {
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

    private let subdirectory: String
    private let directoryOverrideKey: String

    private let lock = NSLock()
    private var calls = 0
    private var failures = 0
    private var totalMs = 0
    private let writeLock = NSLock()
    private var lastWrittenCalls = 0
    private let reapLock = NSLock()
    private var reaped = false

    init(subdirectory: String, directoryOverrideKey: String) {
        self.subdirectory = subdirectory
        self.directoryOverrideKey = directoryOverrideKey
    }

    private var directory: URL {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
    }

    /// 書き込み先。nil = 書かない。
    /// **`LedgerWriteRole` が opt-in した production の実行ファイルだけへ書く**(fail-closed。
    /// LedgerWriteRole.swift 冒頭)。`XCTestConfigurationFilePath` の判定は二重の備えとして残す ——
    /// `swift test --parallel` のワーカーでは立たないことがあるのでこれ単独では守れない
    /// (合成値を直接叩く単体テストが本番の台帳へ偽の実測を書いていた事故がある。控え自体を
    /// 検証するテストは directoryOverrideKey の環境変数を明示するので影響を受けない)。
    /// **`private` を外してあるのはテストのため**
    var writeDirectory: URL? {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard LedgerWriteRole.permitsProductionWrite else { return nil }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return directory
    }

    /// 呼び出し1件を記録する。**必ず呼び出し側の他のロックの外側から呼ぶこと**
    /// (ここでファイル I/O をするため、呼び出し側のロック内で呼ぶと I/O をロック内に持ち込む)。
    /// 書き込み失敗は握りつぶす —— 呼び出し元の実行そのものを絶対に止めない
    func record(ok: Bool, ms: Double) {
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
    private func write(_ entry: FileEntry) {
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
    func drain(previous: inout [Int32: Counters]?) -> Delta? {
        let dir = directory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            // ディレクトリが**無い**のは「この機械でまだ一度もこの種の呼び出しをしていない」= 0件。
            // 不明(nil)にすると、使っていない機械の行が永久に「–」になり壊れて見える。
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
                // 新出の pid は prior が無い = 全量が増分(控えは監視開始後に作られている)。
                // **累計が減った pid は別のプロセス**(pid 再利用)。累計は1プロセスの中で単調増加
                // (write は lastWrittenCalls より大きいときしか着地させない)なので、減少は
                // 「古い控えの pid を新しいプロセスが引き継いだ」以外に起きない。prior のまま引くと
                // max(0,…) で新プロセスの最初の tick ぶんが丸ごと落ちる
                var prior = previous?[pid] ?? Counters(calls: 0, failures: 0, totalMs: 0)
                if counters.calls < prior.calls { prior = Counters(calls: 0, failures: 0, totalMs: 0) }
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
    /// その増分が落ちるので、**自分が書き始める前に**掃除する。**自分の pid の控えは生死を
    /// 見ずに消す**(reapDead は生きている pid を残す = 自分は生きているので、前任者が残した
    /// `<自分の pid>.json` はあちらでは決して消えない。自分の pid を書くのは自分だけなので、
    /// 最初の書き込みの前に在るものは前任者の残骸に限る)
    private func reapOnce() {
        reapLock.lock()
        defer { reapLock.unlock() }
        guard !reaped else { return }
        reaped = true
        let dir = directory
        reapStaleOwnEntry(in: dir, pid: ProcessInfo.processInfo.processIdentifier)
        reapDead(in: dir)
    }

    /// 一度きりの門(`reaped`)と分けてあるのはテストのため —— 門は プロセス全体の状態なので、
    /// 掃除そのものを直接呼べないと「掃除しない」変異を殺せるテストが書けない
    func reapDead(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(".json".count)), pid > 0,
                  !ProcessLiveness.isAlive(pid) else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 自分の pid の控えを無条件に消す(reapOnce の doc 参照。テスト用に internal)
    func reapStaleOwnEntry(in dir: URL, pid: Int32) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(pid).json"))
    }

    /// インスタンスの状態(累計・書き込み済み累計・掃除の門)を初期化する。**テスト専用** ——
    /// 門を戻さないと「最初の record」の経路を2度と通せない
    func resetForTesting() {
        lock.lock()
        calls = 0; failures = 0; totalMs = 0
        lock.unlock()
        writeLock.lock()
        lastWrittenCalls = 0
        writeLock.unlock()
        reapLock.lock()
        reaped = false
        reapLock.unlock()
    }
}

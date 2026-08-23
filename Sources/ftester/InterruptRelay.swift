// InterruptRelay.swift
// 中断(SIGINT / SIGTERM / SIGHUP)を、いま動かしている子プロセスへ伝えるための箱。
//
// **親を殺しても子は死なない**: Foundation の Process は親の終了に子を巻き込まないので、
// ftester を kill しても ssh クライアントは生き残る。すると `-tt` が担っていた
// 「切断でリモートのプロセスグループへ SIGHUP」(docs/remote-runner.md §16.1)が**発火しない** ——
// リモートには走りっぱなしの run が残り、dispatch.lock も握られたままになる
// (2026-08-18 に実測。残った子は exit 途中で刺さり、次のディスパッチが数十分ぶん詰まった)。
//
// 中断を握りつぶすのではなく、**子を落としてから通常の巻き戻しを続ける**のが要点:
// そうすることで呼び出し側の defer(dispatch.lock の解放・終了スクリプト)が動く。
//
// **1プロセスに1組のシグナルソース**(2026-08-24): ホスト別の子を並行に持つ親
// (DeviceHostRunner / FleetRunner / ApiRunHostFanout)は relay を同時に複数抱える。
// 以前は relay ごとにソースを立て、`stop()` が `signal(sig, SIG_DFL)` を戻していたため、
// **先に終わった子の stop() が残りの子の横取りまで解いていた** —— 手元のぶんが先に終わった
// 分散 run の親へ `kill -INT` すると、親だけ既定動作で死に、残った M1Max の子・ssh・リモートの
// run・dispatch.lock が全部残った(受け手報告 2026-08-23。端末の Ctrl-C はプロセスグループ
// 全体に届くので子も自力で止まり、差が出ない)。ソースは登録が 0→1 で立て、1→0 で戻す。

import Foundation

final class InterruptRelay {
    private struct Target {
        let process: Process
        let escalateAfter: TimeInterval?
    }

    private static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private static let queue = DispatchQueue(label: "ftester.interrupt-relay")
    private static let lock = NSLock()
    private static var targets: [ObjectIdentifier: Target] = [:]
    private static var sources: [DispatchSourceSignal] = []

    private let id: ObjectIdentifier
    private var stopped = false

    private init(id: ObjectIdentifier) {
        self.id = id
    }

    /// `process` が動いている間だけ中断を横取りし、受けたら子へ SIGTERM を送る。
    /// 戻り値を `stop()` するまで有効(呼び出し側は defer で止める)。
    ///
    /// - escalateAfter: SIGTERM で死ななかったときに SIGKILL するまでの猶予。
    ///   **nil = エスカレートしない**。使い分け:
    ///   - **ssh(外部プロセス。片付けるものが無い)= 2 秒**。残すと「親は死んだのにリモートは
    ///     走り続ける」元の症状に戻るので必ず落とす
    ///   - **ftester の子(ホスト別サブ実行)= nil**。こちらは SIGTERM を受けてから
    ///     dispatch.lock の解放と終了スクリプトを走らせる。**時間で殺すとそれを飛ばす** ——
    ///     2 秒で殺していた版では実際にロックが残った(2026-08-18 実測: 子の exit=9)。
    ///     片付けの所要は利用者のスクリプト次第で上限を決められないので、待つ側に倒す
    ///     (刺さった場合は人が kill -9 する)
    static func forwarding(to process: Process, escalateAfter: TimeInterval? = 2) -> InterruptRelay {
        let id = ObjectIdentifier(process)
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = targets.isEmpty
        targets[id] = Target(process: process, escalateAfter: escalateAfter)
        if wasEmpty { installSources() }
        return InterruptRelay(id: id)
    }

    /// 横取りをやめる。**最後の1つが止まったときだけ**既定動作へ戻す(以降の中断は普通に
    /// このプロセスを終わらせる)。二重に呼んでも無害
    func stop() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !stopped else { return }
        stopped = true
        Self.targets.removeValue(forKey: id)
        if Self.targets.isEmpty { Self.uninstallSources() }
    }

    /// 現在登録されている子の数(テスト用)
    static var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return targets.count
    }

    // lock を握ったまま呼ぶ
    private static func installSources() {
        for sig in signals {
            // **DispatchSourceSignal は既定動作を止めない**ので、先に無視へ倒す
            // (これを忘れると、ハンドラが動く前にプロセスごと終わる)
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { forwardToAll() }
            source.resume()
            sources.append(source)
        }
    }

    // lock を握ったまま呼ぶ
    private static func uninstallSources() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for sig in signals { signal(sig, SIG_DFL) }
    }

    private static func forwardToAll() {
        lock.lock()
        let snapshot = Array(targets.values)
        lock.unlock()
        for target in snapshot {
            guard target.process.isRunning else { continue }
            target.process.terminate()
            guard let escalateAfter = target.escalateAfter else { continue }
            let process = target.process
            queue.asyncAfter(deadline: .now() + escalateAfter) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

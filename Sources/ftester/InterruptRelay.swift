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

import Foundation

final class InterruptRelay {
    private let sources: [DispatchSourceSignal]
    private let signals: [Int32]

    private init(sources: [DispatchSourceSignal], signals: [Int32]) {
        self.sources = sources
        self.signals = signals
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
        let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
        var sources: [DispatchSourceSignal] = []
        let queue = DispatchQueue(label: "ftester.interrupt-relay")
        for sig in signals {
            // **DispatchSourceSignal は既定動作を止めない**ので、先に無視へ倒す
            // (これを忘れると、ハンドラが動く前にプロセスごと終わる)
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                guard process.isRunning else { return }
                process.terminate()
                guard let escalateAfter else { return }
                queue.asyncAfter(deadline: .now() + escalateAfter) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            source.resume()
            sources.append(source)
        }
        return InterruptRelay(sources: sources, signals: signals)
    }

    /// 横取りをやめて既定動作へ戻す(以降の中断は普通にこのプロセスを終わらせる)
    func stop() {
        for source in sources { source.cancel() }
        for sig in signals { signal(sig, SIG_DFL) }
    }
}

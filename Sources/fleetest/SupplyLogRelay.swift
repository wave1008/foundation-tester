// 供給フェーズ(デバイス起動・インストール・凍結 triage)の進行を NDJSON の log イベントへ中継する。
// stderr だけだと拡張の OUTPUT にしか出ず、「テスト実行」タブは冷えた状態からの数分間(実測:
// 手元8台のエミュレータ起動で 3分39秒)無音になる。
//
// **runStarted より前の行は貯める**: 拡張のレーン状態は NDJSON の runStarted で clear されるので
// (対向: vscode-fleetest/src/runLaneModel.ts の reduceLaneEvent "runStarted")、先に流した行は
// 必ず消える。供給は Task で並行に走るのでロックで守る。

import Foundation

final class SupplyLogRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var started = false

    /// runStarted 前は貯め、以後は即時に write へ渡す。
    func emit(_ line: String, write: (String) -> Void) {
        lock.lock()
        guard started else {
            pending.append(line)
            lock.unlock()
            return
        }
        lock.unlock()
        write(line)
    }

    /// runStarted を出した直後に呼ぶ。貯めた行を届いた順に流し、以後は即時中継へ切り替える。
    func start(write: (String) -> Void) {
        lock.lock()
        started = true
        let queued = pending
        pending.removeAll()
        lock.unlock()
        for line in queued { write(line) }
    }
}

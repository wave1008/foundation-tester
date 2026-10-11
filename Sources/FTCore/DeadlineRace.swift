// 期限付きのレース(先に終わった方で決める)。RunOrchestrator の死活確認と、FM の生死確認(FMLivenessProbe)が共有する。

import Foundation

public enum DeadlineRace {
    /// `op` を最大 `seconds` 秒待つ。期限が先なら nil を返し、`op` はキャンセルだけして**待たない**。
    ///
    /// **withTaskGroup は使わない**: 構造化並行はスコープ終端で全子タスクの完了を待つため、
    /// op(URLSession・FM の呼び出し)がキャンセルに即応しないと cancelAll しても遅い方を待ち続けてハングする。
    /// ここは「先に終わった方で即確定・遅い方は待たない」レースにする(継続を一度だけ resume)。
    /// 期限側が勝った op は放置される(URLSession は自分の timeout で、FM は応答した時点で自然に終わる)。
    /// op が throw したときも nil(呼び手は「期限内に値が得られなかった」と同じに扱う)
    public static func first<T: Sendable>(
        seconds: Double, _ op: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let settled = DeadlineGuard()
        // 敗者を残さないため相互キャンセルする(op が先に終わったら満期スリーパーを cancel。
        // 残すと呼び出し毎に seconds 秒のスリーパー task が居座る)。
        let timeoutBox = DeadlineTaskBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let opTask = Task {
                let result = try? await op()
                if await settled.claim() {
                    timeoutBox.cancel()
                    cont.resume(returning: result)
                }
            }
            timeoutBox.hold(Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if await settled.claim() {
                    opTask.cancel()
                    cont.resume(returning: nil)
                }
            })
        }
    }
}

/// 「継続を一度だけ resume する」ガード(op 完了 と 期限 のレース勝者判定)。
private actor DeadlineGuard {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

/// DeadlineRace.first の満期スリーパー task 参照を保持する箱(op 勝利時に cancel するための前方参照用)。
/// **代入(生成側)と参照(opTask 側)は並行に走る**: `Task { }` の本体は囲みの同期区間と
/// 並行に開始し得るので「代入は op の初回 await より前に完了する」は成り立たない
/// (ThreadSanitizer が実測で競合を報告)。素の `var` だと競合そのものに加え、
/// **代入前に op が勝つと cancel を取りこぼしスリーパーが seconds 秒居座る**
/// (この箱を置いた目的が消える)ため、**先に来た cancel を覚えて後から来た task に適用する**。
/// `@unchecked Sendable` の根拠は lock(素の可変参照ではない)。
/// 同型の RecordingSupport.raceWithDeadline は前方参照を持たない = この箱が要らない
final class DeadlineTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelRequested = false

    /// 生成側から1回だけ渡す。既に cancel 済みならその場で cancel する
    func hold(_ task: Task<Void, Never>) {
        lock.lock()
        let cancelNow = cancelRequested
        self.task = task
        lock.unlock()
        // cancel はロックの外で呼ぶ(並行ランタイムへの呼び出しをロック下に置かない)
        if cancelNow { task.cancel() }
    }

    /// op 勝利側から呼ぶ。task 未設定でも記憶しておき hold 時に適用する
    func cancel() {
        lock.lock()
        cancelRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

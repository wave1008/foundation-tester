// DSL 専用スレッド(協調スレッドプール外)から async の StepExecutor/AppDriver へ橋渡しする同期ファサード。
// ブロックするのは DSL スレッドのみで、async 側(URLSession/Process/FoundationModels)は
// このスレッドを必要としないためデッドロックしない。万一のハングに備え待機に上限タイムアウトを設ける。

import Foundation
import FTCore

enum FTSync {
    /// コマンド 1 回の上限待機秒数
    static var commandTimeout: TimeInterval = 120

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    /// **タスクが実際に走り出すまでの待ち**(協調スレッドプールの空き待ち)を持ち帰る箱。
    /// 壁時計の締め切りは順番待ちの時間も数えてしまうので、それが何割かを測れないと
    /// 締め切りの妥当性を判断できない(実測 2026-09-10: 20 秒超のステップは
    /// snapshot/action/wait のどれにも計上されない時間が 99.7% を占めていた)。
    /// 別スレッドから書くのでロックで守る。**最初の1回だけ**記録する。
    final class ScheduleDelay: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        func record(_ ms: Int) { lock.lock(); if value == nil { value = ms }; lock.unlock() }
        var milliseconds: Int? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// タイムアウト時は nil。**そのとき op は必ず cancel する** — 放置すると諦めたはずの
    /// tap/snapshot が**後続ステップの最中にブリッジへ着弾**し、記録に残らないまま画面を動かす
    /// (原因不明の一発ずれになる)。cancel は届く: 通信は cancel 対応の `URLSession.data(for:)`、
    /// 待ちは `Task.sleep`(cancel で throw)なので、掴んだままのループも巻き戻る。
    /// 相手が cancel を見ない処理(Process 実行等)では従来どおり走り切るだけで、悪化はしない。
    ///
    /// **`DeadlineExclusion` に積まれた分だけ締め切りを延ばす**(OCR 近道の暖機待ち等、
    /// ツールの都合で払った時間を締め切りから外すため)。延長できるのは実際に差し引かれた分だけ
    /// —— 打ち切りの意味は変えない。`op` を始める前に基準点(snapshot)を取り、タイムアウトの
    /// たびに「そこから新たに差し引かれた分」だけ待ちを継ぎ足す(継ぎ足しが 0 なら本当のタイムアウト)
    static func run<T>(timeout: TimeInterval = FTSync.commandTimeout,
                       scheduleDelay: ScheduleDelay? = nil,
                       _ op: @escaping () async -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        let queuedAt = ContinuousClock().now
        let exclusionSnapshot = DeadlineExclusion.snapshot()
        let task = Task.detached(priority: .userInitiated) {
            if let scheduleDelay {
                // **最初の1命令が走った時刻**。ここまでの差は「順番待ち」で、ステップは1命令も
                // 実行していない —— 締め切りに数えてよい時間かどうかの判断材料になる
                let waited = ContinuousClock().now - queuedAt
                scheduleDelay.record(Int((waited / .milliseconds(1)).rounded()))
            }
            box.value = await op()
            semaphore.signal()
        }
        var remaining = timeout
        var grantedExtraSeconds: TimeInterval = 0
        while true {
            guard semaphore.wait(timeout: .now() + max(0, remaining)) == .success else {
                let excludedSeconds = seconds(DeadlineExclusion.excluded(since: exclusionSnapshot))
                let newExtra = excludedSeconds - grantedExtraSeconds
                guard newExtra > 0 else {
                    task.cancel()
                    return nil
                }
                grantedExtraSeconds = excludedSeconds
                remaining = newExtra
                continue
            }
            return box.value
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (wholeSeconds, attoseconds) = duration.components
        return Double(wholeSeconds) + Double(attoseconds) / 1e18
    }

    /// throwing 版(タイムアウト時は nil)
    static func runThrowing<T>(timeout: TimeInterval = FTSync.commandTimeout,
                               _ op: @escaping () async throws -> T) -> Result<T, Error>? {
        run(timeout: timeout) {
            do { return .success(try await op()) } catch { return .failure(error) }
        }
    }
}

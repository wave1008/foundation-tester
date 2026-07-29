// DSL 専用スレッド(協調スレッドプール外)から async の StepExecutor/AppDriver へ橋渡しする同期ファサード。
// ブロックするのは DSL スレッドのみで、async 側(URLSession/Process/FoundationModels)は
// このスレッドを必要としないためデッドロックしない。万一のハングに備え待機に上限タイムアウトを設ける。

import Foundation

enum FTSync {
    /// コマンド 1 回の上限待機秒数
    static var commandTimeout: TimeInterval = 120

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    /// タイムアウト時は nil。**そのとき op は必ず cancel する** — 放置すると諦めたはずの
    /// tap/snapshot が**後続ステップの最中にブリッジへ着弾**し、記録に残らないまま画面を動かす
    /// (原因不明の一発ずれになる)。cancel は届く: 通信は cancel 対応の `URLSession.data(for:)`、
    /// 待ちは `Task.sleep`(cancel で throw)なので、掴んだままのループも巻き戻る。
    /// 相手が cancel を見ない処理(Process 実行等)では従来どおり走り切るだけで、悪化はしない
    static func run<T>(timeout: TimeInterval = FTSync.commandTimeout,
                       _ op: @escaping () async -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        let task = Task.detached(priority: .userInitiated) {
            box.value = await op()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            return nil
        }
        return box.value
    }

    /// throwing 版(タイムアウト時は nil)
    static func runThrowing<T>(timeout: TimeInterval = FTSync.commandTimeout,
                               _ op: @escaping () async throws -> T) -> Result<T, Error>? {
        run(timeout: timeout) {
            do { return .success(try await op()) } catch { return .failure(error) }
        }
    }
}

// 「予算内に返らなければ諦める。**ただし走っている仕事は止めない**」だけを持つ小さな道具。
//
// なぜ止めないか(2026-09-10 の実測): 諦めるのは近道(OCR)が本道(FM)より高くついたときで、
// その高さの正体は**プロセスに1回だけ**の初期化(Vision のモデルロード)だった。ここで巻き添えに
// 止めると初期化がやり直しになり、次のステップもまた予算を使い切る —— 放っておけばそのまま
// 暖機として効き、2 回目以降は桁が変わる。
//
// **タスクグループで待ってはいけない**(2026-09-10 に実際に間違えた): `withTaskGroup` の本体を
// 抜けるとき、グループは残った子の完了を待つ。子が非構造化タスクの `value` を await していると
// `cancelAll()` では止まらないので、**戻り値だけ `.exhausted` で所要は仕事の全長**になる
// —— 諦めたのに何も速くならない。だから合流点は「先に来たほうで1回だけ resume する門」にする。

import Foundation

public enum Budgeted<T: Sendable>: Sendable {
    case value(T)
    /// 予算が尽きた(仕事はまだ走っているかもしれない)
    case exhausted
}

public enum TaskBudget {
    /// `work` が `budget` 以内に返れば `.value`、返らなければ `.exhausted`。
    /// **`.exhausted` は予算ちょうどで返る**(仕事の完了を待たない)し、
    /// **その後も `work` は走り続ける**(このファイル冒頭の理由)
    /// `onLateFinish` は **`.exhausted` を返した後に仕事が終わったとき**だけ呼ばれる
    /// (予算内に終わった回は呼ばない)。諦めた仕事の本当の所要を残すための口
    public static func run<T: Sendable>(_ budget: Duration,
                                        onLateFinish: (@Sendable (T, Duration) -> Void)? = nil,
                                        _ work: @escaping @Sendable () async -> T)
        async -> Budgeted<T> {
        let gate = Gate<T>()
        // どちらも非構造化(group.addTask ではない)。呼び手が消えてもこの2本は巻き添えにならない
        Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            let value = await work()
            if !gate.deliver(.value(value)) { onLateFinish?(value, clock.now - start) }
        }
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: budget)
            gate.deliver(.exhausted)
        }
        return await gate.wait()
    }

    /// 先に来たほうで**ちょうど1回だけ** resume する門。2 本目の deliver は捨てる
    /// (継続の二重 resume はクラッシュ)
    /// **先着だけを採る**契約は TaskBudgetGateTests が直接固定する(内部型だが internal にしてあるのは
    /// そのため。2 本が待ち始める前に届く順序は `run` からは作れない)
    final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Budgeted<T>, Never>?
        private var delivered: Budgeted<T>?

        init() {}

        func wait() async -> Budgeted<T> {
            await withCheckedContinuation { (c: CheckedContinuation<Budgeted<T>, Never>) in
                lock.lock()
                // 待ち始める前に決着していることがある(予算 0・即返る仕事)
                if let value = delivered {
                    lock.unlock()
                    c.resume(returning: value)
                    return
                }
                continuation = c
                lock.unlock()
            }
        }

        /// 戻り値 = 先着として採られたか(false = 既に決着していて捨てた)
        @discardableResult
        func deliver(_ outcome: Budgeted<T>) -> Bool {
            lock.lock()
            // **先着だけを採る**。ここを外すと 2 本目が継続を二重に resume してクラッシュする
            guard delivered == nil else { lock.unlock(); return false }
            delivered = outcome
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: outcome)
            return true
        }
    }
}

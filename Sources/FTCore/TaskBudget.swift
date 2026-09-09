// 「予算内に返らなければ諦める。**ただし走っている仕事は止めない**」だけを持つ小さな道具。
//
// なぜ止めないか(2026-09-10 の実測): 諦めるのは近道(OCR)が本道(FM)より高くついたときで、
// その高さの正体は**プロセスに1回だけ**の初期化(Vision のモデルロード)だった。ここで巻き添えに
// 止めると初期化がやり直しになり、次のステップもまた予算を使い切る —— 放っておけばそのまま
// 暖機として効き、2 回目以降は桁が変わる。
//
// **仕事を構造化並行の子(group.addTask)にしない**のが要点 —— 子にすると `cancelAll()` が
// 仕事ごと巻き戻す。非構造化タスクは親スコープの cancel を継がないので、諦めた後も走り切る
// (`Task.detached` にしているのは、加えて task-local と優先度を呼び手から継がないため)。

import Foundation

public enum Budgeted<T: Sendable>: Sendable {
    case value(T)
    /// 予算が尽きた(仕事はまだ走っているかもしれない)
    case exhausted
}

public enum TaskBudget {
    /// `work` が `budget` 以内に返れば `.value`、返らなければ `.exhausted`。
    /// **`.exhausted` を返した後も `work` は走り続ける**(このファイル冒頭の理由)
    public static func run<T: Sendable>(_ budget: Duration,
                                        _ work: @escaping @Sendable () async -> T)
        async -> Budgeted<T> {
        // 非構造化タスク(group.addTask ではない)。ここを子にすると下の cancelAll() で巻き添えになる
        let task = Task.detached(priority: .userInitiated) { await work() }
        return await withTaskGroup(of: Budgeted<T>.self, returning: Budgeted<T>.self) { group in
            group.addTask { .value(await task.value) }
            group.addTask {
                try? await Task.sleep(for: budget)
                return .exhausted
            }
            let first = await group.next() ?? .exhausted
            // 勝った側だけを採る。**detached の task はここで止まらない**
            group.cancelAll()
            return first
        }
    }
}

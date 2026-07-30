// プラットフォーム別レーン稼働から「配分を変えると壁時計が縮む」状況を検出して助言を出す。
//
// docs/performance-tuning.md §3.6 の実測(SampleApp 76シナリオ・M2 Ultra)では、
// iOS 5レーンが稼働 88〜96% で 185秒まで詰まっている一方、Android 5レーンは 88秒で終わって
// 残り 52% の時間を遊休していた。このとき **Android のデバイスを増やしても壁時計は 1 秒も縮まない**。
// 同じ台数のまま iOS へ振り替えるのが最も効く。
//
// 判定は純粋関数。実機を必要としないので単体テストで固める(FTesterTests)。

import Foundation

enum LaneBalanceAdvice {

    /// 律速側とみなす稼働率の下限(これ未満なら「詰まっている」とは言わない)
    static let busyUtilizationThreshold = 0.7
    /// 遊休側とみなす稼働率の上限
    static let idleUtilizationThreshold = 0.5
    /// 遊休側の最終終了が、律速側のそれのこの割合より早いときだけ助言する
    /// (僅差で終わっている場合は振り替えても縮まないため黙る)
    static let earlyFinishRatio = 0.75

    /// 振り替えを勧めるべきなら1行のメッセージ、そうでなければ nil。
    ///
    /// 条件は3つ全て:
    /// - 明確に詰まっているプラットフォームがある(稼働率が高い = クリティカルパス)
    /// - 明確に遊休しているプラットフォームがある(稼働率が低い)
    /// - 遊休側が律速側よりはっきり早く終わっている(遅い方に引きずられていない)
    static func message(for utilizations: [LaneUtilization]) -> String? {
        guard utilizations.count > 1 else { return nil }
        guard let busiest = utilizations.max(by: { $0.utilization < $1.utilization }),
              let idlest = utilizations.min(by: { $0.utilization < $1.utilization }),
              busiest.platform != idlest.platform else { return nil }

        guard busiest.utilization >= busyUtilizationThreshold,
              idlest.utilization <= idleUtilizationThreshold,
              busiest.lastFinishSeconds > 0,
              idlest.lastFinishSeconds <= busiest.lastFinishSeconds * earlyFinishRatio,
              idlest.lanes > 1 else { return nil }

        let idleSeconds = busiest.lastFinishSeconds - idlest.lastFinishSeconds
        return "💡 \(idlest.platform) finishes \(String(format: "%.1f", idleSeconds))s early"
            + " (\(Int((idlest.utilization * 100).rounded()))% busy). "
            + "The wall clock is set by \(busiest.platform), so "
            + "moving devices from \(idlest.platform) to \(busiest.platform) shortens the run"
            + " (rebalance the split rather than adding devices)"
    }
}

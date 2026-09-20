// run 進捗の残り見積もり(段5。docs/design.md §18.4)。純粋関数のみ —— I/O は呼び手
// (RunOrchestrator.run。同じファイル内で RunResultsStore.scanRecords + LPTScheduler.durations を
// 読む)が持つ。ここでは「実績の表 + 未着手/実行中の集合」から makespan の下界を1つ計算するだけ。
//
// 式は §18.4 のまま(水増ししない・新しい定数を置かない):
//   残り = Σ(未着手の推定) + Σ(実行中レーンの max(0, 推定 − そのシナリオの経過))
//   eta  = max( 残っている単一ジョブの最大, 残り ÷ 生きているレーン数 )
// 並列スケジューリングの makespan は「最長ジョブ」と「総和 ÷ 台数」のどちらも下回れないので、
// これは下界(実際はこれ以上かかる)。早い者勝ちのキューを LPT で再現したり係数で水増ししない。

import Foundation

public enum RunProgressEstimate {
    /// `LPTScheduler.Duration` と同じ鍵((scenarioID, platform))。表を引きやすくするためだけの型
    public struct ScenarioKey: Hashable, Sendable {
        public let scenarioID: String
        public let platform: String

        public init(scenarioID: String, platform: String) {
            self.scenarioID = scenarioID
            self.platform = platform
        }
    }

    /// `LPTScheduler.durations` の結果を (scenarioID, platform) で引ける表にし、この run に
    /// 出てくる全シナリオぶんの穴を埋める。**実績が1件も無ければ空のまま返す**
    /// (`etaSeconds` はここが空なら nil を返す = 推測値を出さない)。
    /// 埋める値は「実績のある中央値の中央値」(`FleetRunner.runSplit` の `unknownDurationMs` と
    /// 同じ考え方 —— 既にある手口を流用し、新しい定数は持ち込まない)
    public static func estimateTable(
        durations: [LPTScheduler.Duration], scenarios: [ScenarioKey]
    ) -> [ScenarioKey: Double] {
        var table = Dictionary(
            durations.map { (ScenarioKey(scenarioID: $0.scenarioID, platform: $0.platform), $0.medianMs) },
            uniquingKeysWith: { first, _ in first })
        guard !table.isEmpty else { return [:] }
        let fallback = median(of: Array(table.values))
        for key in scenarios where table[key] == nil {
            table[key] = fallback
        }
        return table
    }

    /// 未着手/実行中レーンから残り見積もり(秒)を作る。**makespan の下界**であって実測ではない
    /// (呼び手は必ず `~` 付きで表示する。docs/design.md §18.4)。
    /// - table: `estimateTable` の結果(ms)。空 = 実績ゼロ → nil を返す
    /// - pending: 未着手ジョブ。同じ (scenarioID, platform) が複数残っていれば
    ///   そのぶん複数渡す(multiset。broadcast は同じシナリオが複数レーンぶん残りうる)
    /// - running: 実行中レーンぶん (そのシナリオの鍵, その時点の経過秒)
    /// - liveLanes: 生きている(join 済みの)レーン数。0 なら計算できない(nil)
    /// - table に無い鍵(呼び手が `scenarios` に含め忘れた等)は寄与ゼロとして無視する
    ///   (`estimateTable` の穴埋めにより通常は起きない)
    public static func etaSeconds(
        table: [ScenarioKey: Double], pending: [ScenarioKey],
        running: [(scenario: ScenarioKey, elapsedSeconds: Double)], liveLanes: Int
    ) -> Int? {
        guard !table.isEmpty, liveLanes > 0 else { return nil }

        var remainingSeconds = 0.0
        var longestSingleRemainingSeconds = 0.0

        for key in pending {
            guard let ms = table[key] else { continue }
            let seconds = ms / 1000
            remainingSeconds += seconds
            longestSingleRemainingSeconds = max(longestSingleRemainingSeconds, seconds)
        }
        for job in running {
            guard let ms = table[job.scenario] else { continue }
            let remaining = max(0, ms / 1000 - job.elapsedSeconds)
            remainingSeconds += remaining
            longestSingleRemainingSeconds = max(longestSingleRemainingSeconds, remaining)
        }

        let perLane = remainingSeconds / Double(liveLanes)
        // 下界であって実測ではないので、丸めで実際より早く終わるように見せない = 切り上げ
        // (切り捨てると「もう終わっているはず」の見た目を作ってしまう。超過表示は §18.4 が想定内)
        return Int(max(longestSingleRemainingSeconds, perLane).rounded(.up))
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// FleetSplit.swift
// `ftester run --fleet <name> --split`(docs/remote-runner.md §8「シナリオバッチを複数 Mac に
// 割り当てる」)の純粋ロジック。実績の中央値は既存の LPTScheduler.Duration / durations(from:) を
// そのまま使う(中央値算出を二重に持たない)。ssh・プロセス起動・ローカルビルド・ホスト→
// platform の解決は呼び出し側(Sources/ftester/FleetRunner.swift)に置く。
//
// LPT(longest processing time first)貪欲法: 見積りの長いシナリオから、その時点の負荷合計が
// 最小の"適合する"エントリへ入れる。同着は決定的に解く(負荷合計の同点は entryIndex 昇順、
// 見積り時間の同点は scenario ID 昇順) —— 同じ入力から run のたびに違う割り当てが出ると、
// flake 調査で「前回と同じ割り当て」を再現できなくなる。
//
// platform 適合を守らない割り当ては「走ったつもりで走っていない」を静かに作るので、
// 適合するエントリが1つも無いシナリオは黙って落とさず throw する。
//
// 実績が無いシナリオの見積り(unknownDurationMs)は呼び出し側が決める。プロジェクトごとに
// 実行速度が大きく違うので、固定の秒数をここに埋め込まない(別の文脈で調整した定数の流用は
// 誤った推定を生む。記憶: context-blind-constants-20260815)。

import Foundation

public enum FleetSplit {

    /// 1エントリへの割り当て結果。scenarioIDs は投入順(見積り降順)のまま保持する ——
    /// 呼び出し側がそのまま --scenario へ渡せば、そのエントリ内でも長い順に投入される
    public struct Bucket: Equatable, Sendable {
        public let entryIndex: Int
        public let scenarioIDs: [String]
        public let estimatedMs: Double

        public init(entryIndex: Int, scenarioIDs: [String], estimatedMs: Double) {
            self.entryIndex = entryIndex
            self.scenarioIDs = scenarioIDs
            self.estimatedMs = estimatedMs
        }
    }

    public enum FleetSplitError: Error, LocalizedError, Equatable {
        /// scenario の platform に適合するエントリが1つも無い
        case noFittingEntry(scenarioID: String, platform: String)

        public var errorDescription: String? {
            switch self {
            case .noFittingEntry(let scenarioID, let platform):
                return "no fleet entry can run platform \"\(platform)\" scenario \(scenarioID)"
                    + " (add a device for that platform to one of the fleet's entries,"
                    + " or move the scenario off this fleet)"
            }
        }
    }

    /// LPT で貪欲に詰める。
    /// - scenarios: platform は "ios" / "android" / nil(どちらでも可)
    /// - durations: 実績の中央値(LPTScheduler.durations(from:) の出力をそのまま渡す)。
    ///   同じ scenarioID に複数 platform の記録があれば大きい方を採る(platform 未指定の
    ///   シナリオはどちらへ転んでも過小評価にならないよう安全側に倒す)
    /// - entryPlatforms: fleet の実行対象エントリと同じ並び・同じ本数。空集合 = そのエントリは
    ///   どのシナリオも受けない(呼び出し側は空バケツを skip として扱う)
    /// - unknownDurationMs: 実績の無いシナリオの見積り(既定値の根拠は呼び出し側のコメントに書く)
    public static func partition(
        scenarios: [(id: String, platform: String?)],
        durations: [LPTScheduler.Duration],
        entryPlatforms: [Set<String>],
        unknownDurationMs: Double
    ) throws -> [Bucket] {
        var medianByScenario: [String: Double] = [:]
        for duration in durations {
            medianByScenario[duration.scenarioID] =
                max(medianByScenario[duration.scenarioID] ?? 0, duration.medianMs)
        }
        func estimatedMs(_ id: String) -> Double { medianByScenario[id] ?? unknownDurationMs }

        // 見積り降順、同着は scenario ID 昇順(決定的)
        let ordered = scenarios.sorted { lhs, rhs in
            let l = estimatedMs(lhs.id), r = estimatedMs(rhs.id)
            if l != r { return l > r }
            return lhs.id < rhs.id
        }

        var scenarioIDs = [[String]](repeating: [], count: entryPlatforms.count)
        var totals = [Double](repeating: 0, count: entryPlatforms.count)

        for scenario in ordered {
            let fitting = entryPlatforms.indices.filter { index in
                guard let platform = scenario.platform else { return !entryPlatforms[index].isEmpty }
                return entryPlatforms[index].contains(platform)
            }
            // 負荷合計が最小のエントリへ。同着は entryIndex 昇順(決定的)
            guard let target = fitting.min(by: { (totals[$0], $0) < (totals[$1], $1) }) else {
                throw FleetSplitError.noFittingEntry(
                    scenarioID: scenario.id, platform: scenario.platform ?? "ios/android")
            }
            scenarioIDs[target].append(scenario.id)
            totals[target] += estimatedMs(scenario.id)
        }

        return entryPlatforms.indices.map {
            Bucket(entryIndex: $0, scenarioIDs: scenarioIDs[$0], estimatedMs: totals[$0])
        }
    }
}

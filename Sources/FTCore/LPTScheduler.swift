// シナリオの投入順を LPT(Longest Processing Time first)にする。
//
// 既定の投入順はシナリオ ID 順(= クラス名順)で、実行時間とは無関係。並列ワーカーは空き次第
// 先頭から取るので、長いシナリオが最後に残ると 1 レーンだけが延々と走って壁時計がその 1 本に
// 引きずられる。過去の実測(結果 JSON の durationMs)の降順に並べ替えると、長いものが先に走り
// 短いものが末尾の隙間を埋めるので、同じ台数のまま壁時計が縮む。
//
// これは古典的な list scheduling のヒューリスティックで、最適解ではないが
// 「最長ジョブの実行時間」を下限として (4/3 - 1/(3m)) 倍以内に収まることが知られている。
//
// 実績が無いシナリオ(新規追加・初回実行)は**先頭に置く**。所要が不明なものを最後に回すと、
// それが長かった場合に LPT の狙いがそのまま裏返るため、悲観側に倒す。
//
// **実績は platform ごとに分ける**。同じシナリオを iOS と Android の両プロファイルで走らせる
// 構成(このリポジトリの TestProjects/E2E-CMP 等)では 1 つの results/ に両方の記録が溜まり、iOS は
// Android の数倍遅いため、混ぜると中央値が両者の中間に均されて順序判断が歪む。
//
// **実績は machine ごとにも優先して分ける**(2026-08-18)。リモート実行(remote runner)で
// 走った記録が回収されて手元の results/ に混ざるようになったため、機械ごとの速度差が同じ理由で
// 中央値を歪める。同一 machine の記録があればそれだけで中央値を作り、無ければ従来どおり
// 全 machine 混合の中央値へフォールバックする(相対順は機械を跨いでもおおむね保たれるため)。

import Foundation

public enum LPTScheduler {

    /// 実績の代表値。中央値を使う(平均は 1 回の外れ値=振り直し・コールド起動に引きずられる)。
    public struct Duration: Sendable, Equatable {
        public let scenarioID: String
        /// "ios" / "android"。記録が持つ実行 platform。
        public let platform: String
        public let medianMs: Double

        public init(scenarioID: String, platform: String, medianMs: Double) {
            self.scenarioID = scenarioID
            self.platform = platform
            self.medianMs = medianMs
        }
    }

    private struct Key: Hashable {
        let scenarioID: String
        let platform: String
    }

    /// (scenarioID, platform, machine) ごとの実績の代表値。FleetSplit の機械別見積りに使う。
    public struct MachineDuration: Sendable, Equatable {
        public let scenarioID: String
        public let platform: String
        public let machine: String
        public let medianMs: Double

        public init(scenarioID: String, platform: String, machine: String, medianMs: Double) {
            self.scenarioID = scenarioID
            self.platform = platform
            self.machine = machine
            self.medianMs = medianMs
        }
    }

    private struct MachineKey: Hashable {
        let scenarioID: String
        let platform: String
        let machine: String
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// items を LPT 順に並べ替える。
    /// - 実績があるものは medianMs の降順
    /// - 実績が無いものは先頭(未知は長いかもしれないので先に流す)
    /// - 同値・実績なし同士は元の順序を保つ(安定)
    ///
    /// - defaultPlatform: シナリオが platform を明示していないときに走る platform
    ///   (RunOrchestrator.run の defaultPlatform と同じ値を渡すこと。ここがズレると
    ///   別 platform の実績で並べてしまう)。
    public static func order(_ items: [ScenarioRunItem], durations: [Duration],
                             defaultPlatform: String) -> [ScenarioRunItem] {
        guard !items.isEmpty else { return [] }
        let medianByKey = Dictionary(
            durations.map { (Key(scenarioID: $0.scenarioID, platform: $0.platform), $0.medianMs) },
            uniquingKeysWith: { first, _ in first })

        func median(of item: ScenarioRunItem) -> Double? {
            medianByKey[Key(scenarioID: item.info.id,
                            platform: item.info.platform ?? defaultPlatform)]
        }

        // enumerated() で元 index を持ち、比較が同値のときは index 順に倒して安定ソートにする。
        // Swift の sorted(by:) は**実装上は安定だが仕様として保証されていない**(実測: 200要素・
        // 同値混在でも順序は保たれた)。したがってこの安定化は将来の stdlib 変更に対する保険で、
        // 外しても現在の挙動は変わらない = 変異テストでは検出できない。実行順が run ごとに揺れると
        // 前後比較ができなくなるため、保証されるまでは残す。
        return items.enumerated().sorted { lhs, rhs in
            let lhsMedian = median(of: lhs.element)
            let rhsMedian = median(of: rhs.element)
            switch (lhsMedian, rhsMedian) {
            case let (l?, r?):
                if l != r { return l > r }
            case (nil, .some):
                return true   // 実績なしを先に
            case (.some, nil):
                return false
            case (nil, nil):
                break
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 結果レコードから (シナリオ, platform) ごとの中央値を作る。
    /// - skipped 合成レコード(platform 不一致等)は除く — durationMs=0 として混ざると中央値が
    ///   落ちて「短いシナリオ」と誤認し、末尾へ回ってしまう。
    /// - platform 空の記録も除く(どの platform の実績か決められない)。
    /// - machine: 指定すると、(scenarioID, platform) グループ内に record.machine == machine の
    ///   記録が1件以上あるとき**その部分集合だけ**で中央値を作る(機械ごとの速度差で歪めない)。
    ///   無ければグループ全体(全 machine 混合)の中央値へフォールバックする。nil(既定)は
    ///   常に混合 = 従来と同一挙動。
    public static func durations(from records: [ScenarioRunRecord],
                                 preferringMachine machine: String? = nil) -> [Duration] {
        let usable = records.filter {
            !RunResultsQuery.isSkippedSynthetic($0) && $0.durationMs > 0 && !$0.platform.isEmpty
        }
        let grouped = Dictionary(grouping: usable) {
            Key(scenarioID: $0.scenarioID, platform: $0.platform)
        }
        return grouped.compactMap { key, group -> Duration? in
            var group = group
            if let machine {
                let sameMachine = group.filter { $0.machine == machine }
                if !sameMachine.isEmpty { group = sameMachine }
            }
            guard !group.isEmpty else { return nil }
            return Duration(scenarioID: key.scenarioID, platform: key.platform,
                            medianMs: median(of: group.map { Double($0.durationMs) }))
        }
        // 集計順は Dictionary 由来で不定なので、呼び出し側が決定的に扱えるよう並べておく
        .sorted { $0.scenarioID == $1.scenarioID ? $0.platform < $1.platform
                                                 : $0.scenarioID < $1.scenarioID }
    }

    /// (scenarioID, platform, machine) ごとの中央値。durations(from:) と同じフィルタ
    /// (skipped 合成・durationMs<=0・platform 空を除外)に加え、machine 空の記録も除く
    /// (どの機械の実績か決められない)。FleetSplit.speedFactors / MachineContext が使う。
    public static func machineDurations(from records: [ScenarioRunRecord]) -> [MachineDuration] {
        let usable = records.filter {
            !RunResultsQuery.isSkippedSynthetic($0) && $0.durationMs > 0 && !$0.platform.isEmpty
                && !$0.machine.isEmpty
        }
        let grouped = Dictionary(grouping: usable) {
            MachineKey(scenarioID: $0.scenarioID, platform: $0.platform, machine: $0.machine)
        }
        return grouped.map { key, group in
            MachineDuration(scenarioID: key.scenarioID, platform: key.platform, machine: key.machine,
                            medianMs: median(of: group.map { Double($0.durationMs) }))
        }
        // 集計順は Dictionary 由来で不定なので、呼び出し側が決定的に扱えるよう並べておく
        .sorted {
            if $0.scenarioID != $1.scenarioID { return $0.scenarioID < $1.scenarioID }
            if $0.platform != $1.platform { return $0.platform < $1.platform }
            return $0.machine < $1.machine
        }
    }
}

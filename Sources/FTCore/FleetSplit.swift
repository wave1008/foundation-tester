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

    /// エントリごとの機械情報。すべて entryPlatforms と同じ並び・同じ本数(省略時は全員 nil/0/[])。
    public struct MachineContext: Sendable {
        /// 実績レコードの machine と同じ語彙の識別子。不明なら nil(そのエントリは混合見積りのまま)
        public let entryMachines: [String?]
        /// そのエントリが払うディスパッチ固定費(実測。ローカルは 0)。台数で割らず
        /// 見込み終了時刻へそのまま足す(デバイスが走り出す前の壁時計)。
        /// **durations と同じ単位(ms)であること** —— 実績ゼロで見積りが単位重みへ退化する
        /// 呼び出しは machineContext(_:ifHistoryExists:) で context ごと落とす
        public let entryFixedOffsetsMs: [Double]
        /// LPTScheduler.machineDurations(from:) の出力
        public let machineDurations: [LPTScheduler.MachineDuration]

        public init(entryMachines: [String?], entryFixedOffsetsMs: [Double],
                    machineDurations: [LPTScheduler.MachineDuration]) {
            self.entryMachines = entryMachines
            self.entryFixedOffsetsMs = entryFixedOffsetsMs
            self.machineDurations = machineDurations
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
    /// - entryCapacities: エントリの**同時実行本数**(= 割り当てるデバイス台数)。省略時は全員 1。
    ///   分ける相手が「1ホスト = 1プロファイル」なら台数差は割り当てに現れないが、
    ///   デバイス単位の host 混在(1つの実行プロファイルの中に複数ホストのデバイスが並ぶ形)では
    ///   **台数が違うホストへ同じ量を配ると台数の少ない側が終わらない**。総量ではなく
    ///   「見込み終了時刻 = 負荷合計 / 台数」で比べる。全員同じ値なら比較順序は変わらないので、
    ///   既定(全員 1)の割り当ては従来と1バイトも変わらない
    /// - machineContext: 機械ごとの速度差・ディスパッチ固定費を見積りへ反映する(リモート実行)。
    ///   **投入順(降順ソート)は machineContext の有無によらず混合見積りで決める**
    ///   (機械非依存 = 決定的。エントリごとに順序が割れない)。nil(既定)は従来と完全一致
    ///   (offsets 全 0・machine 全 nil と同じ経路を通る)。
    public static func partition(
        scenarios: [(id: String, platform: String?)],
        durations: [LPTScheduler.Duration],
        entryPlatforms: [Set<String>],
        unknownDurationMs: Double,
        entryCapacities: [Double]? = nil,
        machineContext: MachineContext? = nil
    ) throws -> [Bucket] {
        let capacities = entryCapacities ?? [Double](repeating: 1, count: entryPlatforms.count)
        precondition(capacities.count == entryPlatforms.count,
                     "entryCapacities must line up with entryPlatforms")
        let entryMachines = machineContext?.entryMachines
            ?? [String?](repeating: nil, count: entryPlatforms.count)
        let entryOffsets = machineContext?.entryFixedOffsetsMs
            ?? [Double](repeating: 0, count: entryPlatforms.count)
        precondition(entryMachines.count == entryPlatforms.count,
                     "machineContext.entryMachines must line up with entryPlatforms")
        precondition(entryOffsets.count == entryPlatforms.count,
                     "machineContext.entryFixedOffsetsMs must line up with entryPlatforms")

        let mixedByScenario = maxAcrossPlatform(durations)
        func mixedMs(_ id: String) -> Double { mixedByScenario[id] ?? unknownDurationMs }

        let sameMsByMachine = machineContext.map { maxAcrossPlatformByMachine($0.machineDurations) } ?? [:]
        let factors = machineContext.map {
            speedFactors(machineDurations: $0.machineDurations, durations: durations)
        } ?? [:]

        // エントリ別見積り: 同一機の実績があればそれ、無ければ混合見積り × 速度係数
        // (machine 不明・係数不明はどちらも 1.0 相当 = 混合見積りへ落ちる)
        func estimatedMs(_ id: String, forEntry index: Int) -> Double {
            guard let machine = entryMachines[index] else { return mixedMs(id) }
            if let sameMachineMs = sameMsByMachine[machine]?[id] { return sameMachineMs }
            return mixedMs(id) * (factors[machine] ?? 1.0)
        }

        // 見積り降順、同着は scenario ID 昇順(決定的)。machine 非依存の混合見積りで決める
        let ordered = scenarios.sorted { lhs, rhs in
            let l = mixedMs(lhs.id), r = mixedMs(rhs.id)
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
            // 見込み終了時刻(固定費 + 負荷合計 / 台数)が最小のエントリへ。同着は entryIndex 昇順(決定的)。
            // 固定費は台数で割らない(デバイスが走り出す前の壁時計はデバイス数と無関係)
            func finishIfAssigned(_ index: Int) -> Double {
                entryOffsets[index]
                    + (totals[index] + estimatedMs(scenario.id, forEntry: index)) / max(capacities[index], 1)
            }
            guard let target = fitting.min(by: {
                (finishIfAssigned($0), $0) < (finishIfAssigned($1), $1)
            }) else {
                throw FleetSplitError.noFittingEntry(
                    scenarioID: scenario.id, platform: scenario.platform ?? "ios/android")
            }
            scenarioIDs[target].append(scenario.id)
            totals[target] += estimatedMs(scenario.id, forEntry: target)
        }

        return entryPlatforms.indices.map {
            Bucket(entryIndex: $0, scenarioIDs: scenarioIDs[$0], estimatedMs: totals[$0])
        }
    }

    /// 呼び出し側の共通ガード: **実績が1件も無いときは machineContext を渡さない**。
    /// 実績ゼロだと呼び出し側の unknownDuration は単位重み(1.0。ms ではない)へ退化するが、
    /// entryFixedOffsetsMs は実測ミリ秒のままなので、比較の中で offset が重みを支配して
    /// **facts を持つエントリへは数千本積むまで1本も行かず、全シナリオが facts の無い
    /// エントリ(local)へ寄る**(単位の混在は黙って誤る。2026-08-18 のレビューで検出)。
    /// 実績ゼロなら machineDurations も空で context の効きどころは offset だけなので、
    /// context ごと nil に落とすのが最小で正確
    public static func machineContext(
        _ context: MachineContext, ifHistoryExists durations: [LPTScheduler.Duration]
    ) -> MachineContext? {
        durations.isEmpty ? nil : context
    }

    /// 速度係数(machine → 比の中央値)。「sameMs と混合中央値の両方があるシナリオ」の
    /// sameMs/mixedMs を machine ごとに集め、その中央値を係数とする。共通観測が1本も無い
    /// machine は載らない(呼び出し側は `?? 1.0` で扱う)。分母は unknownDurationMs ではなく
    /// durations の実績中央値だけを使う(実績ゼロのシナリオで係数を作らない)。
    public static func speedFactors(machineDurations: [LPTScheduler.MachineDuration],
                                    durations: [LPTScheduler.Duration]) -> [String: Double] {
        let mixed = maxAcrossPlatform(durations)
        let byMachine = maxAcrossPlatformByMachine(machineDurations)
        var factors: [String: Double] = [:]
        for (machine, sameMsByScenario) in byMachine {
            let ratios = sameMsByScenario.compactMap { scenarioID, sameMs -> Double? in
                guard let mixedMs = mixed[scenarioID], mixedMs > 0 else { return nil }
                return sameMs / mixedMs
            }
            guard !ratios.isEmpty else { continue }
            factors[machine] = median(of: ratios)
        }
        return factors
    }

    /// scenarioID ごとの max-across-platform(大きい方を安全側として採る。partition の
    /// durations 引数の doc コメントと同じ規律)
    private static func maxAcrossPlatform(_ durations: [LPTScheduler.Duration]) -> [String: Double] {
        var result: [String: Double] = [:]
        for duration in durations {
            result[duration.scenarioID] = max(result[duration.scenarioID] ?? 0, duration.medianMs)
        }
        return result
    }

    /// machine → scenarioID → max-across-platform
    private static func maxAcrossPlatformByMachine(
        _ machineDurations: [LPTScheduler.MachineDuration]
    ) -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for duration in machineDurations {
            let existing = result[duration.machine]?[duration.scenarioID] ?? 0
            result[duration.machine, default: [:]][duration.scenarioID] = max(existing, duration.medianMs)
        }
        return result
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

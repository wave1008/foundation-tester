// ResponseMeasurementQuery.swift
// `fleetest results response` の集計(純粋関数)。計測モードの run の `timeline[].response.firstFrameMs` と `readyMs` を
// (シナリオ, ステップ, 機械, デバイス)ごとに束ね、同じ機械・同じデバイスの直前の計測 run と中央値を比べる。
// **全文の ScenarioRunRecord を渡すこと**(RunRecordPack の縮約版は timeline の欄を落とす)。
// RunResultsQuery.swift に置かない: TimelineNotesOnlyScanTests が timeline の notes 以外の読み取りを禁じている。

import Foundation

public enum ResponseMeasurementQuery {

    /// ステップの鍵。実行時の `index` は制御フローでずれるので使わず、同じ (scene, section, command, description) の
    /// 記録内での出現順(1 始まり)で同一視する
    public struct StepKey: Hashable, Codable, Sendable {
        public let scene: Int?
        public let section: String?
        public let command: String?
        public let description: String
        public let occurrence: Int

        /// 例: `s2 action tap Tap login #1`(欄が無いときは `-`)
        public var label: String {
            "\(scene.map { "s\($0)" } ?? "s-") \(section ?? "-") \(command ?? "-") \(description) #\(occurrence)"
        }
    }

    public struct Row: Codable, Sendable, Equatable {
        public let scenarioID: String
        public let step: String
        public let host: String
        public let device: String
        public let runID: String
        public let startedAt: String
        /// firstFrameMs を持つ標本数
        public let n: Int
        public let medianMs: Double?
        public let p90Ms: Double?
        public let busyCount: Int
        /// firstFrameMissing の値(生の文字列)ごとの件数。値の無いステップは数えない
        public let missingCounts: [String: Int]
        /// readyMs(t2)を持つ標本数と中央値・p90。t2 は次の計測ステップの判定で後から入る(最後の計測ステップ等は入らない)
        public let readyN: Int
        public let readyMedianMs: Double?
        public let readyP90Ms: Double?
        /// readyMissing の値(生の文字列)ごとの件数。readyMs が無く値もないステップは数えない
        public let readyMissingCounts: [String: Int]
        public let previousRunID: String?
        public let previousMedianMs: Double?
        public let deltaMs: Double?
        public let deltaPct: Double?
    }

    private struct GroupID: Hashable {
        let scenarioID: String
        let step: StepKey
        let host: String
        let device: String
    }

    private struct Aggregate {
        var samples: [Int] = []
        var busy = 0
        var missing: [String: Int] = [:]
        var readySamples: [Int] = []
        var readyMissing: [String: Int] = [:]
    }

    /// 同一記録内で response を持つステップへ鍵を振る(出現順)
    static func keyedSteps(_ record: ScenarioRunRecord) -> [(key: StepKey, response: ResponseMeasurementRecord)] {
        var seen: [String: Int] = [:]
        var out: [(StepKey, ResponseMeasurementRecord)] = []
        for step in record.timeline ?? [] {
            // 出現順は response を持つステップ同士で数える(計測の有無が混ざる回と混ざらない回でずれない)
            guard let response = step.response else { continue }
            let base = "\(step.scene.map(String.init) ?? "-")\u{1F}\(step.section ?? "-")\u{1F}\(step.command ?? "-")\u{1F}\(step.description)"
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            out.append((StepKey(scene: step.scene, section: step.section, command: step.command,
                                description: step.description, occurrence: count), response))
        }
        return out
    }

    /// 中央値(偶数個は中央2つの平均)。空なら nil
    static func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? Double(sorted[mid]) : Double(sorted[mid - 1] + sorted[mid]) / 2
    }

    /// 計測 run の記録を (シナリオ, ステップ, 機械, デバイス) ごとに集計し、直前の計測 run との差を付ける。
    /// - 対象は `responseMeasurement != nil` の run だけ。デバイスは run の meta の識別(serial ?? deviceName)
    /// - 同じ run の同じシナリオの複数記録(繰り返し)は標本を合算する
    /// - 行は各グループの最新の run のもの。直前 = 同じ (機械, デバイス) でそのグループを持つ1つ前の run(別の機械・デバイスとは比べない)
    /// - 百分位は RunResultsQuery.percentile(最近接順位法)
    public static func rows(runs: [RunMetaRecord], records: [ScenarioRunRecord]) -> [Row] {
        struct RunInfo { let runID: String; let host: String; let device: String; let startedAt: String }
        var infoByRun: [String: RunInfo] = [:]
        for meta in runs {
            guard let info = meta.responseMeasurement else { continue }
            infoByRun[meta.runID] = RunInfo(runID: meta.runID, host: meta.host,
                                            device: info.serial ?? info.deviceName, startedAt: meta.startedAt)
        }
        guard !infoByRun.isEmpty else { return [] }

        // 順序が決定的になるよう、新旧・runID・記録の startedAt で並べてから走査する
        let ordered = records.filter { infoByRun[$0.runID] != nil }.sorted {
            let a = infoByRun[$0.runID]!, b = infoByRun[$1.runID]!
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            if $0.runID != $1.runID { return $0.runID < $1.runID }
            return $0.startedAt < $1.startedAt
        }

        var aggregates: [GroupID: [String: Aggregate]] = [:]   // group -> runID -> 集計
        var order: [String: [StepKey: Int]] = [:]              // scenarioID -> 鍵の初出順
        for record in ordered {
            let info = infoByRun[record.runID]!
            for (key, response) in keyedSteps(record) {
                if order[record.scenarioID, default: [:]][key] == nil {
                    order[record.scenarioID, default: [:]][key] = order[record.scenarioID, default: [:]].count
                }
                let group = GroupID(scenarioID: record.scenarioID, step: key, host: info.host, device: info.device)
                var agg = aggregates[group, default: [:]][record.runID] ?? Aggregate()
                if let ms = response.firstFrameMs { agg.samples.append(ms) }
                if response.busyBeforeAction { agg.busy += 1 }
                if response.firstFrameMs == nil, let reason = response.firstFrameMissing {
                    agg.missing[reason.rawValue, default: 0] += 1
                }
                if let ms = response.readyMs {
                    agg.readySamples.append(ms)
                } else if let reason = response.readyMissing {
                    agg.readyMissing[reason, default: 0] += 1
                }
                aggregates[group, default: [:]][record.runID] = agg
            }
        }

        var built: [(scenario: String, stepOrder: Int, row: Row)] = []
        for (group, byRun) in aggregates {
            let chronological = byRun.keys.compactMap { infoByRun[$0] }.sorted {
                $0.startedAt == $1.startedAt ? $0.runID < $1.runID : $0.startedAt < $1.startedAt
            }
            guard let latest = chronological.last, let agg = byRun[latest.runID] else { continue }
            let previous = chronological.dropLast().last
            let previousMedian = previous.flatMap { byRun[$0.runID] }.flatMap { median($0.samples) }
            let currentMedian = median(agg.samples)
            var deltaMs: Double?
            var deltaPct: Double?
            if let cur = currentMedian, let prev = previousMedian {
                deltaMs = cur - prev
                if prev != 0 { deltaPct = (cur - prev) / prev * 100 }
            }
            let row = Row(
                scenarioID: group.scenarioID, step: group.step.label, host: group.host, device: group.device,
                runID: latest.runID, startedAt: latest.startedAt, n: agg.samples.count,
                medianMs: currentMedian,
                p90Ms: agg.samples.isEmpty ? nil : RunResultsQuery.percentile(agg.samples, 0.9),
                busyCount: agg.busy, missingCounts: agg.missing,
                readyN: agg.readySamples.count, readyMedianMs: median(agg.readySamples),
                readyP90Ms: agg.readySamples.isEmpty ? nil : RunResultsQuery.percentile(agg.readySamples, 0.9),
                readyMissingCounts: agg.readyMissing,
                previousRunID: previous?.runID, previousMedianMs: previousMedian,
                deltaMs: deltaMs, deltaPct: deltaPct)
            built.append((group.scenarioID, order[group.scenarioID]?[group.step] ?? 0, row))
        }
        return built.sorted {
            if $0.scenario != $1.scenario { return $0.scenario < $1.scenario }
            if $0.stepOrder != $1.stepOrder { return $0.stepOrder < $1.stepOrder }
            if $0.row.host != $1.row.host { return $0.row.host < $1.row.host }
            return $0.row.device < $1.row.device
        }.map(\.row)
    }
}

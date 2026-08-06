// RunResultsQuery.swift
// RunResultsStore が読み取った [RunMetaRecord]/[ScenarioRunRecord] を集計する純関数群。
// CLI(ftester results)と vscode 拡張向け api コマンドの双方から再利用するため FTCore に置く。
// 日付は startedAt(ISO8601 文字列)を基準に比較する。パース不能な文字列は distantPast 扱いで
// 落ちないようにする(RunResultsStore 側も同様に不正日時を許容している)。

import Foundation

public enum RunResultsQuery {

    // MARK: - --since 解析

    /// "30d" / "12h"(相対時間、referenceDate 基準)、または "YYYY-MM-DD"(UTC 0時)を Date に変換する。
    /// どちらの形式にも一致しなければ nil(呼び出し側でエラーにすること)
    public static func parseSince(_ raw: String, referenceDate: Date = Date()) -> Date? {
        if let absolute = parseAbsoluteDate(raw) { return absolute }
        return parseRelativeDuration(raw, referenceDate: referenceDate)
    }

    private static func parseAbsoluteDate(_ raw: String) -> Date? {
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    private static func parseRelativeDuration(_ raw: String, referenceDate: Date) -> Date? {
        guard let unitChar = raw.last else { return nil }
        let unitSeconds: TimeInterval
        switch unitChar {
        case "d": unitSeconds = 86400
        case "h": unitSeconds = 3600
        default: return nil
        }
        guard let amount = Double(raw.dropLast()), amount > 0 else { return nil }
        return referenceDate.addingTimeInterval(-amount * unitSeconds)
    }

    // MARK: - 共通ヘルパー

    /// RunRecorder.recordSkipped が書く合成レコード(実行対象外の埋め合わせ)の判定。
    /// duration 集計(平均・中央値・trend バー)からは除外するが、成功率・失敗率には失敗として含める
    public static func isSkippedSynthetic(_ record: ScenarioRunRecord) -> Bool {
        record.steps.total == 1 && record.steps.skipped == 1 && record.durationMs == 0
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static func date(from startedAt: String) -> Date {
        isoFormatter.date(from: startedAt) ?? .distantPast
    }

    private static func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return Double(sorted[mid - 1] + sorted[mid]) / 2
        }
        return Double(sorted[mid])
    }

    private static func average(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    // MARK: - list

    /// runID 降順(新しい順)で先頭 limit 件
    public static func recentRuns(_ runs: [RunMetaRecord], limit: Int) -> [RunMetaRecord] {
        Array(runs.sorted { $0.runID > $1.runID }.prefix(max(0, limit)))
    }

    // MARK: - summary

    public struct ScenarioSummaryRow: Codable, Sendable, Equatable {
        public let scenarioID: String
        public let runs: Int
        /// 0-100
        public let successRate: Double
        /// isSkippedSynthetic を除いた実行のみの平均・中央値。対象が 0 件なら nil
        public let avgDurationMs: Double?
        public let medianDurationMs: Double?
        public let lastRunAt: String?
        public let lastPassed: Bool?
    }

    /// シナリオ別に集計する。成功率昇順(問題のあるものが上)。同率は scenarioID 昇順
    public static func scenarioSummary(_ records: [ScenarioRunRecord]) -> [ScenarioSummaryRow] {
        let grouped = Dictionary(grouping: records, by: \.scenarioID)
        let rows = grouped.map { scenarioID, group -> ScenarioSummaryRow in
            let passedCount = group.filter(\.passed).count
            let successRate = group.isEmpty ? 0 : Double(passedCount) / Double(group.count) * 100
            let durations = group.filter { !isSkippedSynthetic($0) }.map(\.durationMs)
            let latest = group.max { date(from: $0.startedAt) < date(from: $1.startedAt) }
            return ScenarioSummaryRow(
                scenarioID: scenarioID, runs: group.count, successRate: successRate,
                avgDurationMs: average(durations), medianDurationMs: median(durations),
                lastRunAt: latest?.startedAt, lastPassed: latest?.passed)
        }
        return rows.sorted {
            $0.successRate == $1.successRate ? $0.scenarioID < $1.scenarioID
                                              : $0.successRate < $1.successRate
        }
    }

    // MARK: - flaky

    public struct FlakyRow: Codable, Sendable, Equatable {
        public let scenarioID: String
        public let runs: Int
        /// 0-100
        public let failureRate: Double
        /// 隣接実行間の結果遷移回数 / (実行回数 - 1)
        public let flakinessScore: Double
        /// 新しい順、最大 10 件
        public let recentResults: [Bool]
    }

    /// 期間内に pass/fail が混在し、実行回数が minRuns 以上のシナリオを不安定度降順で返す
    public static func flakyScenarios(_ records: [ScenarioRunRecord], minRuns: Int) -> [FlakyRow] {
        let grouped = Dictionary(grouping: records, by: \.scenarioID)
        let rows = grouped.compactMap { scenarioID, group -> FlakyRow? in
            guard group.count >= minRuns else { return nil }
            let chronological = group.sorted { date(from: $0.startedAt) < date(from: $1.startedAt) }
            let passedValues = Set(chronological.map(\.passed))
            guard passedValues.count > 1 else { return nil }  // pass/fail 混在なしは対象外

            var transitions = 0
            for i in 1..<chronological.count where chronological[i].passed != chronological[i - 1].passed {
                transitions += 1
            }
            let flakinessScore = Double(transitions) / Double(chronological.count - 1)
            let failedCount = chronological.filter { !$0.passed }.count
            let failureRate = Double(failedCount) / Double(chronological.count) * 100
            let recentResults = chronological.reversed().prefix(10).map(\.passed)

            return FlakyRow(
                scenarioID: scenarioID, runs: chronological.count, failureRate: failureRate,
                flakinessScore: flakinessScore, recentResults: Array(recentResults))
        }
        return rows.sorted {
            $0.flakinessScore == $1.flakinessScore ? $0.scenarioID < $1.scenarioID
                                                    : $0.flakinessScore > $1.flakinessScore
        }
    }

    // MARK: - trend

    /// 指定シナリオの実行履歴を startedAt 昇順(古い順)で返す
    public static func trend(_ records: [ScenarioRunRecord], scenarioID: String) -> [ScenarioRunRecord] {
        records.filter { $0.scenarioID == scenarioID }
            .sorted { date(from: $0.startedAt) < date(from: $1.startedAt) }
    }

    // MARK: - devices

    public struct DeviceRow: Codable, Sendable, Equatable {
        /// worker 未設定は "(worker不明)"
        public let worker: String
        public let runs: Int
        public let successRate: Double
        public let avgDurationMs: Double?
    }

    public struct PlatformRow: Codable, Sendable, Equatable {
        public let platform: String
        public let runs: Int
        public let successRate: Double
        public let avgDurationMs: Double?
    }

    public struct DevicesReport: Codable, Sendable, Equatable {
        public let byWorker: [DeviceRow]
        public let byPlatform: [PlatformRow]
    }

    private static let unknownWorkerLabel = "(unknown worker)"

    public static func deviceSummary(_ records: [ScenarioRunRecord]) -> DevicesReport {
        func aggregate<Key: Hashable>(
            _ records: [ScenarioRunRecord], key: (ScenarioRunRecord) -> Key
        ) -> [(Key, Int, Double, Double?)] {
            let grouped = Dictionary(grouping: records, by: key)
            return grouped.map { groupKey, group in
                let passedCount = group.filter(\.passed).count
                let successRate = group.isEmpty ? 0 : Double(passedCount) / Double(group.count) * 100
                let durations = group.filter { !isSkippedSynthetic($0) }.map(\.durationMs)
                return (groupKey, group.count, successRate, average(durations))
            }
        }

        let byWorker = aggregate(records) { $0.worker ?? unknownWorkerLabel }
            .map { DeviceRow(worker: $0.0, runs: $0.1, successRate: $0.2, avgDurationMs: $0.3) }
            .sorted { $0.worker < $1.worker }

        let byPlatform = aggregate(records) { $0.platform }
            .map { PlatformRow(platform: $0.0, runs: $0.1, successRate: $0.2, avgDurationMs: $0.3) }
            .sorted { $0.platform < $1.platform }

        return DevicesReport(byWorker: byWorker, byPlatform: byPlatform)
    }

    // MARK: - daily

    /// vscode 拡張ダッシュボードの日別グラフ用。フィールド名は
    /// vscode-ftester/src/dashboardModel.ts と同期
    public struct DailyRow: Codable, Sendable, Equatable {
        public let date: String
        public let total: Int
        public let passed: Int
        public let failed: Int
    }

    /// startedAt を timeZone 基準の日付("yyyy-MM-dd")に丸めて集計し date 昇順で返す。
    /// パース不能な startedAt は date(from:) と同じく distantPast 扱いの日付にまとめる
    public static func dailyRates(_ records: [ScenarioRunRecord], timeZone: TimeZone = .current) -> [DailyRow] {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        let grouped = Dictionary(grouping: records) { record in
            dayFormatter.string(from: date(from: record.startedAt))
        }
        let rows = grouped.map { dateKey, group -> DailyRow in
            let passedCount = group.filter(\.passed).count
            return DailyRow(
                date: dateKey, total: group.count, passed: passedCount,
                failed: group.count - passedCount)
        }
        return rows.sorted { $0.date < $1.date }
    }

    // MARK: - slow

    /// deltaPct を計算する最小実行回数(未満は前半/後半比較が意味を持たないため nil)
    private static let slowTestsMinRunsForDelta = 4

    public struct SlowTestRow: Codable, Sendable, Equatable {
        public let scenarioID: String
        public let runs: Int
        public let avgDurationMs: Double
        public let p90DurationMs: Double
        /// 時系列で前半平均→後半平均の変化率(%)。実行 4 回未満は nil
        public let deltaPct: Double?
        /// scene 平均所要時間が最大の scene タイトルとその平均(scene データが無ければ nil)
        public let slowestScene: String?
        public let slowestSceneAvgMs: Double?
    }

    /// avgDurationMs 降順。isSkippedSynthetic は除外
    public static func slowTests(_ records: [ScenarioRunRecord], limit: Int) -> [SlowTestRow] {
        let grouped = Dictionary(grouping: records.filter { !isSkippedSynthetic($0) }, by: \.scenarioID)
        let rows = grouped.compactMap { scenarioID, group -> SlowTestRow? in
            let chronological = group.sorted { date(from: $0.startedAt) < date(from: $1.startedAt) }
            let durations = chronological.map(\.durationMs)
            guard let avg = average(durations) else { return nil }
            let (slowestScene, slowestSceneAvgMs) = slowestSceneInfo(chronological)
            return SlowTestRow(
                scenarioID: scenarioID, runs: chronological.count, avgDurationMs: avg,
                p90DurationMs: percentile(durations, 0.9), deltaPct: durationDeltaPct(chronological),
                slowestScene: slowestScene, slowestSceneAvgMs: slowestSceneAvgMs)
        }
        return Array(rows.sorted {
            $0.avgDurationMs == $1.avgDurationMs ? $0.scenarioID < $1.scenarioID : $0.avgDurationMs > $1.avgDurationMs
        }.prefix(max(0, limit)))
    }

    /// 実行回数を前半(floor)・後半(残り)に分けた平均の変化率。前半平均が 0 なら比率が発散するため nil
    private static func durationDeltaPct(_ chronological: [ScenarioRunRecord]) -> Double? {
        guard chronological.count >= slowTestsMinRunsForDelta else { return nil }
        let durations = chronological.map(\.durationMs)
        let mid = durations.count / 2
        guard let firstAvg = average(Array(durations[0..<mid])), firstAvg > 0,
              let secondAvg = average(Array(durations[mid...])) else { return nil }
        return (secondAvg - firstAvg) / firstAvg * 100
    }

    /// scene タイトルごとの平均 durationMs が最大のものを返す(同値はタイトル昇順で決定的に選ぶ)
    private static func slowestSceneInfo(_ records: [ScenarioRunRecord]) -> (String?, Double?) {
        var byTitle: [String: [Int]] = [:]
        for record in records {
            for scene in record.scenes {
                guard let duration = scene.durationMs else { continue }
                byTitle[scene.title, default: []].append(duration)
            }
        }
        let candidates = byTitle.compactMap { title, durations -> (String, Double)? in
            average(durations).map { (title, $0) }
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        guard let top = candidates.first else { return (nil, nil) }
        return (top.0, top.1)
    }

    /// 最近接順位法(nearest-rank)。values が空なら 0
    private static func percentile(_ values: [Int], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return Double(sorted[index])
    }

    // MARK: - insights

    /// 直近何回連続 fail から consecutiveFailures とするか
    private static let consecutiveFailureThreshold = 3
    /// newFailure: 単発 fail の直前に何回連続 pass があれば回帰疑いとするか
    private static let newFailurePriorPassThreshold = 3
    /// infraFailures: timedOut またはステップ未到達失敗がシナリオあたり何件以上で警告するか
    private static let infraFailureMinCount = 2
    /// selectorDecay: steps.healed + passedViaFallback の合計がシナリオあたり何件以上で警告するか。
    /// **これだけでは判定しない**(下の傾向条件と AND)—— 合計は窓の中で増え続けるので、
    /// 単独だと「毎回1件フォールバックするシナリオ」が 3 run 目から永久に鳴る
    private static let selectorDecayMinCount = 3
    /// selectorDecay: 前半/後半の比較に要る最小 run 数(slowTestsMinRunsForDelta と同じ理由)
    private static let selectorDecayMinRunsForTrend = 4
    /// selectorDecay: 1 run あたりの件数が前半→後半でこの割合(%)以上増えたら「劣化」とみなす。
    /// **一定なら劣化ではない** —— フォールバックや自己修復を意図的に検証するシナリオは
    /// 毎 run 同じ件数を出す(実測: 2118 run で 2107 件 = 1件/run が2週間一定)
    private static let selectorDecayRisePct = 30.0
    /// retiredScenarios: 最新の記録からこの日数より前にしか記録が無いシナリオは
    /// 「実行されなくなった」とみなし、per-scenario の検知から外す
    private static let retiredScenarioDays = 7.0
    /// deviceBias: 対象 worker の最小実行回数(サンプル数が少ない偏り判定を避ける)
    private static let deviceBiasMinRunsPerWorker = 3
    /// deviceBias: シナリオ全体の失敗率に対してこの倍率以上なら偏りありと判定
    private static let deviceBiasRatioMultiplier = 2.0
    /// deviceBias: 対象にするシナリオの最小 worker 種類数(単一 worker では偏りを判定できない)
    private static let deviceBiasMinWorkerKinds = 2
    /// durationRegression: slowTests の deltaPct(%)がこの値以上で悪化とみなす
    private static let durationRegressionPct = 30.0
    /// unfinishedRuns: finishedAt 欠落 run がこの件数以上で info を出す
    private static let unfinishedRunsMinCount = 1
    /// unsettledSteps: 判定に要る最小 run 数(1〜2 run では整定の打ち切りは環境雑音と区別できない)
    private static let unsettledMinRuns = 3
    /// unsettledSteps: 整定打ち切りを含む run の割合がこれ以上で警告。**緑の run も母数に入れる** ——
    /// これは失敗の集計ではなく「赤になる前の先行指標」なので、通っている run こそ見たい
    private static let unsettledRunRatio = 0.3

    public struct InsightRow: Codable, Sendable, Equatable {
        /// "newFailure" | "consecutiveFailures" | "infraFailures" | "selectorDecay" | "deviceBias" |
        /// "durationRegression" | "unfinishedRuns" | "unsettledSteps" | "retiredScenarios"
        public let kind: String
        /// "critical" | "warn" | "info"
        public let severity: String
        public let scenarioID: String?
        public let worker: String?
        public let message: String
        public let count: Int?
        public let deltaPct: Double?
    }

    /// severity 順(critical→warn→info)、同 severity 内は count 降順(同数は kind→scenarioID 昇順で決定的に)
    public static func insights(records: [ScenarioRunRecord], runs: [RunMetaRecord]) -> [InsightRow] {
        var rows: [InsightRow] = []
        // **実行されなくなったシナリオを先に外す**。--since の窓に古い記録が残るかぎり、
        // 削除・_disabled 化されたシナリオの「末尾の失敗」は永久に critical を出し続け、
        // severity 順の先頭を占めて本物を押し下げる(実測: 12 行中 5 行がこれだった)
        let (records, retiredIDs) = partitionRetired(records)
        let grouped = Dictionary(grouping: records, by: \.scenarioID)

        for (scenarioID, group) in grouped {
            let chronological = group.sorted { date(from: $0.startedAt) < date(from: $1.startedAt) }
            rows.append(contentsOf: failureStreakInsights(scenarioID: scenarioID, chronological: chronological))
            rows.append(contentsOf: infraFailureInsights(scenarioID: scenarioID, chronological: chronological))
            if let row = selectorDecayInsight(scenarioID: scenarioID, group: group) {
                rows.append(row)
            }
            rows.append(contentsOf: deviceBiasInsights(scenarioID: scenarioID, group: group))
            if let row = unsettledStepsInsight(scenarioID: scenarioID, group: group) {
                rows.append(row)
            }
        }

        for row in slowTests(records, limit: .max) {
            guard let deltaPct = row.deltaPct, deltaPct >= durationRegressionPct else { continue }
            rows.append(InsightRow(
                kind: "durationRegression", severity: "warn", scenarioID: row.scenarioID, worker: nil,
                message: "\(row.scenarioID): duration regressed (+\(String(format: "%.0f", deltaPct))% vs the first half)",
                count: nil, deltaPct: deltaPct))
        }

        // **黙って落とさない**: 外した事実は出す(消えたシナリオの結果が残っていること自体が情報)
        if !retiredIDs.isEmpty {
            rows.append(InsightRow(
                kind: "retiredScenarios", severity: "info", scenarioID: nil, worker: nil,
                message: "\(retiredIDs.count) scenario(s) have results but are no longer being run"
                    + " (excluded from the checks above): \(retiredIDs.prefix(3).joined(separator: ", "))"
                    + (retiredIDs.count > 3 ? ", …" : ""),
                count: retiredIDs.count, deltaPct: nil))
        }

        let unfinishedCount = runs.filter { $0.finishedAt == nil }.count
        if unfinishedCount >= unfinishedRunsMinCount {
            rows.append(InsightRow(
                kind: "unfinishedRuns", severity: "info", scenarioID: nil, worker: nil,
                message: "\(unfinishedCount) incomplete run(s) (possible crash or force-quit)",
                count: unfinishedCount, deltaPct: nil))
        }

        return rows.sorted { lhs, rhs in
            let lhsRank = severityRank(lhs.severity), rhsRank = severityRank(rhs.severity)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsCount = lhs.count ?? 0, rhsCount = rhs.count ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return (lhs.scenarioID ?? "") < (rhs.scenarioID ?? "")
        }
    }

    // MARK: - matrix

    public struct MatrixRunColumn: Codable, Sendable, Equatable {
        public let runID: String
        public let startedAt: String
        public let profile: String?
    }

    public struct MatrixScenarioRow: Codable, Sendable, Equatable {
        public let scenarioID: String
        public let title: String?
        /// runs と同順・同数。1=passed 0=failed null=その run にこのシナリオの記録が無い
        public let cells: [Int?]
    }

    public struct MatrixReport: Codable, Sendable, Equatable {
        public let runs: [MatrixRunColumn]
        public let scenarios: [MatrixScenarioRow]
    }

    private struct MatrixKey: Hashable {
        let runID: String
        let scenarioID: String
    }

    /// シナリオ×直近 limit run の成否マトリクス。total==nil/0 の run(未完了・0件実行)は窓の対象外。
    /// (runID, scenarioID) が複数レコードを持つ場合(RunRecorder の ~2 リトライ)は startedAt 最新を採用。
    /// 出力順: flaky(pass/fail混在)→ all-fail → all-pass、各グループ内は scenarioID 昇順
    public static func matrix(records: [ScenarioRunRecord], runs: [RunMetaRecord], limit: Int) -> MatrixReport {
        guard limit > 0 else { return MatrixReport(runs: [], scenarios: []) }

        let window = runs
            .filter { ($0.total ?? 0) != 0 }
            .sorted { date(from: $0.startedAt) > date(from: $1.startedAt) }
            .prefix(limit)
        guard !window.isEmpty else { return MatrixReport(runs: [], scenarios: []) }

        let windowRunIDs = Set(window.map(\.runID))
        var latestByKey: [MatrixKey: ScenarioRunRecord] = [:]
        for record in records where windowRunIDs.contains(record.runID) {
            let key = MatrixKey(runID: record.runID, scenarioID: record.scenarioID)
            if let existing = latestByKey[key] {
                if date(from: record.startedAt) > date(from: existing.startedAt) {
                    latestByKey[key] = record
                }
            } else {
                latestByKey[key] = record
            }
        }

        var latestTitle: [String: (title: String?, date: Date)] = [:]
        for record in records {
            let recordDate = date(from: record.startedAt)
            if let existing = latestTitle[record.scenarioID] {
                if recordDate > existing.date {
                    latestTitle[record.scenarioID] = (record.title, recordDate)
                }
            } else {
                latestTitle[record.scenarioID] = (record.title, recordDate)
            }
        }

        let runColumns = window.map { MatrixRunColumn(runID: $0.runID, startedAt: $0.startedAt, profile: $0.profile) }
        let scenarioIDs = Set(records.map(\.scenarioID))

        var flakyRows: [MatrixScenarioRow] = []
        var allFailRows: [MatrixScenarioRow] = []
        var allPassRows: [MatrixScenarioRow] = []

        for scenarioID in scenarioIDs {
            let cells: [Int?] = window.map { run in
                guard let record = latestByKey[MatrixKey(runID: run.runID, scenarioID: scenarioID)] else { return nil }
                return record.passed ? 1 : 0
            }
            let nonNilCells = cells.compactMap { $0 }
            guard !nonNilCells.isEmpty else { continue }
            let row = MatrixScenarioRow(scenarioID: scenarioID, title: latestTitle[scenarioID]?.title, cells: cells)
            let hasPass = nonNilCells.contains(1)
            let hasFail = nonNilCells.contains(0)
            if hasPass && hasFail {
                flakyRows.append(row)
            } else if hasFail {
                allFailRows.append(row)
            } else {
                allPassRows.append(row)
            }
        }

        func sortedByScenarioID(_ rows: [MatrixScenarioRow]) -> [MatrixScenarioRow] {
            rows.sorted { $0.scenarioID < $1.scenarioID }
        }

        return MatrixReport(
            runs: runColumns,
            scenarios: sortedByScenarioID(flakyRows) + sortedByScenarioID(allFailRows) + sortedByScenarioID(allPassRows))
    }

    private static func severityRank(_ severity: String) -> Int {
        switch severity {
        case "critical": return 0
        case "warn": return 1
        default: return 2
        }
    }

    /// 末尾から同じ passed 値が連続する長さを返す(空配列なら (true, 0))
    private static func trailingStreak(_ passedFlags: [Bool]) -> (passed: Bool, length: Int) {
        guard let last = passedFlags.last else { return (true, 0) }
        var length = 0
        for flag in passedFlags.reversed() {
            if flag != last { break }
            length += 1
        }
        return (passed: last, length: length)
    }

    /// newFailure/consecutiveFailures は末尾の fail 連続長で排他的に決まる(2 件目以降は重複しない)
    private static func failureStreakInsights(
        scenarioID: String, chronological: [ScenarioRunRecord]
    ) -> [InsightRow] {
        let streak = trailingStreak(chronological.map(\.passed))
        guard !streak.passed else { return [] }

        if streak.length >= consecutiveFailureThreshold {
            return [InsightRow(
                kind: "consecutiveFailures", severity: "critical", scenarioID: scenarioID, worker: nil,
                message: "\(scenarioID): failed the last \(streak.length) run(s) in a row", count: streak.length, deltaPct: nil)]
        }
        guard streak.length == 1 else { return [] }
        let priorStreak = trailingStreak(chronological.dropLast().map(\.passed))
        guard priorStreak.passed, priorStreak.length >= newFailurePriorPassThreshold else { return [] }
        return [InsightRow(
            kind: "newFailure", severity: "critical", scenarioID: scenarioID, worker: nil,
            message: "\(scenarioID): failed after \(priorStreak.length) consecutive passes (possible regression)",
            count: priorStreak.length, deltaPct: nil)]
    }

    private static func isInfraFailure(_ record: ScenarioRunRecord) -> Bool {
        if record.timedOut == true { return true }
        let noFailedSteps = record.failedSteps?.isEmpty ?? true
        let hasErrorLogs = !(record.errorLogs?.isEmpty ?? true)
        return noFailedSteps && hasErrorLogs
    }

    private static func infraFailureInsights(
        scenarioID: String, chronological: [ScenarioRunRecord]
    ) -> [InsightRow] {
        let failedRecords = chronological.filter { !$0.passed }
        let infraFailures = failedRecords.filter(isInfraFailure)
        guard infraFailures.count >= infraFailureMinCount else { return [] }
        let assertionCount = failedRecords.count - infraFailures.count
        return [InsightRow(
            kind: "infraFailures", severity: "warn", scenarioID: scenarioID, worker: nil,
            message: "\(scenarioID): \(infraFailures.count) infrastructure-caused failure(s) (bridge/device/timeout)"
                + " (vs \(assertionCount) assertion-caused)",
            count: infraFailures.count, deltaPct: nil)]
    }

    /// セレクタの劣化は「**増えていること**」でしか判定できない。合計だけを見ると、
    /// フォールバックや自己修復を意図的に検証するシナリオ(このリポジトリの
    /// `セレクタの型と序数とフォールバックが解決できること` 等)が毎 run 同じ件数を出すため、
    /// 3 run 目から永久に鳴り続けて一覧を埋める。1 run あたりの件数を前半/後半で比べる。
    private static func selectorDecayInsight(scenarioID: String, group: [ScenarioRunRecord]) -> InsightRow? {
        let chronological = group.sorted { date(from: $0.startedAt) < date(from: $1.startedAt) }
        let counts = chronological.map { $0.steps.healed + $0.steps.passedViaFallback }
        let total = counts.reduce(0, +)
        guard total >= selectorDecayMinCount, counts.count >= selectorDecayMinRunsForTrend else { return nil }
        let mid = counts.count / 2
        guard let firstAvg = average(Array(counts[0..<mid])),
              let secondAvg = average(Array(counts[mid...])) else { return nil }
        // 前半 0 = **無かったものが出始めた**。比率が発散するので率は出さず、これ自体を合図にする。
        // このとき後半が 0 でないことは selectorDecayMinCount(合計 >= 3)が担保する
        // ——「減っている」「一定」は下の閾値で落ちるので、ここで別途 secondAvg > firstAvg を見ない
        // (見ても到達しない条件になり、テストで守れない枝が増えるだけ)
        let deltaPct: Double? = firstAvg > 0 ? (secondAvg - firstAvg) / firstAvg * 100 : nil
        if let deltaPct, deltaPct < selectorDecayRisePct { return nil }
        let trend = deltaPct.map { "+\(String(format: "%.0f", $0))% per run" }
            ?? "newly appeared"
        return InsightRow(
            kind: "selectorDecay", severity: "warn", scenarioID: scenarioID, worker: nil,
            message: "\(scenarioID): reliance on self-heal/fallback is growing (\(trend), \(total) time(s) total)",
            count: total, deltaPct: deltaPct)
    }

    /// 実行されなくなったシナリオ(結果だけが results/ に残っている)を分ける。
    /// 判定は**最新の記録からの相対**にする —— 絶対時刻だと、しばらく回していない
    /// プロジェクトの全シナリオが一斉に retired になる
    private static func partitionRetired(
        _ records: [ScenarioRunRecord]
    ) -> (live: [ScenarioRunRecord], retired: [String]) {
        guard let newest = records.map({ date(from: $0.startedAt) }).max() else { return (records, []) }
        let cutoff = newest.addingTimeInterval(-retiredScenarioDays * 86400)
        var live: [ScenarioRunRecord] = []
        var retired: [String] = []
        for (scenarioID, group) in Dictionary(grouping: records, by: \.scenarioID) {
            if let last = group.map({ date(from: $0.startedAt) }).max(), last < cutoff {
                retired.append(scenarioID)
            } else {
                live.append(contentsOf: group)
            }
        }
        return (live, retired.sorted())
    }

    /// 整定の収束判定が打ち切られたまま先へ進んだステップの**出現率**(赤になる前の先行指標)。
    ///
    /// 数えるのは `TimelineStepRecord.notes` のコードだけで、説明文は見ない(StepNote の doc)。
    /// **notes を持たない旧レコードは 0 件として数える** = 率が下がる側 ==
    /// 「まだ測れていない」を「異常あり」と言わない側に倒れる(過小報告は安全・過剰報告は害)。
    /// timeline が無い記録も同じ扱い。
    private static func unsettledStepsInsight(scenarioID: String,
                                              group: [ScenarioRunRecord]) -> InsightRow? {
        guard group.count >= unsettledMinRuns else { return nil }
        let affected = group.filter { record in
            record.timeline?.contains { $0.notes?.contains(StepNote.settleCapped.rawValue) == true } == true
        }
        guard !affected.isEmpty else { return nil }
        let ratio = Double(affected.count) / Double(group.count)
        guard ratio >= unsettledRunRatio else { return nil }
        let steps = affected.reduce(0) { total, record in
            total + (record.timeline?.filter {
                $0.notes?.contains(StepNote.settleCapped.rawValue) == true
            }.count ?? 0)
        }
        return InsightRow(
            kind: "unsettledSteps", severity: "warn", scenarioID: scenarioID, worker: nil,
            message: "\(scenarioID): the screen was still moving when \(steps) step(s) went ahead"
                + " (in \(affected.count)/\(group.count) runs; a leading indicator of flakiness)",
            count: steps, deltaPct: nil)
    }

    private static func deviceBiasInsights(scenarioID: String, group: [ScenarioRunRecord]) -> [InsightRow] {
        let byWorker = Dictionary(grouping: group.filter { $0.worker != nil }) { $0.worker! }
        guard byWorker.count >= deviceBiasMinWorkerKinds else { return [] }

        let overallFailureRate = Double(group.filter { !$0.passed }.count) / Double(group.count)
        guard overallFailureRate > 0 else { return [] }

        return byWorker.sorted { $0.key < $1.key }.compactMap { worker, workerRecords -> InsightRow? in
            guard workerRecords.count >= deviceBiasMinRunsPerWorker else { return nil }
            let workerFailed = workerRecords.filter { !$0.passed }.count
            let workerFailureRate = Double(workerFailed) / Double(workerRecords.count)
            guard workerFailureRate >= overallFailureRate * deviceBiasRatioMultiplier else { return nil }
            return InsightRow(
                kind: "deviceBias", severity: "warn", scenarioID: scenarioID, worker: worker,
                message: "\(scenarioID): failures cluster on \(worker) (its failure rate is "
                    + "\(String(format: "%.0f", workerFailureRate * 100))% vs overall"
                    + "\(String(format: "%.0f", overallFailureRate * 100))%)",
                count: workerFailed, deltaPct: nil)
        }
    }
}

// RunResultsQuery.swift
// RunResultsStore が読み取った [RunMetaRecord]/[ScenarioRunRecord] を集計する純関数群。
// CLI(fleetest results)と vscode 拡張向け api コマンドの双方から再利用するため FTCore に置く。
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

    /// ISO8601 パース(ICU)は1回あたり数µs〜十µs掛かり、この関数は**ソートの比較器の中**から
    /// 呼ばれる(= 同じ文字列を n log n 回パースする)。メモ化しないと 90 日窓の集計が
    /// パースだけで数十秒になる(実測: E2E-CMP 84s → メモ化で解消)。
    /// キャッシュは (プロセス内の distinct startedAt 数) でしか育たないので上限は設けない
    private static let dateCacheLock = NSLock()
    private static var dateCache: [String: Date] = [:]

    private static func date(from startedAt: String) -> Date {
        dateCacheLock.lock()
        defer { dateCacheLock.unlock() }
        if let cached = dateCache[startedAt] { return cached }
        let parsed = isoFormatter.date(from: startedAt) ?? .distantPast
        dateCache[startedAt] = parsed
        return parsed
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
    /// vscode-fleetest/src/dashboardModel.ts と同期
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
    /// healReliance: 同じセレクタの修正提案が何 run 続いたら警告するか。
    /// **提案が出るのは自己修復かヒールキャッシュで「通った」ときだけ**なので、これは
    /// 「緑だがセレクタは壊れている」状態が続いている run 数そのもの
    private static let healRelianceMinRuns = 3
    /// retiredScenarios: 最新の記録からこの日数より前にしか記録が無いシナリオは
    /// 「実行されなくなった」とみなし、per-scenario の検知から外す
    private static let retiredScenarioDays = 7.0
    /// deviceBias: 対象 worker の最小実行回数(サンプル数が少ない偏り判定を避ける)。
    /// **3 では足りなかった** —— 3 run 中 1 失敗で 33% になり、全体 4% の 2 倍を軽く超える。
    /// 実データで 69 行出ていたうちの大半がこれと、worker ラベルの旧形式(1〜3 run しか無い)だった
    private static let deviceBiasMinRunsPerWorker = 10
    /// deviceBias: その worker での最小失敗**回数**。率だけだと単発の失敗が偏りに化ける。
    /// 実データでの行数: (10 run, 1 回)=59 / (10, 3)=20 / (10, 5)=**7** / (20, 5)=4。
    /// 生き残った 7 行はいずれも 5 失敗以上で全体率の 2〜50 倍
    private static let deviceBiasMinFailures = 5
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
        /// "durationRegression" | "unfinishedRuns" | "unsettledSteps" | "retiredScenarios" |
        /// "healReliance"
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
    /// definedClasses: **今もソースに在る** @TestClass のクラス名(ScenarioFolders.classFileMap の
    /// キー。_disabled/ は除外される)。渡すと「消えたシナリオ」を日数の推測ではなく確実に判定できる。
    /// nil または空 = 供給されていない(走査に失敗した等)ので日数だけで判定する ——
    /// **空集合を「全部消えた」と読まない**(全シナリオが retired になり、検知が丸ごと黙る)
    public static func insights(records: [ScenarioRunRecord], runs: [RunMetaRecord],
                                definedClasses: Set<String>? = nil) -> [InsightRow] {
        var rows: [InsightRow] = []
        // **実行されなくなったシナリオを先に外す**。--since の窓に古い記録が残るかぎり、
        // 削除・_disabled 化されたシナリオの「末尾の失敗」は永久に critical を出し続け、
        // severity 順の先頭を占めて本物を押し下げる(実測: 12 行中 5 行がこれだった)
        let (records, retiredIDs) = partitionRetired(records, definedClasses: definedClasses)
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
            rows.append(contentsOf: healRelianceInsights(scenarioID: scenarioID, group: group))
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

    // MARK: - triage

    public struct TriageRow: Codable, Sendable, Equatable {
        public let section: String?
        public let command: String?
        public let failureKind: String?
        public let count: Int
        public let scenarioCount: Int
        /// distinct・昇順・例示用に最大5件
        public let scenarioIDs: [String]
    }

    public struct NoteCountRow: Codable, Sendable, Equatable {
        public let note: String
        public let count: Int
    }

    public struct TriageReport: Codable, Sendable, Equatable {
        public let totalFailed: Int
        /// failedSteps が nil/空(ステップ未到達)。rows には含めない
        public let unreachedCount: Int
        public let rows: [TriageRow]
        public let noteCounts: [NoteCountRow]
    }

    private struct TriageKey: Hashable {
        let section: String?
        let command: String?
        let failureKind: String?
    }

    /// グループ鍵は failedSteps.first の (section, command, failureKind)。
    /// nil は「丸めず」別グループのまま保つ(CLAUDE.md「失敗の記録に置くのは事実だけ」)
    public static func triage(_ records: [ScenarioRunRecord]) -> TriageReport {
        let failed = records.filter { !$0.passed }
        var unreachedCount = 0
        var byKey: [TriageKey: [ScenarioRunRecord]] = [:]
        var noteCounts: [String: Int] = [:]

        for record in failed {
            let steps = record.failedSteps ?? []
            for step in steps {
                for note in step.notes ?? [] {
                    noteCounts[note, default: 0] += 1
                }
            }
            guard let first = steps.first else {
                unreachedCount += 1
                continue
            }
            let key = TriageKey(section: first.section, command: first.command, failureKind: first.failureKind)
            byKey[key, default: []].append(record)
        }

        let rows = byKey.map { key, group -> TriageRow in
            let scenarioIDs = Set(group.map(\.scenarioID)).sorted()
            return TriageRow(
                section: key.section, command: key.command, failureKind: key.failureKind,
                count: group.count, scenarioCount: scenarioIDs.count,
                scenarioIDs: Array(scenarioIDs.prefix(5)))
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if (lhs.section ?? "") != (rhs.section ?? "") { return (lhs.section ?? "") < (rhs.section ?? "") }
            if (lhs.command ?? "") != (rhs.command ?? "") { return (lhs.command ?? "") < (rhs.command ?? "") }
            return (lhs.failureKind ?? "") < (rhs.failureKind ?? "")
        }

        let noteRows = noteCounts.map { NoteCountRow(note: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.note < rhs.note
            }

        return TriageReport(
            totalFailed: failed.count, unreachedCount: unreachedCount, rows: rows, noteCounts: noteRows)
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

    // MARK: - runStats

    /// 直近の実行一覧に添える per-run の時間統計(壁時計・テスト時間)。
    /// テスト時間の**端点も配る** —— 表示はフリート実行(runGroup)単位に畳むが、畳むのは
    /// クライアント側なので、所要(長さ)だけだとグループの窓(min 開始〜max 完了)を合成できない
    public struct RunStatsRow: Codable, Sendable, Equatable {
        public let runID: String
        /// startedAt〜finishedAt(ms)。未完了・パース不能なら nil
        public let wallClockMs: Int?
        /// 最初のシナリオ開始 / 最後のシナリオ完了(ISO8601)。レコード0件なら nil
        public let testStartedAt: String?
        public let testFinishedAt: String?
        public let testTimeMs: Int?
        /// シナリオ所要合計(ms)。isSkippedSynthetic は除外
        public let scenarioTotalMs: Int
        /// 同・レコード数
        public let scenarioCount: Int
        /// distinct worker 数(1 run = 1機械なので host は畳み込み不要。グループのレーン数は合算)
        public let laneCount: Int
        /// 最長1本(= test time の下限)。レコード0件なら nil
        public let maxScenarioMs: Int?
        public let maxScenarioID: String?
    }

    public static func runStats(runs: [RunMetaRecord], records: [ScenarioRunRecord]) -> [RunStatsRow] {
        let byRunID = Dictionary(grouping: records.filter { !isSkippedSynthetic($0) }, by: \.runID)
        let formatter = ISO8601DateFormatter()
        return runs.map { run in
            let scoped = byRunID[run.runID] ?? []
            let spans = scoped.compactMap { record -> (start: Date, end: Date)? in
                let start = date(from: record.startedAt)
                guard start != .distantPast else { return nil }
                return (start, start.addingTimeInterval(Double(record.durationMs) / 1000))
            }
            let testStart = spans.map(\.start).min()
            let testEnd = spans.map(\.end).max()
            let testTime = testStart.flatMap { start in
                testEnd.map { Int(($0.timeIntervalSince(start) * 1000).rounded()) }
            }
            return RunStatsRow(
                runID: run.runID,
                wallClockMs: perfGroupWallClockMs([run]),
                testStartedAt: testStart.map(formatter.string(from:)),
                testFinishedAt: testEnd.map(formatter.string(from:)),
                testTimeMs: testTime,
                scenarioTotalMs: scoped.reduce(0) { $0 + $1.durationMs },
                scenarioCount: scoped.count,
                laneCount: Set(scoped.compactMap(\.worker)).count,
                maxScenarioMs: perfMaxScenario(scoped)?.ms,
                maxScenarioID: perfMaxScenario(scoped)?.id)
        }
    }

    // MARK: - performance

    /// パフォーマンス一覧の1行 = **1つの実行**。フリート計測は機械ごとに別 run(別 runID)に
    /// なるが同じ実行なので、runGroup で1行に畳む(単機 run は自分1つのグループ)
    public struct PerfRunRow: Codable, Sendable, Equatable {
        /// グループ鍵(runGroup。単機 run はその runID)
        public let runID: String
        /// 畳んだ run の全 runID(昇順)
        public let runIDs: [String]
        public let startedAt: String
        public let profile: String?
        /// hosts の先頭(単機 run では従来どおりその host)。表示は hosts を使う
        public let host: String
        /// グループ内の全機械のホスト名(昇順・distinct)。表示は machine へ読み替える
        public let hosts: [String]
        /// finishedAt - startedAt(ms)。どちらか欠落・パース不能なら nil
        public let wallClockMs: Int?
        /// テスト時間(ms): 最初のシナリオ開始〜最後のシナリオ完了。CLI が run 末尾に出す
        /// test time に相当し、壁時計との差 = 供給・準備のオーバーヘッド。レコード0件なら nil
        public let testTimeMs: Int?
        /// この run のシナリオ所要合計(ms)。isSkippedSynthetic は除外
        public let scenarioTotalMs: Int
        /// 同・レコード数(isSkippedSynthetic 除外)
        public let scenarioCount: Int
        public let passed: Int?
        public let failed: Int?
        /// test time の下限 = 最長1本(これ以上レーンを増やしても速くならない)。レコード0件なら nil
        public let maxScenarioMs: Int?
        public let maxScenarioID: String?
        /// distinct **(host, worker)** の数(worker nil のレコードは数えない)。worker 単独で
        /// 数えないこと —— デバイス論理名は機械ごとに付くので、別々の機械の同名レーンが1本に潰れる
        public let laneCount: Int
        /// ProfileRunner が run 末尾に出す Lane utilisation の記録版に相当する近似(シナリオ所要ベース)。
        /// scenarioTotalMs / **Σ機械ごとの(レーン数 × その機械のテスト時間窓)** × 100。
        /// **分母は壁時計にしない**(供給待ちで膨らみ、実測 87% が 17% に見えた)し、
        /// **グループ全体の窓×全レーンにもしない**(機械の開始ずれが「全レーンの遊び」に化けて
        /// フリート計測で 16.7% に見えた。どちらも 2026-09-01 実データ)。
        /// 単機グループでは従来(laneCount × testTimeMs)と同値。分母が 0 なら nil
        public let avgLaneUtilisationPct: Double?
    }

    public struct PerfScenarioDelta: Codable, Sendable, Equatable {
        public let scenarioID: String
        public let platform: String
        public let latestMs: Int
        public let previousMs: Int
        /// (latest - previous) / previous * 100。previous==0 の組は比較から除外する(発散)
        public let deltaPct: Double
    }

    public struct PerformanceReport: Codable, Sendable, Equatable {
        /// 有効な計測の実行(グループ)。1行 = 1実行(PerfRunRow の doc 参照)。グループ鍵の降順(新しい順)。
        /// **measurementInvalid の run を1つでも含むグループは丸ごと除外**(片翼だけの計測は
        /// 実行全体として使えない)
        public let runs: [PerfRunRow]
        /// 除外したグループに属していた perf run の総数(事実として出す)
        public let invalidCount: Int
        /// **同じ (profile, 機械集合) に前回計測がある最新の実行**と、その直前の実行の突き合わせ。
        /// 「全体の最新」に固定しない —— 初計測の構成が最新に来ると、意味ある比較が眠ったまま
        /// 空になる(2026-09-01 実データ)。機械集合も揃える(デバイス構成を揃える規律:
        /// docs/results-json.md。ローカルのみ計測とフリート計測の突き合わせは機械性能差が混ざる)。
        /// **両方に存在する (scenarioID, platform) だけ**を比べる(集合を揃える規律。
        /// 同一実行内に同じ組が複数あるときは startedAt 最新を採る = matrix と同じ規律)。
        /// deltaPct 降順(悪化が上)、同値は scenarioID 昇順。相手が無ければ空
        public let comparison: [PerfScenarioDelta]
        /// comparison の比較相手(前回側)のグループ鍵(無ければ nil)
        public let comparedRunID: String?
        /// comparison の最新側のグループ鍵(runs の先頭と一致するとは限らない。無ければ nil)
        public let comparisonRunID: String?
    }

    private struct PerfScenarioKey: Hashable {
        let scenarioID: String
        let platform: String
    }

    /// performanceMode==true の run を実行(runGroup)単位に畳み、有効な計測グループの一覧と
    /// 直近の突き合わせを返す
    public static func performanceReport(records: [ScenarioRunRecord], runs: [RunMetaRecord]) -> PerformanceReport {
        let perfRuns = runs.filter { $0.performanceMode == true }
        let grouped = Dictionary(grouping: perfRuns) { $0.runGroup ?? $0.runID }
        var validGroups: [(key: String, members: [RunMetaRecord])] = []
        var invalidCount = 0
        for (key, members) in grouped {
            if members.contains(where: { $0.measurementInvalid == true }) {
                invalidCount += members.count
            } else {
                validGroups.append((key, members.sorted { $0.runID < $1.runID }))
            }
        }
        // グループ鍵は runID と同じ形式(辞書順 = 時系列順)なので鍵の降順 = 新しい順
        validGroups.sort { $0.key > $1.key }

        let runRows = validGroups.map { perfGroupRow(key: $0.key, members: $0.members, records: records) }
        let (comparison, comparedRunID, comparisonRunID) = perfComparison(groups: validGroups, records: records)

        return PerformanceReport(
            runs: runRows, invalidCount: invalidCount,
            comparison: comparison, comparedRunID: comparedRunID, comparisonRunID: comparisonRunID)
    }

    private static func perfGroupRow(key: String, members: [RunMetaRecord],
                                     records: [ScenarioRunRecord]) -> PerfRunRow {
        let memberIDs = Set(members.map(\.runID))
        let scoped = records.filter { memberIDs.contains($0.runID) && !isSkippedSynthetic($0) }
        let scenarioTotalMs = scoped.reduce(0) { $0 + $1.durationMs }
        let testTime = perfTestTimeMs(scoped)
        // (host, worker) で数える(laneCount の doc 参照)
        let laneCount = Set(scoped.compactMap { record in
            record.worker.map { "\(record.host)\u{1}\($0)" }
        }).count
        let longest = perfMaxScenario(scoped)
        // 分母 = Σ機械ごとの(レーン数 × その機械のテスト時間窓)(avgLaneUtilisationPct の doc 参照)
        let capacityMs = Dictionary(grouping: scoped, by: \.host).values.reduce(0.0) { acc, hostRecords in
            let lanes = Set(hostRecords.compactMap(\.worker)).count
            guard lanes > 0, let hostTestTime = perfTestTimeMs(hostRecords) else { return acc }
            return acc + Double(lanes) * Double(hostTestTime)
        }
        let utilisation: Double? = capacityMs > 0
            ? Double(scenarioTotalMs) / capacityMs * 100 : nil
        let hosts = Set(members.map(\.host)).sorted()
        let startedAt = members.min { date(from: $0.startedAt) < date(from: $1.startedAt) }?.startedAt
            ?? members.first?.startedAt ?? ""
        // 合算(どれか1つでも未完了なら「まだ言えない」= nil)
        let passed = members.reduce(Optional(0)) { acc, m in acc.flatMap { a in m.passed.map { a + $0 } } }
        let failed = members.reduce(Optional(0)) { acc, m in acc.flatMap { a in m.failed.map { a + $0 } } }
        return PerfRunRow(
            runID: key, runIDs: members.map(\.runID),
            startedAt: startedAt, profile: members.first?.profile,
            host: hosts.first ?? "", hosts: hosts,
            wallClockMs: perfGroupWallClockMs(members), testTimeMs: testTime,
            scenarioTotalMs: scenarioTotalMs, scenarioCount: scoped.count,
            passed: passed, failed: failed,
            maxScenarioMs: longest?.ms, maxScenarioID: longest?.id,
            laneCount: laneCount, avgLaneUtilisationPct: utilisation)
    }

    /// グループ最初の開始〜最後の完了(ms)。1つでも finishedAt が欠落(未完了)なら nil
    private static func perfGroupWallClockMs(_ members: [RunMetaRecord]) -> Int? {
        let starts = members.map { date(from: $0.startedAt) }
        var finishes: [Date] = []
        for member in members {
            guard let finishedAt = member.finishedAt,
                  let finish = isoFormatter.date(from: finishedAt) else { return nil }
            finishes.append(finish)
        }
        guard let start = starts.min(), start != .distantPast, let finish = finishes.max() else { return nil }
        return Int((finish.timeIntervalSince(start) * 1000).rounded())
    }

    /// 最初のシナリオ開始〜最後のシナリオ完了(ms)。startedAt がパース不能なレコードは
    /// distantPast 扱いになり窓を壊すので除外する。対象0件なら nil
    private static func perfTestTimeMs(_ scoped: [ScenarioRunRecord]) -> Int? {
        let spans = scoped.compactMap { record -> (start: Date, end: Date)? in
            let start = date(from: record.startedAt)
            guard start != .distantPast else { return nil }
            return (start, start.addingTimeInterval(Double(record.durationMs) / 1000))
        }
        guard let first = spans.map(\.start).min(), let last = spans.map(\.end).max() else { return nil }
        return Int((last.timeIntervalSince(first) * 1000).rounded())
    }

    /// 最長所要のレコード(同値は scenarioID 昇順で決定的に選ぶ)。走査順に依存しない —— 同値のときは
    /// 「より小さい scenarioID」のときだけ入れ替えるので、先に見つかった側の scenarioID の大小と無関係に
    /// 最終的に集合内最小の scenarioID へ収束する
    private static func perfMaxScenario(_ records: [ScenarioRunRecord]) -> (ms: Int, id: String)? {
        var best: (ms: Int, id: String)?
        for record in records {
            guard let current = best else { best = (record.durationMs, record.scenarioID); continue }
            if record.durationMs > current.ms
                || (record.durationMs == current.ms && record.scenarioID < current.id) {
                best = (record.durationMs, record.scenarioID)
            }
        }
        return best
    }

    /// グループの比較同一性: (profile, 機械集合)。member は runID 昇順で来るので first の profile で代表する
    private static func perfGroupIdentity(_ members: [RunMetaRecord]) -> String {
        let profile = members.first?.profile ?? ""
        let hosts = Set(members.map(\.host)).sorted().joined(separator: "\u{1}")
        return "\(profile)\u{2}\(hosts)"
    }

    private static func perfComparison(
        groups: [(key: String, members: [RunMetaRecord])], records: [ScenarioRunRecord]
    ) -> ([PerfScenarioDelta], String?, String?) {
        // 新しい順に「同じ (profile, 機械集合) の前回計測がある実行」を探す(PerformanceReport の doc 参照)
        var pair: (latest: (key: String, members: [RunMetaRecord]),
                   previous: (key: String, members: [RunMetaRecord]))?
        for (index, candidate) in groups.enumerated() {
            if let previous = groups.dropFirst(index + 1).first(where: {
                perfGroupIdentity($0.members) == perfGroupIdentity(candidate.members)
            }) {
                pair = (candidate, previous)
                break
            }
        }
        guard let (latest, previous) = pair else { return ([], nil, nil) }

        let latestDurations = perfLatestDurations(records: records, runIDs: Set(latest.members.map(\.runID)))
        let previousDurations = perfLatestDurations(records: records, runIDs: Set(previous.members.map(\.runID)))

        var deltas: [PerfScenarioDelta] = []
        for (key, latestValue) in latestDurations {
            guard let previousValue = previousDurations[key], previousValue.durationMs != 0 else { continue }
            let deltaPct = Double(latestValue.durationMs - previousValue.durationMs)
                / Double(previousValue.durationMs) * 100
            deltas.append(PerfScenarioDelta(
                scenarioID: key.scenarioID, platform: key.platform,
                latestMs: latestValue.durationMs, previousMs: previousValue.durationMs, deltaPct: deltaPct))
        }
        let sorted = deltas.sorted { lhs, rhs in
            if lhs.deltaPct != rhs.deltaPct { return lhs.deltaPct > rhs.deltaPct }
            if lhs.scenarioID != rhs.scenarioID { return lhs.scenarioID < rhs.scenarioID }
            return lhs.platform < rhs.platform
        }
        return (sorted, previous.key, latest.key)
    }

    /// (scenarioID, platform) ごとの最新レコードの所要(同一 run 内に複数あるときは startedAt 最新。
    /// matrix の latestByKey と同じ規律)。isSkippedSynthetic は除外(duration 比較の対象外)。
    /// **passed のレコードだけ** —— 失敗の durationMs はタイムアウト等「失敗経路の長さ」であって
    /// シナリオの性能ではなく、比較に混ぜると巨大な偽の悪化が先頭に並ぶ
    private static func perfLatestDurations(
        records: [ScenarioRunRecord], runIDs: Set<String>
    ) -> [PerfScenarioKey: (durationMs: Int, startedAt: String)] {
        var result: [PerfScenarioKey: (durationMs: Int, startedAt: String)] = [:]
        for record in records where runIDs.contains(record.runID) && record.passed && !isSkippedSynthetic(record) {
            let key = PerfScenarioKey(scenarioID: record.scenarioID, platform: record.platform)
            if let existing = result[key] {
                if date(from: record.startedAt) > date(from: existing.startedAt) {
                    result[key] = (record.durationMs, record.startedAt)
                }
            } else {
                result[key] = (record.durationMs, record.startedAt)
            }
        }
        return result
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

    /// **ヒールキャッシュ/自己修復に寄りかかったまま緑が続いている**セレクタ。
    ///
    /// 修正提案は毎 run 出るが、放置しても何も起きない —— キャッシュは
    /// `.fleetest/heal-cache.json` に残り、2 回目以降は FM すら呼ばずに通る。
    /// 速度のための仕組みが「壊れたセレクタを永久に緑にする装置」になっていないかを、
    /// **提案が何 run 続いたか**で見る(1 run だけなら直せばよい。続いているなら放置されている)。
    private static func healRelianceInsights(scenarioID: String,
                                             group: [ScenarioRunRecord]) -> [InsightRow] {
        var runsPerSelector: [String: Int] = [:]
        for record in group {
            // 同じ run に同じセレクタが複数回出ても 1 と数える(run 数が知りたい)
            let selectors = Set((record.fixSuggestions ?? []).compactMap(\.oldSelector))
            for selector in selectors { runsPerSelector[selector, default: 0] += 1 }
        }
        return runsPerSelector
            .filter { $0.value >= healRelianceMinRuns }
            .sorted { $0.key < $1.key }
            .map { selector, runs in
                InsightRow(
                    kind: "healReliance", severity: "warn", scenarioID: scenarioID, worker: nil,
                    message: "\(scenarioID): \"\(selector)\" has been passing only via self-heal/cache"
                        + " for \(runs) run(s) — apply the suggested selector",
                    count: runs, deltaPct: nil)
            }
    }

    /// 実行されなくなったシナリオ(結果だけが results/ に残っている)を分ける。
    /// 判定は**最新の記録からの相対**にする —— 絶対時刻だと、しばらく回していない
    /// プロジェクトの全シナリオが一斉に retired になる
    private static func partitionRetired(
        _ records: [ScenarioRunRecord], definedClasses: Set<String>?
    ) -> (live: [ScenarioRunRecord], retired: [String]) {
        guard let newest = records.map({ date(from: $0.startedAt) }).max() else { return (records, []) }
        let cutoff = newest.addingTimeInterval(-retiredScenarioDays * 86400)
        // 空集合は「供給されていない」とみなす(下の doc 参照)
        let defined = (definedClasses?.isEmpty ?? true) ? nil : definedClasses
        var live: [ScenarioRunRecord] = []
        var retired: [String] = []
        for (scenarioID, group) in Dictionary(grouping: records, by: \.scenarioID) {
            // ソースに無いなら日付を問わず retired(削除・_disabled 化。2〜3 日前に走っていても消す)
            let className = String(scenarioID.prefix { $0 != "." })
            let undefined = defined.map { !$0.contains(className) } ?? false
            let stale = group.map({ date(from: $0.startedAt) }).max().map { $0 < cutoff } ?? false
            if undefined || stale {
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
            guard workerFailed >= deviceBiasMinFailures else { return nil }
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

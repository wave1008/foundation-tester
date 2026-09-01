// VSCode拡張ダッシュボード向け: 実行結果DB(RunResultsStore/RunResultsQuery)の集計を
// まとめて1回のJSONで返す(fleetest api results)。診断は stderr のみ(ApiCommands.swift と同じ流儀)。
// 出力ペイロードの契約(フィールド名・trend の省略可否): vscode-fleetest/src/dashboardModel.ts と同期。
// 出力は <project>/.fleetest/results-cache/ にキャッシュする(有効条件と厳密性は
// FTCore.ResultsOutputCache の冒頭)。--no-cache は読まないだけで、書き直しは常に行う

import ArgumentParser
import Foundation
import FTCore
import FTRemote

struct ApiResultsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "results",
        abstract: "Aggregate the run-results database (results/) — runs/summary/flaky/devices/daily/trend/slow/insights/matrix —"
            + " and print it all as JSON on stdout (diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Start of the period: a relative value such as 30d/12h, or YYYY-MM-DD (default 90d)")
    var since: String = "90d"

    @Option(help: "Number of entries to include in runs (descending by runID)")
    var limit: Int = 50

    @Option(name: .customLong("min-runs"), help: "Minimum number of runs before a scenario is considered for flakiness")
    var minRuns: Int = 5

    @Option(help: "Scenario ID whose trend (run history) to output; omitted unless given")
    var scenario: String?

    @Option(name: .customLong("matrix-runs"), help: "How many recent runs to include in the scenario-by-run pass/fail matrix (0 omits the matrix)")
    var matrixRuns: Int = 20

    @Flag(name: .customLong("no-cache"),
          help: "Recompute instead of reading the output cache (<project>/.fleetest/results-cache/); the cache is rewritten either way")
    var noCache = false

    func run() throws {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        guard let sinceDate = RunResultsQuery.parseSince(since) else {
            throw ValidationError("invalid --since format: \(since) (e.g. 30d, 12h, 2026-06-01)")
        }
        let isoFormatter = ISO8601DateFormatter()
        let generatedAt = isoFormatter.string(from: Date())
        // windowKey と同じ書式(ISO8601 "Z")。出力の since と有効判定の sinceKey は同じ値
        let sinceKey = RunResultsStore.windowKey(sinceDate)
        let stateDir = testProject.stateDir
        let key = ResultsOutputCache.argumentsKey(
            arguments: [testProject.name, since, String(limit), String(minRuns), String(matrixRuns)],
            executable: Bundle.main.executableURL)
        // 指紋は走査より先に取る(順序の理由は scanFingerprint の doc)
        let scanDigest = RunResultsStore.scanFingerprint(resultsDir: resultsDir, since: sinceDate)

        if !noCache,
           let output = cachedOutput(stateDir: stateDir, resultsDir: resultsDir, key: key,
                                     scanDigest: scanDigest, sinceKey: sinceKey, generatedAt: generatedAt) {
            print(output)
            return
        }

        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
        let entries = RunResultsStore.scanRecordEntries(resultsDir: resultsDir, since: sinceDate)
        let records = entries.map(\.record)
        let recentRuns = RunResultsQuery.recentRuns(runs, limit: limit)

        let body = ApiResultsBody(
            schemaVersion: 1,
            project: testProject.name,
            runs: recentRuns,
            summary: RunResultsQuery.scenarioSummary(records),
            flaky: RunResultsQuery.flakyScenarios(records, minRuns: minRuns),
            devices: RunResultsQuery.deviceSummary(records),
            daily: RunResultsQuery.dailyRates(records),
            slow: RunResultsQuery.slowTests(records, limit: 10),
            insights: RunResultsQuery.insights(records: records, runs: runs,
                                               definedClasses: definedScenarioClasses(of: testProject)),
            matrix: matrixRuns > 0 ? RunResultsQuery.matrix(records: records, runs: runs, limit: matrixRuns) : nil,
            triage: RunResultsQuery.triage(records),
            performance: RunResultsQuery.performanceReport(records: records, runs: runs),
            machines: RemoteHostFactsStore.aliasPairs(dir: RemoteHostFactsStore.dir(project: testProject))
                .map { MachineAliasEntry(host: $0.host, machine: $0.machine) },
            runStats: RunResultsQuery.runStats(runs: recentRuns, records: records))

        let encoder = Self.makeEncoder()
        let bodyJSON = String(decoding: try encoder.encode(body), as: UTF8.self)
        let trendJSON = try scenario.map { id in
            String(decoding: try encoder.encode(RunResultsQuery.trend(records, scenarioID: id)), as: UTF8.self)
        }

        // 窓に含めた最古の startedAt(run.json と記録の両方。どちらかが落ちれば出力が変わる)
        let oldestIncluded = (runs.map(\.startedAt) + records.map(\.startedAt)).min()
        let resultsPrefix = resultsDir.path + "/"
        let trendFiles = Dictionary(grouping: entries, by: \.record.scenarioID).mapValues { group in
            group.map { entry -> String in
                let path = entry.url.path
                return path.hasPrefix(resultsPrefix) ? String(path.dropFirst(resultsPrefix.count)) : path
            }
        }
        ResultsOutputCache.write(
            ResultsOutputCache.Entry(key: key, scanDigest: scanDigest, sinceKey: sinceKey,
                                     oldestIncludedStartedAt: oldestIncluded, body: bodyJSON),
            trendIndex: ResultsOutputCache.TrendIndex(scanDigest: scanDigest, files: trendFiles),
            stateDir: stateDir)

        guard let output = ResultsOutputCache.compose(generatedAt: generatedAt, since: sinceKey,
                                                      trendJSON: trendJSON, body: bodyJSON) else {
            throw ValidationError("internal: the results body did not encode as a JSON object")
        }
        print(output)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func diagnose(_ message: String) {
        FileHandle.standardError.write(Data("results cache: \(message)\n".utf8))
    }

    /// キャッシュが有効なら合成済みの出力(--scenario 付きは索引から trend を読んで足す)。
    /// 無効・読めない・索引が指紋と食い違う場合は nil(= 全部計算する)
    private func cachedOutput(stateDir: URL, resultsDir: URL, key: String, scanDigest: String,
                              sinceKey: String, generatedAt: String) -> String? {
        let (entry, readable) = ResultsOutputCache.readEntry(stateDir: stateDir)
        if let miss = ResultsOutputCache.validate(entry, readable: readable, key: key,
                                                  scanDigest: scanDigest, sinceKey: sinceKey) {
            Self.diagnose("miss (\(miss))")
            return nil
        }
        guard let entry else { return nil }
        var trendJSON: String?
        if let scenario {
            guard let index = ResultsOutputCache.readTrendIndex(stateDir: stateDir),
                  index.formatVersion == ResultsOutputCache.formatVersion,
                  index.scanDigest == scanDigest else {
                Self.diagnose("miss (trend index)")
                return nil
            }
            let records = Self.records(index: index, scenarioID: scenario, resultsDir: resultsDir, sinceKey: sinceKey)
            guard let data = try? Self.makeEncoder().encode(RunResultsQuery.trend(records, scenarioID: scenario)) else {
                return nil
            }
            trendJSON = String(decoding: data, as: UTF8.self)
        }
        guard let output = ResultsOutputCache.compose(generatedAt: generatedAt, since: sinceKey,
                                                      trendJSON: trendJSON, body: entry.body) else {
            Self.diagnose("miss (body)")
            return nil
        }
        Self.diagnose("hit")
        return output
    }

    /// 索引が指す記録だけを読む。読み飛ばし規律は RunResultsStore.scanRecords と同じ
    /// (壊れたファイル・新しすぎる schemaVersion・since より前)
    private static func records(index: ResultsOutputCache.TrendIndex, scenarioID: String,
                                resultsDir: URL, sinceKey: String) -> [ScenarioRunRecord] {
        let decoder = JSONDecoder()
        return (index.files[scenarioID] ?? []).compactMap { relative -> ScenarioRunRecord? in
            let url = relative.hasPrefix("/") ? URL(fileURLWithPath: relative)
                                              : resultsDir.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(ScenarioRunRecord.self, from: data),
                  record.schemaVersion <= RunRecordSchema.current,
                  record.startedAt >= sinceKey else { return nil }
            return record
        }
    }
}

/// fleetest api results の出力のうち、呼ぶたびに変わる since/generatedAt と --scenario 依存の trend を
/// 除いた部分(= キャッシュの body)。matrix は --matrix-runs 0 指定時にキー自体を出さない
/// (null ではなくキー欠落。TS 側はキーの有無で指定の有無を判定する契約)。
/// 印字形は ResultsOutputCache.compose が組む
private struct ApiResultsBody: Encodable {
    let schemaVersion: Int
    let project: String
    let runs: [RunMetaRecord]
    let summary: [RunResultsQuery.ScenarioSummaryRow]
    let flaky: [RunResultsQuery.FlakyRow]
    let devices: RunResultsQuery.DevicesReport
    let daily: [RunResultsQuery.DailyRow]
    let slow: [RunResultsQuery.SlowTestRow]
    let insights: [RunResultsQuery.InsightRow]
    let matrix: RunResultsQuery.MatrixReport?
    let triage: RunResultsQuery.TriageReport
    let performance: RunResultsQuery.PerformanceReport
    /// 記録の host(ホスト名)→ この Mac の登録名(machine)の読み替え表(facts キャッシュ由来)。
    /// 記録・runID は host のまま —— エイリアスは改名されうるので表示時にだけ引く
    let machines: [MachineAliasEntry]
    /// runs と同じ集合の per-run 時間統計(壁時計・テスト時間。表示側が runGroup 単位に畳む)
    let runStats: [RunResultsQuery.RunStatsRow]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, runs, summary, flaky, devices, daily,
             slow, insights, matrix, triage, performance, machines, runStats
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(project, forKey: .project)
        try container.encode(runs, forKey: .runs)
        try container.encode(summary, forKey: .summary)
        try container.encode(flaky, forKey: .flaky)
        try container.encode(devices, forKey: .devices)
        try container.encode(daily, forKey: .daily)
        try container.encode(slow, forKey: .slow)
        try container.encode(insights, forKey: .insights)
        if let matrix {
            try container.encode(matrix, forKey: .matrix)
        }
        try container.encode(triage, forKey: .triage)
        try container.encode(performance, forKey: .performance)
        try container.encode(machines, forKey: .machines)
        try container.encode(runStats, forKey: .runStats)
    }
}

/// host(記録の鍵)→ machine(表示名)の1組。TS 側契約: dashboardModel.ts の MachineAliasRow
struct MachineAliasEntry: Encodable {
    let host: String
    let machine: String
}

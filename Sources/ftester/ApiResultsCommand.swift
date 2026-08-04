// VSCode拡張ダッシュボード向け: 実行結果DB(RunResultsStore/RunResultsQuery)の集計を
// まとめて1回のJSONで返す(ftester api results)。診断は stderr のみ(ApiCommands.swift と同じ流儀)。
// 出力ペイロードの契約(フィールド名・trend の省略可否): vscode-ftester/src/dashboardModel.ts と同期

import ArgumentParser
import Foundation
import FTCore

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

    func run() throws {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        guard let sinceDate = RunResultsQuery.parseSince(since) else {
            throw ValidationError("invalid --since format: \(since) (e.g. 30d, 12h, 2026-06-01)")
        }

        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let isoFormatter = ISO8601DateFormatter()

        let output = ApiResultsOutput(
            schemaVersion: 1,
            project: testProject.name,
            generatedAt: isoFormatter.string(from: Date()),
            since: isoFormatter.string(from: sinceDate),
            runs: RunResultsQuery.recentRuns(runs, limit: limit),
            summary: RunResultsQuery.scenarioSummary(records),
            flaky: RunResultsQuery.flakyScenarios(records, minRuns: minRuns),
            devices: RunResultsQuery.deviceSummary(records),
            daily: RunResultsQuery.dailyRates(records),
            trend: scenario.map { RunResultsQuery.trend(records, scenarioID: $0) },
            slow: RunResultsQuery.slowTests(records, limit: 10),
            insights: RunResultsQuery.insights(records: records, runs: runs),
            matrix: matrixRuns > 0 ? RunResultsQuery.matrix(records: records, runs: runs, limit: matrixRuns) : nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }
}

/// ftester api results の出力全体。trend は --scenario 省略時、matrix は --matrix-runs 0 指定時に
/// キー自体を出さない(null ではなくキー欠落。TS 側はキーの有無で指定の有無を判定する契約)
private struct ApiResultsOutput: Encodable {
    let schemaVersion: Int
    let project: String
    let generatedAt: String
    let since: String
    let runs: [RunMetaRecord]
    let summary: [RunResultsQuery.ScenarioSummaryRow]
    let flaky: [RunResultsQuery.FlakyRow]
    let devices: RunResultsQuery.DevicesReport
    let daily: [RunResultsQuery.DailyRow]
    let trend: [ScenarioRunRecord]?
    let slow: [RunResultsQuery.SlowTestRow]
    let insights: [RunResultsQuery.InsightRow]
    let matrix: RunResultsQuery.MatrixReport?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, generatedAt, since, runs, summary, flaky, devices, daily, trend,
             slow, insights, matrix
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(project, forKey: .project)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(since, forKey: .since)
        try container.encode(runs, forKey: .runs)
        try container.encode(summary, forKey: .summary)
        try container.encode(flaky, forKey: .flaky)
        try container.encode(devices, forKey: .devices)
        try container.encode(daily, forKey: .daily)
        if let trend {
            try container.encode(trend, forKey: .trend)
        }
        try container.encode(slow, forKey: .slow)
        try container.encode(insights, forKey: .insights)
        if let matrix {
            try container.encode(matrix, forKey: .matrix)
        }
    }
}

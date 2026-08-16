// ResultsCommand.swift
// results/ 配下(RunResultsStore)の実行結果 DB を集計して表示する CLI。
// 集計ロジックは RunResultsQuery(FTCore、vscode 拡張の api コマンドと共用)に置き、
// このファイルは表示整形とオプション解釈のみを担当する。

import ArgumentParser
import Foundation
import FTCore

struct ResultsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "results",
        abstract: "Aggregate and analyse the run-results database (results/)",
        subcommands: [
            ResultsListCommand.self,
            ResultsSummaryCommand.self,
            ResultsFlakyCommand.self,
            ResultsTrendCommand.self,
            ResultsDevicesCommand.self,
            ResultsSlowCommand.self,
            ResultsInsightsCommand.self,
        ])
}

/// results サブコマンド共通オプション
struct ResultsQueryOptions: ParsableArguments {
    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Start of the period: a relative value such as 30d/12h, or YYYY-MM-DD (default 90d)")
    var since: String = "90d"

    @Flag(help: "Print the result as a single line of JSON")
    var json = false

    /// プロジェクト・resultsDir・since の Date を解決する。--since 形式不正はここで弾く
    func resolve() throws -> (project: TestProject, resultsDir: URL, sinceDate: Date) {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        guard let sinceDate = RunResultsQuery.parseSince(since) else {
            throw ValidationError("invalid --since format: \(since) (e.g. 30d, 12h, 2026-06-01)")
        }
        return (testProject, resultsDir, sinceDate)
    }
}

/// 今もソースに在る @TestClass のクラス名(`insights` が「消えたシナリオ」を確実に判定するために使う)。
/// **ソース走査だけで済ませる**(ScenarioHost.list はビルドが要り、読み取りだけの results を重くする)。
/// 走査できなければ空集合 = 供給なし扱い(RunResultsQuery.insights の doc 参照)
func definedScenarioClasses(of project: TestProject) -> Set<String> {
    Set(ScenarioFolders.classFileMap(scenariosDir: project.scenariosDir).keys)
}

/// --json 指定時の共通出力(sortedKeys・スラッシュ非エスケープの 1 行 JSON)
private func printResultsJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8)!)
}

/// startedAt(ISO8601 UTC)をローカルタイムゾーンの人間可読表示に変換する。パース不能ならそのまま返す
// formatLocal / SimpleTable は FTesterTests から検証するため internal(private へ戻さない)。
func formatLocal(_ iso8601: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
}

/// 日本語混じりでも桁数(character count)基準で揃える簡易テーブル(半角想定・厳密な幅計算はしない)
enum SimpleTable {
    static func render(headers: [String], rows: [[String]]) -> String {
        let columnCount = headers.count
        var widths = headers.map(\.count)
        for row in rows {
            for i in 0..<columnCount {
                widths[i] = max(widths[i], (i < row.count ? row[i] : "").count)
            }
        }
        func padRow(_ cells: [String]) -> String {
            (0..<columnCount).map { i -> String in
                let cell = i < cells.count ? cells[i] : ""
                return cell + String(repeating: " ", count: widths[i] - cell.count)
            }.joined(separator: "  ")
        }
        var lines = [padRow(headers)]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        lines.append(contentsOf: rows.map(padRow))
        return lines.joined(separator: "\n")
    }
}

// MARK: - list

struct ResultsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List runs, newest first")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "Number of rows to show")
    var limit: Int = 20

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.recentRuns(runs, limit: limit)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("No matching runs")
            return
        }
        let headers = ["runID", "time", "trigger", "profile", "machine", "passed/failed/total"]
        let tableRows = rows.map { meta -> [String] in
            let counts: String
            if let total = meta.total, let passed = meta.passed, let failed = meta.failed {
                counts = "\(passed)/\(failed)/\(total)"
            } else {
                counts = "(incomplete)"
            }
            return [meta.runID, formatLocal(meta.startedAt), meta.trigger,
                    meta.profile ?? "-", meta.machine, counts]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - summary

struct ResultsSummaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary", abstract: "Aggregate run count, pass rate and duration per scenario (lowest pass rate first)")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "Scenario ID to report on (defaults to all scenarios)")
    var scenario: String?

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let filtered = scenario.map { id in records.filter { $0.scenarioID == id } } ?? records
        let rows = RunResultsQuery.scenarioSummary(filtered)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("No matching scenarios")
            return
        }
        let headers = ["scenario", "runs", "pass rate", "avg ms", "median ms", "last run", "last result"]
        let tableRows = rows.map { row -> [String] in
            [row.scenarioID, String(row.runs), String(format: "%.1f%%", row.successRate),
             row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-",
             row.medianDurationMs.map { String(format: "%.0f", $0) } ?? "-",
             row.lastRunAt.map(formatLocal) ?? "-",
             row.lastPassed.map { $0 ? "✅" : "❌" } ?? "-"]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - flaky

struct ResultsFlakyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flaky", abstract: "List scenarios that both pass and fail, most flaky first")

    @OptionGroup var options: ResultsQueryOptions

    @Option(name: .customLong("min-runs"), help: "Minimum number of runs to include a scenario")
    var minRuns: Int = 5

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.flakyScenarios(records, minRuns: minRuns)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("No flaky scenarios (candidates need --min-runs \(minRuns)+ and mixed pass/fail)")
            return
        }
        let headers = ["scenario", "runs", "fail rate", "flip score", "recent results (new→old)"]
        let tableRows = rows.map { row -> [String] in
            [row.scenarioID, String(row.runs), String(format: "%.1f%%", row.failureRate),
             String(format: "%.2f", row.flakinessScore),
             row.recentResults.map { $0 ? "✅" : "❌" }.joined()]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - trend

struct ResultsTrendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trend", abstract: "Show the run history of a single scenario in chronological order")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "Scenario ID")
    var scenario: String

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.trend(records, scenarioID: scenario)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("No run history for: \(scenario)")
            return
        }
        // バーはスキップ合成レコードを除いた最大 durationMs を 20 文字とした相対値
        let maxDuration = rows.filter { !RunResultsQuery.isSkippedSynthetic($0) }
            .map(\.durationMs).max() ?? 0
        let headers = ["startedAt", "runID", "passed", "durationMs", "worker", "machine", "bar"]
        let tableRows = rows.map { record -> [String] in
            let bar: String
            if RunResultsQuery.isSkippedSynthetic(record) || maxDuration == 0 {
                bar = ""
            } else {
                let length = max(1, Int((Double(record.durationMs) / Double(maxDuration)) * 20))
                bar = String(repeating: "█", count: length)
            }
            return [formatLocal(record.startedAt), record.runID, record.passed ? "✅" : "❌",
                    String(record.durationMs), record.worker ?? "-", record.machine, bar]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - devices

struct ResultsDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices", abstract: "Aggregate run count and pass rate per worker (device) and per platform")

    @OptionGroup var options: ResultsQueryOptions

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let report = RunResultsQuery.deviceSummary(records)

        if options.json {
            try printResultsJSON(report)
            return
        }
        guard !report.byWorker.isEmpty else {
            print("No matching runs")
            return
        }
        print("[per worker]")
        print(SimpleTable.render(
            headers: ["worker", "runs", "pass rate", "avg ms"],
            rows: report.byWorker.map { row in
                [row.worker, String(row.runs), String(format: "%.1f%%", row.successRate),
                 row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-"]
            }))
        print("\n[per platform]")
        print(SimpleTable.render(
            headers: ["platform", "runs", "pass rate", "avg ms"],
            rows: report.byPlatform.map { row in
                [row.platform, String(row.runs), String(format: "%.1f%%", row.successRate),
                 row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-"]
            }))
    }
}

// MARK: - slow

struct ResultsSlowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slow", abstract: "List scenarios by average duration, slowest first")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "Number of rows to show")
    var limit: Int = 10

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.slowTests(records, limit: limit)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("No matching scenarios")
            return
        }
        let headers = ["scenario", "runs", "avg ms", "p90 ms", "regression", "slowest scene"]
        let tableRows = rows.map { row -> [String] in
            let delta = row.deltaPct.map { String(format: "%+.0f%%", $0) } ?? "-"
            let slowestScene: String
            if let scene = row.slowestScene, let avg = row.slowestSceneAvgMs {
                slowestScene = "\(scene) (\(String(format: "%.0f", avg))ms)"
            } else {
                slowestScene = "-"
            }
            return [row.scenarioID, String(row.runs), String(format: "%.0f", row.avgDurationMs),
                    String(format: "%.0f", row.p90DurationMs), delta, slowestScene]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - insights

struct ResultsInsightsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "insights",
        abstract: "Detect things worth attention: regressions, consecutive failures, infrastructure-caused failures and stale selectors")

    @OptionGroup var options: ResultsQueryOptions

    func run() throws {
        let (project, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.insights(records: records, runs: runs,
                                            definedClasses: definedScenarioClasses(of: project))

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("Nothing needs attention")
            return
        }
        for row in rows {
            let icon: String
            switch row.severity {
            case "critical": icon = "🔴"
            case "warn": icon = "🟡"
            default: icon = "🔵"
            }
            print("\(icon) \(row.message)")
        }
    }
}

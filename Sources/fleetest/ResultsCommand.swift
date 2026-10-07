// ResultsCommand.swift
// results/ 配下(RunResultsStore)の実行結果 DB を集計して表示する CLI。
// 集計ロジックは RunResultsQuery(FTCore、vscode 拡張の api コマンドと共用)に置き、
// 表の整形は FTCore.ResultsRendering(MCP の ft_results と共有)。このファイルはオプション解釈と --json のみ。

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
            ResultsLogCommand.self,
        ])
}

/// results サブコマンド共通オプション
struct ResultsQueryOptions: ParsableArguments {
    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Start of the period: a duration (e.g. 90s/30m/2h/30d), a date (YYYY-MM-DD) or an epoch (@1757280000)")
    var since: String = ResultsRendering.defaultSince

    @Flag(help: "Print the result as a single line of JSON")
    var json = false

    /// プロジェクト・resultsDir・since の Date を解決する。--since 形式不正はここで弾く
    func resolve() throws -> (project: TestProject, resultsDir: URL, sinceDate: Date) {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        guard let sinceDate = RunResultsQuery.parseSince(since) else {
            throw ValidationError(TimeBoundParse.rejection(option: "--since", raw: since))
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
    ConsoleOut.out(String(data: data, encoding: .utf8)!)
}

// MARK: - list

/// `--limit` の検査(results list / slow と api results が共有)。0 以下は黙って空の一覧になるので断る
enum ResultsLimit {
    static func validate(_ limit: Int) throws {
        guard limit >= 1 else { throw ValidationError("--limit must be 1 or more (got \(limit))") }
    }
}

struct ResultsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List runs, newest first")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "Number of rows to show")
    var limit: Int = ResultsRendering.defaultListLimit

    func validate() throws { try ResultsLimit.validate(limit) }

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.recentRuns(runs, limit: limit)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        ConsoleOut.out(ResultsRendering.list(rows))
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
        // CLI は --since の窓をそのまま集計する(ダッシュボードだけが直近 N 回へ絞る)
        let rows = RunResultsQuery.scenarioSummary(filtered, recentRuns: .max)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        ConsoleOut.out(ResultsRendering.summary(rows))
    }
}

// MARK: - flaky

struct ResultsFlakyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flaky", abstract: "List scenarios that both pass and fail, most flaky first")

    @OptionGroup var options: ResultsQueryOptions

    @Option(name: .customLong("min-runs"), help: "Minimum number of runs to include a scenario")
    var minRuns: Int = ResultsRendering.defaultMinRuns

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        // CLI は --since の窓をそのまま見る(ダッシュボードだけが直近 N 回へ絞る)
        let rows = RunResultsQuery.flakyScenarios(records, minRuns: minRuns, recentRuns: .max)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        ConsoleOut.out(ResultsRendering.flaky(rows, minRuns: minRuns))
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
        ConsoleOut.out(ResultsRendering.trend(rows, scenario: scenario))
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
        ConsoleOut.out(ResultsRendering.devices(report))
    }
}

// MARK: - slow

struct ResultsSlowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slow", abstract: "List scenarios by average duration, slowest first")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "Number of rows to show")
    var limit: Int = ResultsRendering.defaultSlowLimit

    func validate() throws { try ResultsLimit.validate(limit) }

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.slowTests(records, limit: limit)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        ConsoleOut.out(ResultsRendering.slow(rows))
    }
}

// MARK: - insights

struct ResultsInsightsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "insights",
        abstract: "Detect things worth attention: regressions, consecutive failures, failures with a non-assertion signature, and stale selectors")

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
        ConsoleOut.out(ResultsRendering.insights(rows))
    }
}

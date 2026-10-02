// MCPServer+Results.swift
// ft_results: `fleetest results <list|summary|flaky|trend|devices|slow|insights|log>` と同じ出力(JSON は無い)。
// **集計は FTCore.RunResultsQuery・整形は FTCore.ResultsRendering / ResultsLogReport の1箇所**
// (CLI と共有。ここで表や文言を作り直さない)。**CLI は Codex 等のシェルのサンドボックス内で動かない**ので
// 結果の履歴は MCP からも引けるようにしてある。

import Foundation
import FTCore

/// 入口で検査した ft_results の引数(Sendable なので走査をプールの外へ出せる)
struct MCPResultsRequest: Sendable, Equatable {
    static let queries = ["list", "summary", "flaky", "trend", "devices", "slow", "insights", "log"]

    var query: String
    var since: String
    var scenario: String?
    var runID: String?
    var limit: Int?
    var minRuns: Int?

    /// 引数名 → それを読む query。**読まれない query に渡されたら断る**(黙って効かない形を作らない)
    private static let appliesTo: [(argument: String, queries: Set<String>)] = [
        ("scenario", ["summary", "trend", "log"]),
        ("runId", ["log"]),
        ("limit", ["list", "slow"]),
        ("minRuns", ["flaky"]),
    ]

    static func parse(_ args: [String: Any]) throws -> MCPResultsRequest {
        let query = try MCPServer.requiredStringArgument(args, "query")
        guard queries.contains(query) else {
            throw MCPError("query must be one of: \(queries.joined(separator: ", ")) (got \(query))")
        }
        for (argument, accepted) in appliesTo where args[argument] != nil && !accepted.contains(query) {
            throw MCPError("\(argument) does not apply to query \(query) — it is read by: "
                + queries.filter(accepted.contains).joined(separator: ", "))
        }
        if query == "log", args["since"] != nil {
            throw MCPError("since does not apply to query log — pass runId (default latest)")
        }
        let scenario = try MCPServer.stringArgument(args, "scenario")
        if let scenario, scenario.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPError("scenario must not be empty")
        }
        if query == "trend", scenario == nil {
            throw MCPError("scenario is required for query trend")
        }
        return MCPResultsRequest(
            query: query,
            since: try MCPServer.stringArgument(args, "since") ?? ResultsRendering.defaultSince,
            scenario: scenario,
            runID: try MCPServer.stringArgument(args, "runId"),
            limit: try MCPServer.intArgument(args, "limit"),
            minRuns: try MCPServer.intArgument(args, "minRuns"))
    }

    /// CLI(`fleetest results <query>`)と同じ文面。**デバイス・ブリッジに触らない**
    func render(project: TestProject, now: Date = Date()) throws -> String {
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        if query == "log" {
            let sections: [ResultsLogReport.Section]
            do {
                sections = try ResultsLogReport.build(
                    resultsDir: resultsDir, projectName: project.name, requestedRunID: runID ?? "latest",
                    scenario: scenario, raw: false)
            } catch let error as ResultsLogError {
                throw MCPError(error.message)
            }
            return ResultsLogReport.text(sections)
        }
        guard let sinceDate = RunResultsQuery.parseSince(since, referenceDate: now) else {
            throw MCPError(TimeBoundParse.rejection(option: "since", raw: since))
        }
        switch query {
        case "list":
            let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
            return ResultsRendering.list(
                RunResultsQuery.recentRuns(runs, limit: limit ?? ResultsRendering.defaultListLimit))
        case "summary":
            let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
            let filtered = scenario.map { id in records.filter { $0.scenarioID == id } } ?? records
            return ResultsRendering.summary(RunResultsQuery.scenarioSummary(filtered, recentRuns: .max))
        case "flaky":
            let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
            let minRuns = minRuns ?? ResultsRendering.defaultMinRuns
            return ResultsRendering.flaky(
                RunResultsQuery.flakyScenarios(records, minRuns: minRuns, recentRuns: .max),
                minRuns: minRuns, minRunsOption: "minRuns")
        case "trend":
            let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
            let id = scenario ?? ""
            return ResultsRendering.trend(RunResultsQuery.trend(records, scenarioID: id), scenario: id)
        case "devices":
            let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
            return ResultsRendering.devices(RunResultsQuery.deviceSummary(records))
        case "slow":
            let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
            return ResultsRendering.slow(
                RunResultsQuery.slowTests(records, limit: limit ?? ResultsRendering.defaultSlowLimit))
        case "insights":
            let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
            let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
            // ソース走査だけ(ビルドしない)。走査できなければ空集合 = 供給なし扱い
            let defined = Set(ScenarioFolders.classFileMap(scenariosDir: project.scenariosDir).keys)
            return ResultsRendering.insights(
                RunResultsQuery.insights(records: records, runs: runs, definedClasses: defined))
        default:
            throw MCPError("query must be one of: \(Self.queries.joined(separator: ", ")) (got \(query))")
        }
    }
}

extension MCPServer {
    func ftResults(_ args: [String: Any]) async throws -> [[String: Any]] {
        let request = try MCPResultsRequest.parse(args)
        let project = try ScenarioHost.project(named: args["project"] as? String)
        // 90 日窓の走査は重い。協調スレッドプールにディスク走査を載せない(他の ft_* と同居している)
        let output = try await Task.detached(priority: .utility) {
            try request.render(project: project)
        }.value
        return text(output)
    }
}

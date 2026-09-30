// 2つの実行のシナリオ所要を突き合わせる(fleetest api results-compare)。ダッシュボードの
// 「直近の実行」で利用者が選んだ2件の比較が呼ぶ。判定は RunResultsQuery.scenarioDurationDeltas
// (前回計測との比較と共有)。診断は stderr のみ(ApiCommands.swift と同じ流儀)。

import ArgumentParser
import Foundation
import FTCore

struct ApiResultsCompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "results-compare",
        abstract: "Compare scenario durations between two runs (each given as all its member runIDs)"
            + " and print the per-scenario deltas as JSON on stdout (diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(name: .customLong("previous-run-id"),
            help: "A member runID of the baseline run (repeat for every member of a fleet run)")
    var previousRunIDs: [String] = []

    @Option(name: .customLong("latest-run-id"),
            help: "A member runID of the run compared against the baseline (repeat for every member)")
    var latestRunIDs: [String] = []

    func validate() throws {
        guard !previousRunIDs.isEmpty, !latestRunIDs.isEmpty else {
            throw ValidationError("pass at least one --previous-run-id and one --latest-run-id")
        }
        guard Set(previousRunIDs).isDisjoint(with: latestRunIDs) else {
            throw ValidationError("the same runID is given on both sides")
        }
    }

    func run() throws {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        var records: [ScenarioRunRecord] = []
        for runID in previousRunIDs + latestRunIDs {
            let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
            // 無い run を空集合として比べない(比較が黙って空になる)
            guard RunResultsStore.meta(runDir: runDir) != nil else {
                throw ValidationError("run not found: \(runID)")
            }
            records += RunResultsStore.records(runDir: runDir)
        }
        let comparison = RunResultsQuery.scenarioDurationDeltas(
            records: records, latestRunIDs: Set(latestRunIDs), previousRunIDs: Set(previousRunIDs))

        let output = ApiResultsCompareOutput(
            schemaVersion: 1, project: testProject.name,
            previousRunIDs: previousRunIDs, latestRunIDs: latestRunIDs, comparison: comparison)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        ConsoleOut.out(String(data: data, encoding: .utf8)!)
    }
}

/// fleetest api results-compare の出力全体。対向: vscode-fleetest/src/dashboardModel.ts の
/// isApiResultsComparePayload
private struct ApiResultsCompareOutput: Encodable {
    let schemaVersion: Int
    let project: String
    let previousRunIDs: [String]
    let latestRunIDs: [String]
    let comparison: [RunResultsQuery.PerfScenarioDelta]
}

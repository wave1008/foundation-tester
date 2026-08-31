// 1 run の run.json と全シナリオ記録をまとめて返す(fleetest api results-run)。
// 診断は stderr のみ(ApiCommands.swift と同じ流儀)。

import ArgumentParser
import Foundation
import FTCore

struct ApiResultsRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "results-run",
        abstract: "Print a single run's run.json and all its scenario records as JSON on stdout"
            + " (diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(name: .customLong("run-id"), help: "The runID to look up")
    var runID: String

    func run() throws {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)

        guard let meta = RunResultsStore.meta(runDir: runDir) else {
            throw ValidationError("run not found: \(runID)")
        }
        let scenarios = RunResultsStore.records(runDir: runDir)

        let output = ApiResultsRunOutput(
            schemaVersion: 1, project: testProject.name, run: meta, scenarios: scenarios)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }
}

/// fleetest api results-run の出力全体
private struct ApiResultsRunOutput: Encodable {
    let schemaVersion: Int
    let project: String
    let run: RunMetaRecord
    let scenarios: [ScenarioRunRecord]
}

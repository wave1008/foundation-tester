// ResultsLogCommand.swift
// 1 run のシナリオごとの実行ログ(RunRecorder が書く
// results/runs/<YYYY-MM>/<runID>/events/<fileBase>.ndjson。fileBase は同じ run の
// scenarios/<fileBase>.json と対応)を人間可読に整形して表示する(fleetest results log)。
// 収集・整形は FTCore.ResultsLogReport の1箇所(MCP の ft_results と共有。ここで整形し直さない)。

import ArgumentParser
import Foundation
import FTCore

struct ResultsLogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Print a run's per-scenario execution log (events/*.ndjson), one heading per scenario")

    @Argument(help: "The runID to look up, or \"latest\"")
    var runID: String

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Only show the log for this scenario ID")
    var scenario: String?

    @Flag(help: "Print the raw NDJSON lines instead of formatting them")
    var raw = false

    func run() throws {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)

        let sections: [ResultsLogReport.Section]
        do {
            sections = try ResultsLogReport.build(
                resultsDir: resultsDir, projectName: testProject.name, requestedRunID: runID,
                scenario: scenario, raw: raw)
        } catch let error as ResultsLogError {
            ConsoleOut.err(error.message)
            throw ExitCode(1)
        }

        for (offset, section) in sections.enumerated() {
            // --raw の stdout は NDJSON だけにする(jq 等へ流せるように)。見出しは stderr へ
            if raw {
                ConsoleOut.err("=== \(section.heading) ===")
            } else {
                if offset > 0 { ConsoleOut.out("") }
                ConsoleOut.out("=== \(section.heading) ===")
            }
            if let path = section.unreadablePath {
                ConsoleOut.err("failed to read: \(path)")
                continue
            }
            for line in section.lines { ConsoleOut.out(line) }
        }
    }
}

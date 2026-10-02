// ft_results: 引数の検査と、実エンコーダで書いた結果ディレクトリからの出力。
// 表の文面そのものは FTCore.ResultsRendering(FTCoreTests/ResultsRenderingTests)が持つ。
// ここは「CLI と同じ関数を通っていること」と入口の検査を固定する。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPResultsToolTests: XCTestCase {

    private var root: URL!
    private var project: TestProject!
    private var server: MCPServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-results-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scenarios"), withIntermediateDirectories: true)
        project = TestProject(name: "Shop", rootURL: root)
        server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var resultsDir: URL { RunResultsStore.resultsDir(projectRoot: root) }

    /// 1 run ぶんを書く。runID の先頭は日付(月ディレクトリの決定に使われる)なので今日の日付で作る
    @discardableResult
    private func writeRun(offset: TimeInterval, passed: Bool, scenario: String = "Cart.add") -> String {
        let when = Date().addingTimeInterval(offset)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let runID = stamp.string(from: when) + "Z-" + UUID().uuidString.prefix(8).lowercased()
        let startedAt = ISO8601DateFormatter().string(from: when)
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        RunResultsStore.writeMeta(
            RunMetaRecord(runID: runID, project: "Shop", profile: "smoke", host: "h", trigger: "cli",
                          startedAt: startedAt, finishedAt: startedAt, pid: 1, total: 1,
                          passed: passed ? 1 : 0, failed: passed ? 0 : 1),
            runDir: runDir)
        RunResultsStore.writeScenario(
            ScenarioRunRecord(runID: runID, scenarioID: scenario, platform: "ios", host: "h",
                              passed: passed, startedAt: startedAt, durationMs: 1200,
                              steps: StepCountsRecord(total: 1, passed: passed ? 1 : 0)),
            runDir: runDir, fileName: scenario)
        return runID
    }

    private func request(_ args: [String: Any]) throws -> MCPResultsRequest {
        try MCPResultsRequest.parse(args)
    }

    // MARK: - 出力(CLI と同じ関数を通る)

    func testListMatchesTheSharedRenderer() throws {
        writeRun(offset: -60, passed: true)
        let newest = writeRun(offset: -30, passed: false)
        let out = try request(["query": "list"]).render(project: project)
        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir)
        XCTAssertEqual(out, ResultsRendering.list(RunResultsQuery.recentRuns(runs, limit: 20)))
        XCTAssertTrue(out.hasPrefix("runID"), out)
        XCTAssertTrue(out.contains(newest), out)
        XCTAssertTrue(out.contains("0/1/1"), out)
    }

    func testListLimitIsHonoured() throws {
        for index in 0..<3 { writeRun(offset: TimeInterval(-60 * (index + 1)), passed: true) }
        let out = try request(["query": "list", "limit": 2]).render(project: project)
        XCTAssertEqual(out.split(separator: "\n").count, 4, "ヘッダ + 区切り + 2行: \(out)")
    }

    func testSummaryFlakyTrendDevicesSlowInsightsRenderFromRealRecords() throws {
        for (index, passed) in [true, false, true, false, true, false].enumerated() {
            writeRun(offset: TimeInterval(-600 + index * 60), passed: passed)
        }
        let summary = try request(["query": "summary"]).render(project: project)
        XCTAssertTrue(summary.contains("Cart.add"), summary)
        XCTAssertTrue(summary.contains("50.0%"), summary)
        let flaky = try request(["query": "flaky"]).render(project: project)
        XCTAssertTrue(flaky.contains("Cart.add"), flaky)
        let trend = try request(["query": "trend", "scenario": "Cart.add"]).render(project: project)
        XCTAssertEqual(trend.split(separator: "\n").count, 8, "ヘッダ + 区切り + 6行: \(trend)")
        XCTAssertTrue(try request(["query": "devices"]).render(project: project).hasPrefix("[per worker]"))
        XCTAssertTrue(try request(["query": "slow"]).render(project: project).contains("Cart.add"))
        // 結果は書けているので「何もない」文言ではない(insights の中身は RunResultsQuery のテストの担当)
        XCTAssertFalse(try request(["query": "insights"]).render(project: project).isEmpty)
    }

    func testEmptyResultsUseTheCLIEmptyMessages() throws {
        XCTAssertEqual(try request(["query": "list"]).render(project: project), "No matching runs")
        XCTAssertEqual(try request(["query": "summary"]).render(project: project), "No matching scenarios")
        XCTAssertEqual(try request(["query": "devices"]).render(project: project), "No matching runs")
        XCTAssertEqual(try request(["query": "insights"]).render(project: project), "Nothing needs attention")
        XCTAssertEqual(try request(["query": "trend", "scenario": "X.y"]).render(project: project),
                       "No run history for: X.y")
        // 空のときの文言は MCP の引数名(--min-runs ではない)で言う
        XCTAssertEqual(try request(["query": "flaky", "minRuns": 3]).render(project: project),
                       "No flaky scenarios (candidates need minRuns 3+ and mixed pass/fail)")
    }

    func testSinceNarrowsTheWindowAndARejectedSinceIsNamed() throws {
        writeRun(offset: -3 * 86_400, passed: true)
        XCTAssertEqual(try request(["query": "list", "since": "1h"]).render(project: project), "No matching runs")
        XCTAssertNotEqual(try request(["query": "list", "since": "7d"]).render(project: project), "No matching runs")
        XCTAssertThrowsError(try request(["query": "list", "since": "yesterday"]).render(project: project)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("since must be a duration"), $0.localizedDescription)
        }
    }

    // MARK: - log

    func testLogResolvesLatestAndFormatsLikeTheCLI() throws {
        let older = writeRun(offset: -60, passed: true)
        let latest = writeRun(offset: -30, passed: false)
        for (runID, line) in [(older, "older-line"), (latest, "latest-line")] {
            let events = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID).appendingPathComponent("events")
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            try line.write(to: events.appendingPathComponent("Cart.add.ndjson"), atomically: true, encoding: .utf8)
        }
        let sections = try ResultsLogReport.build(
            resultsDir: resultsDir, projectName: "Shop", requestedRunID: "latest", scenario: nil, raw: false)
        let out = try request(["query": "log"]).render(project: project)
        XCTAssertEqual(out, ResultsLogReport.text(sections))
        XCTAssertTrue(out.hasPrefix("=== Cart.add ==="), out)
        let byID = try request(["query": "log", "runId": older, "scenario": "Cart.add"]).render(project: project)
        XCTAssertTrue(byID.hasPrefix("=== Cart.add ==="), byID)
        XCTAssertNotEqual(byID, out)
    }

    func testLogFailuresBecomeMCPErrorsWithTheCLIMessages() throws {
        XCTAssertThrowsError(try request(["query": "log"]).render(project: project)) {
            XCTAssertEqual($0.localizedDescription, "no runs found for project: Shop")
        }
        let runID = writeRun(offset: -30, passed: true)
        XCTAssertThrowsError(try request(["query": "log", "runId": "nope"]).render(project: project)) {
            XCTAssertEqual($0.localizedDescription, "run not found: nope")
        }
        XCTAssertThrowsError(try request(["query": "log", "runId": runID]).render(project: project)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("this run has no execution log"), $0.localizedDescription)
        }
    }

    // MARK: - 引数の検査

    func testQueryIsRequiredAndMustBeKnown() async {
        for (args, expected) in [
            ([String: Any](), "query is required"),
            (["query": "nope"], "query must be one of: list, summary, flaky, trend, devices, slow, insights, log"),
            (["query": ""], "query must not be empty"),
            (["query": 3], "query must be a string"),
        ] as [([String: Any], String)] {
            do {
                _ = try await server.call(tool: "ft_results", args: args)
                XCTFail("\(args) は断られるはず")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(args): \(error.localizedDescription)")
            }
        }
    }

    func testIntegerBoundsAreEnforcedAtTheEntrance() async {
        for (key, value) in [("limit", 0), ("limit", -1), ("minRuns", 0)] {
            do {
                _ = try await server.call(tool: "ft_results", args: ["query": "list", key: value])
                XCTFail("\(key)=\(value) は断られるはず")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("\(key) must be 1 or more"),
                              error.localizedDescription)
            }
        }
        do {
            _ = try await server.call(tool: "ft_results", args: ["query": "list", "limit": "5"])
            XCTFail("文字列の limit は断られるはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("limit must be an integer"), error.localizedDescription)
        }
    }

    func testArgumentsThatTheQueryDoesNotReadAreRefused() {
        for (args, argument) in [
            (["query": "list", "scenario": "A.b"], "scenario"),
            (["query": "summary", "runId": "r"], "runId"),
            (["query": "flaky", "limit": 3], "limit"),
            (["query": "slow", "minRuns": 3], "minRuns"),
            (["query": "log", "since": "1d"], "since"),
        ] as [([String: Any], String)] {
            XCTAssertThrowsError(try request(args)) {
                XCTAssertTrue($0.localizedDescription.hasPrefix("\(argument) does not apply"), "\(args): \($0)")
            }
        }
    }

    func testTrendNeedsAScenario() {
        XCTAssertThrowsError(try request(["query": "trend"])) {
            XCTAssertEqual($0.localizedDescription, "scenario is required for query trend")
        }
        XCTAssertThrowsError(try request(["query": "trend", "scenario": "  "])) {
            XCTAssertEqual($0.localizedDescription, "scenario must not be empty")
        }
    }
}

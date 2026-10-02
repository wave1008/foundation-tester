// `fleetest results <sub>` と MCP の ft_results が共有する出力(ResultsRendering)の文面を固定する。
// 列・見出し・空のときの文言が変わると CLI の出力が変わるので、小さな fixture で完全一致を取る。

import XCTest
@testable import FTCore

final class ResultsRenderingTests: XCTestCase {

    // MARK: - SimpleTable

    func testRenderAlignsColumnsToWidestCell() {
        let table = SimpleTable.render(
            headers: ["id", "result"],
            rows: [["S0010", "passed"], ["S1", "failed"]])
        let lines = table.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 4, "ヘッダ + 区切り + 行数")
        // 区切り行の各列幅が、その列の最長セルに一致する
        XCTAssertEqual(lines[1], "-----  ------")
        // 短いセルは右側が空白で埋まる(列開始位置が揃う)
        XCTAssertTrue(lines[3].hasPrefix("S1     "), "実際: \(lines[3])")
    }

    func testRenderUsesHeaderWidthWhenRowsAreShorter() {
        let table = SimpleTable.render(headers: ["scenario"], rows: [["S1"]])
        XCTAssertEqual(table.split(separator: "\n")[1], "--------")
    }

    func testRenderToleratesRowsWithMissingCells() {
        // 列数が足りない行が来ても落ちない(空セル扱い)
        let table = SimpleTable.render(headers: ["a", "b", "c"], rows: [["1"]])
        XCTAssertEqual(table.split(separator: "\n").count, 3)
    }

    func testRenderWithNoRowsStillEmitsHeaderAndSeparator() {
        let table = SimpleTable.render(headers: ["id"], rows: [])
        XCTAssertEqual(table.split(separator: "\n").map(String.init), ["id", "--"])
    }

    // MARK: - formatLocal

    func testFormatLocalRendersISO8601AsLocalTime() {
        // 表示はローカル時刻。壁時計の桁形だけを確認する(TZ 依存の値そのものは見ない)
        let formatted = formatLocal("2026-07-29T10:20:30Z")
        XCTAssertNotEqual(formatted, "2026-07-29T10:20:30Z", "ISO 文字列のまま返してはいけません")
        XCTAssertEqual(formatted.count, 19, "yyyy-MM-dd HH:mm:ss: \(formatted)")
        XCTAssertTrue(formatted.contains(":"))
    }

    func testFormatLocalPassesThroughUnparsableInput() {
        // 壊れた値でも表示は止めない(結果一覧が1行の異常で全滅しないため)
        XCTAssertEqual(formatLocal("not-a-date"), "not-a-date")
        XCTAssertEqual(formatLocal(""), "")
    }

    // MARK: - 既定値(CLI の --since / --limit / --min-runs と MCP が引く)

    func testDefaultsArePinned() {
        XCTAssertEqual(ResultsRendering.defaultSince, "90d")
        XCTAssertEqual(ResultsRendering.defaultListLimit, 20)
        XCTAssertEqual(ResultsRendering.defaultSlowLimit, 10)
        XCTAssertEqual(ResultsRendering.defaultMinRuns, 5)
    }

    // MARK: - fixture

    private let started = "2026-09-28T00:00:00Z"

    private func record(_ scenario: String, passed: Bool, durationMs: Int, runID: String = "r1",
                        worker: String? = "iPhone", startedAt: String? = nil) -> ScenarioRunRecord {
        ScenarioRunRecord(runID: runID, scenarioID: scenario, platform: "ios", worker: worker, host: "h",
                          passed: passed, startedAt: startedAt ?? started, durationMs: durationMs,
                          steps: StepCountsRecord(total: 2, passed: passed ? 2 : 1))
    }

    /// 行を列のセルへ分ける(列の区切りは2個以上の空白。セル自身は連続した空白を持たない)
    private func cells(_ line: String) -> [String] {
        line.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    // MARK: - list

    func testListRendersCountsAndMarksIncompleteRuns() {
        let done = RunMetaRecord(runID: "r2", project: "Shop", profile: "smoke", host: "m1", trigger: "cli",
                                 startedAt: started, total: 3, passed: 2, failed: 1)
        let open = RunMetaRecord(runID: "r1", project: "Shop", profile: nil, host: "m1", trigger: "api",
                                 startedAt: started)
        let out = lines(ResultsRendering.list([done, open]))
        XCTAssertEqual(cells(out[0]), ["runID", "time", "trigger", "profile", "machine", "passed/failed/total"])
        XCTAssertEqual(cells(out[2]), ["r2", formatLocal(started), "cli", "smoke", "m1", "2/1/3"])
        XCTAssertEqual(cells(out[3]), ["r1", formatLocal(started), "api", "-", "m1", "(incomplete)"])
        XCTAssertEqual(ResultsRendering.list([]), "No matching runs")
    }

    // MARK: - summary

    func testSummaryRendersRatesAndLastResult() {
        let rows = RunResultsQuery.scenarioSummary(
            [record("Cart.add", passed: true, durationMs: 100, startedAt: "2026-09-27T00:00:00Z"),
             record("Cart.add", passed: false, durationMs: 300)], recentRuns: .max)
        let out = lines(ResultsRendering.summary(rows))
        XCTAssertEqual(cells(out[0]),
                       ["scenario", "runs", "pass rate", "avg ms", "median ms", "last run", "last result"])
        XCTAssertEqual(cells(out[2]), ["Cart.add", "2", "50.0%", "200", "200", formatLocal(started), "❌"])
        XCTAssertEqual(ResultsRendering.summary([]), "No matching scenarios")
    }

    // MARK: - flaky

    func testFlakyRendersRecentResultsAndNamesTheOptionInTheEmptyMessage() {
        let records = [true, false, true, false].enumerated().map { index, passed in
            record("Cart.add", passed: passed, durationMs: 10,
                   startedAt: "2026-09-2\(index)T00:00:00Z")
        }
        let rows = RunResultsQuery.flakyScenarios(records, minRuns: 2, recentRuns: .max)
        let out = lines(ResultsRendering.flaky(rows, minRuns: 2))
        XCTAssertEqual(cells(out[0]), ["scenario", "runs", "fail rate", "flip score", "recent results (new→old)"])
        XCTAssertEqual(Array(cells(out[2]).prefix(3)), ["Cart.add", "4", "50.0%"])
        XCTAssertEqual(cells(out[2]).last, "❌✅❌✅")
        XCTAssertEqual(ResultsRendering.flaky([], minRuns: 5),
                       "No flaky scenarios (candidates need --min-runs 5+ and mixed pass/fail)")
        XCTAssertEqual(ResultsRendering.flaky([], minRuns: 5, minRunsOption: "minRuns"),
                       "No flaky scenarios (candidates need minRuns 5+ and mixed pass/fail)")
    }

    // MARK: - trend

    func testTrendDrawsBarsRelativeToTheLongestRun() {
        let rows = [record("Cart.add", passed: true, durationMs: 50),
                    record("Cart.add", passed: false, durationMs: 100, worker: nil)]
        let out = lines(ResultsRendering.trend(rows, scenario: "Cart.add"))
        XCTAssertEqual(cells(out[0]), ["startedAt", "runID", "passed", "durationMs", "worker", "machine", "bar"])
        XCTAssertEqual(cells(out[2]), [formatLocal(started), "r1", "✅", "50", "iPhone", "h",
                                       String(repeating: "█", count: 10)])
        XCTAssertEqual(cells(out[3]), [formatLocal(started), "r1", "❌", "100", "-", "h",
                                       String(repeating: "█", count: 20)])
        XCTAssertEqual(ResultsRendering.trend([], scenario: "X.y"), "No run history for: X.y")
    }

    // MARK: - devices

    func testDevicesRendersBothSectionsAndTheEmptyMessage() {
        let report = RunResultsQuery.deviceSummary([
            record("A.a", passed: true, durationMs: 100), record("A.b", passed: false, durationMs: 300),
        ])
        let trimmed = lines(ResultsRendering.devices(report)).map {
            $0.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }
        XCTAssertEqual(trimmed, [
            "[per worker]",
            "worker  runs  pass rate  avg ms",
            "------  ----  ---------  ------",
            "iPhone  2     50.0%      200",
            "",
            "[per platform]",
            "platform  runs  pass rate  avg ms",
            "--------  ----  ---------  ------",
            "ios       2     50.0%      200",
        ])
        XCTAssertEqual(ResultsRendering.devices(RunResultsQuery.deviceSummary([])), "No matching runs")
    }

    // MARK: - slow

    func testSlowRendersPlatformAndRegressionColumns() {
        let rows = RunResultsQuery.slowTests(
            [record("Cart.add", passed: true, durationMs: 100), record("Cart.add", passed: true, durationMs: 300)],
            limit: 5)
        let out = lines(ResultsRendering.slow(rows))
        XCTAssertEqual(cells(out[0]),
                       ["scenario", "platform", "runs", "avg ms", "p90 ms", "regression", "slowest scene"])
        XCTAssertEqual(Array(cells(out[2]).prefix(4)), ["Cart.add", "ios", "2", "200"])
        XCTAssertEqual(ResultsRendering.slow([]), "No matching scenarios")
    }

    // MARK: - insights

    func testInsightsRendersOneIconLinePerRowAndAnEmptyMessage() {
        func row(_ severity: String, _ message: String) -> RunResultsQuery.InsightRow {
            RunResultsQuery.InsightRow(kind: "k", severity: severity, scenarioID: nil, platform: nil,
                                       worker: nil, message: message, count: nil, deltaPct: nil)
        }
        XCTAssertEqual(
            ResultsRendering.insights([row("critical", "a"), row("warn", "b"), row("info", "c")]),
            "🔴 a\n🟡 b\n🔵 c")
        XCTAssertEqual(ResultsRendering.insights([]), "Nothing needs attention")
    }
}

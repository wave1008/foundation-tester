// 子が対象外を宣言したシナリオ(scenarioFinished.notApplicableReason)は、緑でも赤でもない
// 「skipped」として表示・集計・統計に出る。ここは FTCore 側の純粋な部分(コンソール行・RunSummary・統計)。
// 同期相手: NDJSON(ApiRunNDJSONPathParityTests)・fan-out(ApiRunMachineFanoutMultiplexerTests)・
// 拡張(vscode-fleetest/test/runReducer.test.mjs)。

import XCTest
@testable import FTCore

final class ChildDeclaredNotApplicableCountingTests: XCTestCase {
    private let url = URL(string: "scenario://T/S0010")!

    func testConsoleLineIsSkippedNotPassed() {
        let lines = RunLogFormatter.lines(for: .flowFinished(
            worker: "ios:1", flowURL: url, passed: true, reportURL: nil, fm: nil, appCrash: nil,
            notApplicableReason: "no biometrics"))
        XCTAssertEqual(lines.first, "  → ⏭ skipped (not applicable): no biometrics")
        XCTAssertFalse(lines.joined().contains("✅"))
    }

    func testPassedAndFailedConsoleLinesAreUnchanged() {
        XCTAssertEqual(RunLogFormatter.lines(for: .flowFinished(
            worker: "ios:1", flowURL: url, passed: true, reportURL: nil, fm: nil, appCrash: nil,
            notApplicableReason: nil)).first, "  → ✅ passed")
        XCTAssertEqual(RunLogFormatter.lines(for: .flowFinished(
            worker: "ios:1", flowURL: url, passed: false, reportURL: nil, fm: nil, appCrash: nil,
            notApplicableReason: nil)).first, "  → ❌ failed")
    }

    func testSummaryCountsSkippedInsideTotalButNotAsPassed() {
        let summary = RunSummary(total: 5, failed: 1, skipped: 2)
        XCTAssertEqual(summary.passed, 2)
        XCTAssertEqual(summary.passed + summary.failed + summary.skipped, summary.total)
        XCTAssertEqual(RunSummary(total: 3, failed: 0).skipped, 0)
    }

    // MARK: - 統計(成功率・所要)から外す

    private func record(_ id: String, passed: Bool, skip: ScenarioSkipKind?, at offset: Int) -> ScenarioRunRecord {
        ScenarioRunRecord(runID: "r\(offset)", scenarioID: id, platform: "ios", host: "h",
                          passed: passed, startedAt: String(format: "2026-10-12T00:00:%02dZ", offset),
                          durationMs: 100, steps: StepCountsRecord(), skipKind: skip)
    }

    func testDeclaredNotApplicableIsExcludedFromSuccessRate() {
        let records = [
            record("A.t", passed: true, skip: nil, at: 1),
            record("A.t", passed: false, skip: nil, at: 2),
            record("A.t", passed: true, skip: .notApplicable, at: 3),
            record("A.t", passed: true, skip: .notApplicable, at: 4),
        ]
        let row = RunResultsQuery.scenarioSummary(records, recentRuns: 10).first
        XCTAssertEqual(row?.runs, 2, "宣言した回は標本に入れない")
        XCTAssertEqual(row?.successRate, 50)
        let onlySkipped = records.filter { $0.skipKind == .notApplicable }
        XCTAssertTrue(RunResultsQuery.scenarioSummary(onlySkipped, recentRuns: 10).isEmpty)
        XCTAssertTrue(RunResultsQuery.isDeclaredNotApplicable(onlySkipped[0]))
        XCTAssertFalse(RunResultsQuery.isDeclaredNotApplicable(records[0]))
    }
}

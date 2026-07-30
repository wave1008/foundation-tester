// JUnit XML 出力(--junit)。CI ツールが機械で読む契約なので、構造・集計・エスケープを
// 手書きレコードで固める(実 run での妥当性検証は xmllint で別途行う)。

import XCTest
@testable import FTCore

final class JUnitReportWriterTests: XCTestCase {

    private func record(id: String, passed: Bool, durationMs: Int = 1000,
                        steps: StepCountsRecord = StepCountsRecord(total: 3, passed: 3),
                        failedSteps: [FailedStepRecord]? = nil,
                        errorLogs: [String]? = nil,
                        timedOut: Bool? = nil,
                        reportPath: String? = nil,
                        worker: String? = nil) -> ScenarioRunRecord {
        ScenarioRunRecord(runID: "r1", scenarioID: id, platform: "ios", worker: worker,
                          passed: passed, timedOut: timedOut,
                          startedAt: "2026-07-30T00:00:00Z", durationMs: durationMs,
                          steps: steps, reportPath: reportPath,
                          failedSteps: failedSteps, errorLogs: errorLogs)
    }

    func testAggregatesCountsAndGroupsByClass() {
        let xml = JUnitReportWriter.xml(project: "E2E", records: [
            record(id: "ログイン.S0010", passed: true, durationMs: 1500),
            record(id: "ログイン.S0020", passed: false, durationMs: 500,
                   steps: StepCountsRecord(total: 3, passed: 1, failed: 1, skipped: 1),
                   failedSteps: [FailedStepRecord(index: 2, description: ##"exist "#ok""##,
                                                 detail: "element not found")]),
            record(id: "設定.S0010", passed: true, durationMs: 1000),
        ])
        XCTAssertTrue(xml.contains(
            #"<testsuites name="E2E" tests="3" failures="1" errors="0" skipped="0" time="3.000">"#), xml)
        XCTAssertTrue(xml.contains(
            #"<testsuite name="ログイン" tests="2" failures="1" errors="0" skipped="0" time="2.000">"#), xml)
        XCTAssertTrue(xml.contains(
            #"<testsuite name="設定" tests="1" failures="0" errors="0" skipped="0" time="1.000">"#), xml)
        XCTAssertTrue(xml.contains(#"<testcase classname="ログイン" name="S0010" time="1.500"/>"#), xml)
    }

    func testFailureCarriesMessageDetailLocationAndReport() throws {
        let xml = JUnitReportWriter.xml(project: "E2E", records: [
            record(id: "A.f", passed: false,
                   steps: StepCountsRecord(total: 2, passed: 1, failed: 1),
                   failedSteps: [FailedStepRecord(index: 2, description: "tap \"x\"",
                                                 detail: "element not found: id=x",
                                                 file: "A.swift", line: 12)],
                   errorLogs: ["❌ bridge unreachable"],
                   reportPath: "Projects/E2E/reports/a.md",
                   worker: "ios:iPhone 17")])
        XCTAssertTrue(xml.contains(
            #"<failure message="tap &quot;x&quot; — element not found: id=x">"#), xml)
        XCTAssertTrue(xml.contains("at A.swift:12"), xml)
        XCTAssertTrue(xml.contains("error logs:"), xml)
        XCTAssertTrue(xml.contains("report: Projects/E2E/reports/a.md"), xml)
        XCTAssertTrue(xml.contains("worker: ios:iPhone 17"), xml)
    }

    /// recordSkipped の形(全ステップ skipped・failed 0)は failure ではなく skipped
    func testSkippedRecordBecomesSkippedNotFailure() {
        let xml = JUnitReportWriter.xml(project: "E2E", records: [
            record(id: "A.s", passed: false, durationMs: 0,
                   steps: StepCountsRecord(total: 1, skipped: 1),
                   failedSteps: [FailedStepRecord(index: 0, description: "no worker available")]),
        ])
        XCTAssertTrue(xml.contains(#"skipped="1""#), xml)
        XCTAssertTrue(xml.contains(#"<skipped message="no worker available"/>"#), xml)
        XCTAssertFalse(xml.contains("<failure"), xml)
    }

    /// 途中まで走って中断(skipped>0 でも failed>0)は skipped ではなく failure
    func testAbortedMidRunIsFailureEvenWithSkippedSteps() {
        let xml = JUnitReportWriter.xml(project: "E2E", records: [
            record(id: "A.f", passed: false,
                   steps: StepCountsRecord(total: 5, passed: 2, failed: 1, skipped: 2),
                   failedSteps: [FailedStepRecord(index: 3, description: "tap \"x\"")]),
        ])
        XCTAssertTrue(xml.contains(#"failures="1""#), xml)
        XCTAssertTrue(xml.contains(#"skipped="0""#), xml)
    }

    func testTimedOutIsCalledOutInTheMessage() {
        let xml = JUnitReportWriter.xml(project: "E2E", records: [
            record(id: "A.t", passed: false,
                   steps: StepCountsRecord(total: 1, failed: 1),
                   failedSteps: [FailedStepRecord(index: 1, description: "wait")],
                   timedOut: true),
        ])
        XCTAssertTrue(xml.contains(#"message="timed out — wait""#), xml)
    }

    /// XML 予約文字は属性・本文の両方でエスケープされる(壊れた XML は CI 側で全滅する)
    func testEscapesReservedCharactersEverywhere() {
        let xml = JUnitReportWriter.xml(project: "a<b>&\"'", records: [
            record(id: #"C<&>."お"'x'"#, passed: false,
                   steps: StepCountsRecord(total: 1, failed: 1),
                   failedSteps: [FailedStepRecord(index: 1, description: "a<b & \"c\"",
                                                 detail: "d>'e'")]),
        ])
        XCTAssertTrue(xml.contains(#"name="a&lt;b&gt;&amp;&quot;&apos;""#), xml)
        XCTAssertTrue(xml.contains(#"classname="C&lt;&amp;&gt;""#), xml)
        XCTAssertTrue(xml.contains("a&lt;b &amp; &quot;c&quot;"), xml)
        // 生の予約文字が(タグ・宣言以外に)残っていないこと
        let stripped = xml
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "").replacingOccurrences(of: "&lt;", with: "")
            .replacingOccurrences(of: "&gt;", with: "").replacingOccurrences(of: "&quot;", with: "")
            .replacingOccurrences(of: "&apos;", with: "")
        XCTAssertFalse(stripped.contains("<") || stripped.contains("&"), stripped)
    }

    func testDotlessScenarioIDUsesWholeIDAsClassAndName() {
        let xml = JUnitReportWriter.xml(project: "P", records: [record(id: "solo", passed: true)])
        XCTAssertTrue(xml.contains(#"<testsuite name="solo""#), xml)
        XCTAssertTrue(xml.contains(#"<testcase classname="solo" name="solo""#), xml)
    }

    func testEmptyRecordsStillProduceValidEnvelope() {
        let xml = JUnitReportWriter.xml(project: "P", records: [])
        XCTAssertTrue(xml.contains(#"tests="0""#), xml)
        XCTAssertTrue(xml.hasPrefix("<?xml"), xml)
        XCTAssertTrue(xml.contains("</testsuites>"), xml)
    }

    /// 出力は決定的(クラス・scenarioID ソート)。CI の差分比較・キャッシュが揺れない
    func testOutputIsDeterministicRegardlessOfInputOrder() {
        let a = [record(id: "B.x", passed: true), record(id: "A.y", passed: true),
                 record(id: "A.x", passed: true)]
        XCTAssertEqual(JUnitReportWriter.xml(project: "P", records: a),
                       JUnitReportWriter.xml(project: "P", records: a.reversed()))
    }

    // MARK: - RunResultsStore.records(runDir:)(--junit の入力経路)

    func testRecordsReadsBackWhatWasWrittenAndSkipsCorrupt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-junit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        RunResultsStore.writeScenario(record(id: "A.x", passed: true), runDir: dir, fileName: "A.x")
        RunResultsStore.writeScenario(record(id: "A.y", passed: false,
                                             steps: StepCountsRecord(total: 1, failed: 1),
                                             failedSteps: [FailedStepRecord(index: 1, description: "f")]),
                                      runDir: dir, fileName: "A.y")
        // 壊れたファイルと新しすぎる schemaVersion は黙って飛ばす
        try Data("not json".utf8).write(
            to: dir.appendingPathComponent("scenarios/broken.json"))
        var future = record(id: "A.z", passed: true)
        future.schemaVersion = RunRecordSchema.current + 1
        RunResultsStore.writeScenario(future, runDir: dir, fileName: "A.z")

        let loaded = RunResultsStore.records(runDir: dir)
        XCTAssertEqual(loaded.map(\.scenarioID), ["A.x", "A.y"])
    }
}

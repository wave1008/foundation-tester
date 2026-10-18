import XCTest
@testable import FTCore

final class ResponseMeasurementQueryTests: XCTestCase {

    private func meta(_ runID: String, host: String = "hostA", startedAt: String,
                      device: String? = "dev", serial: String? = nil) -> RunMetaRecord {
        var m = RunMetaRecord(runID: runID, project: "p", profile: nil, host: host, trigger: "cli", startedAt: startedAt)
        if let device {
            m.responseMeasurement = ResponseMeasurementRunInfo(
                deviceName: device, serial: serial, model: nil, osVersion: nil, repeatCount: 5)
        }
        return m
    }

    private func step(_ description: String, ms: Int? = nil, busy: Bool = false,
                      missing: ResponseMeasurementRecord.FirstFrameMissing? = nil,
                      command: String? = "tap") -> TimelineStepRecord {
        TimelineStepRecord(scene: 1, section: "action", index: 0, description: description, status: "passed",
                           command: command,
                           response: ResponseMeasurementRecord(busyBeforeAction: busy, quietWaitMs: nil,
                                                               firstFrameMs: ms, firstFrameMissing: missing))
    }

    private func record(_ runID: String, scenario: String = "S", startedAt: String = "2026-10-01T00:00:00Z",
                        _ steps: [TimelineStepRecord]) -> ScenarioRunRecord {
        ScenarioRunRecord(runID: runID, scenarioID: scenario, platform: "android", host: "hostA", passed: true,
                          startedAt: startedAt, durationMs: 1,
                          steps: StepCountsRecord(total: 1, passed: 1, failed: 0), timeline: steps)
    }

    func testNonMeasurementRunsAreIgnored() {
        let rows = ResponseMeasurementQuery.rows(
            runs: [meta("r1", startedAt: "2026-10-01T00:00:00Z", device: nil)],
            records: [record("r1", [step("a", ms: 10)])])
        XCTAssertTrue(rows.isEmpty)
    }

    func testOccurrenceDistinguishesIdenticalSteps() {
        let rows = ResponseMeasurementQuery.rows(
            runs: [meta("r1", startedAt: "2026-10-01T00:00:00Z")],
            records: [record("r1", [step("Tap", ms: 100), step("Tap", ms: 500)])])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.medianMs), [100, 500])
        XCTAssertEqual(rows[0].step, "s1 action tap Tap #1")
        XCTAssertEqual(rows[1].step, "s1 action tap Tap #2")
    }

    func testRepeatedRecordsInRunArePooledWithMedianAndP90() {
        let records = (1...10).map { record("r1", startedAt: "2026-10-01T00:00:\(String(format: "%02d", $0))Z", [step("Tap", ms: $0 * 10)]) }
        let rows = ResponseMeasurementQuery.rows(runs: [meta("r1", startedAt: "2026-10-01T00:00:00Z")], records: records)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].n, 10)
        XCTAssertEqual(rows[0].medianMs, 55)   // 偶数個は中央2つの平均
        XCTAssertEqual(rows[0].p90Ms, 90)      // 最近接順位法: ceil(0.9*10)=9 番目
    }

    func testBusyAndMissingCounts() {
        let rows = ResponseMeasurementQuery.rows(
            runs: [meta("r1", startedAt: "2026-10-01T00:00:00Z")],
            records: [record("r1", [step("Tap", ms: 100)]),
                      record("r1", startedAt: "2026-10-01T00:00:01Z", [step("Tap", busy: true, missing: .busyBeforeAction)]),
                      record("r1", startedAt: "2026-10-01T00:00:02Z", [step("Tap", missing: .noFrame)]),
                      record("r1", startedAt: "2026-10-01T00:00:03Z", [step("Tap")])])
        XCTAssertEqual(rows[0].n, 1)
        XCTAssertEqual(rows[0].busyCount, 1)
        XCTAssertEqual(rows[0].missingCounts, ["busyBeforeAction": 1, "noFrame": 1])
    }

    func testPreviousRunIsImmediatelyPreviousOnSameHostAndDevice() {
        let runs = [
            meta("r1", startedAt: "2026-10-01T00:00:00Z"),
            meta("r2", startedAt: "2026-10-02T00:00:00Z", device: "other"),
            meta("r3", host: "hostB", startedAt: "2026-10-03T00:00:00Z"),
            meta("r4", startedAt: "2026-10-04T00:00:00Z"),
            meta("r5", startedAt: "2026-10-05T00:00:00Z"),
        ]
        let records = [record("r1", [step("Tap", ms: 900)]), record("r2", [step("Tap", ms: 1)]),
                       record("r3", [step("Tap", ms: 2)]), record("r4", [step("Tap", ms: 100)]),
                       record("r5", [step("Tap", ms: 150)])]
        let rows = ResponseMeasurementQuery.rows(runs: runs, records: records)
        let target = rows.first { $0.host == "hostA" && $0.device == "dev" }!
        XCTAssertEqual(target.runID, "r5")
        XCTAssertEqual(target.previousRunID, "r4")
        XCTAssertEqual(target.deltaMs, 50)
        XCTAssertEqual(target.deltaPct, 50)
        // 別デバイス・別機械は単独の行で、前回を持たない
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows.first { $0.device == "other" }!.previousRunID)
        XCTAssertNil(rows.first { $0.host == "hostB" }!.previousRunID)
    }

    func testSerialIsDeviceIdentityAndRowsAreDeterministic() {
        let runs = [meta("r1", startedAt: "2026-10-01T00:00:00Z", device: "name", serial: "SER1")]
        let records = [record("r1", scenario: "B", [step("x", ms: 1)]),
                       record("r1", scenario: "A", [step("second", ms: 2), step("first", ms: 3)])]
        let a = ResponseMeasurementQuery.rows(runs: runs, records: records)
        let b = ResponseMeasurementQuery.rows(runs: runs, records: records.reversed())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.map(\.scenarioID), ["A", "A", "B"])
        XCTAssertEqual(a.map(\.device), ["SER1", "SER1", "SER1"])
        XCTAssertTrue(a[0].step.contains("second"))   // 初出順(説明の辞書順ではない)
    }

    func testRenderingEmptyAndRow() {
        XCTAssertEqual(ResultsRendering.response([]), "No response-measurement runs found")
        let rows = ResponseMeasurementQuery.rows(
            runs: [meta("r1", startedAt: "2026-10-01T00:00:00Z")], records: [record("r1", [step("Tap", ms: 100)])])
        let out = ResultsRendering.response(rows)
        XCTAssertTrue(out.contains("prev median ms"))
        XCTAssertTrue(out.contains("s1 action tap Tap #1"))
        for header in ["ready n", "ready median ms", "ready p90 ms"] {
            XCTAssertTrue(out.contains(header), header)
        }
    }

    private func readyStep(_ description: String, readyMs: Int? = nil, missing: String? = nil) -> TimelineStepRecord {
        TimelineStepRecord(scene: 1, section: "action", index: 0, description: description, status: "passed",
                           command: "tap",
                           response: ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: nil, firstFrameMs: 40,
                                                               firstFrameMissing: nil, readyMs: readyMs,
                                                               readyMissing: missing))
    }

    func testReadyAggregationCountsSamplesAndMissingReasons() {
        let records = [
            record("r1", startedAt: "2026-10-01T00:00:01Z", [readyStep("Tap", readyMs: 100)]),
            record("r1", startedAt: "2026-10-01T00:00:02Z", [readyStep("Tap", readyMs: 300)]),
            record("r1", startedAt: "2026-10-01T00:00:03Z", [readyStep("Tap", readyMs: 200)]),
            record("r1", startedAt: "2026-10-01T00:00:04Z", [readyStep("Tap", missing: "notReadyBeforeNextAction")]),
            record("r1", startedAt: "2026-10-01T00:00:05Z", [readyStep("Tap", missing: "notReadyBeforeNextAction")]),
            record("r1", startedAt: "2026-10-01T00:00:06Z", [readyStep("Tap", missing: "noTarget")]),
            record("r1", startedAt: "2026-10-01T00:00:07Z", [readyStep("Tap")]),   // 判定されなかった(最後の計測ステップ等)
        ]
        let rows = ResponseMeasurementQuery.rows(runs: [meta("r1", startedAt: "2026-10-01T00:00:00Z")], records: records)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].n, 7, "firstFrameMs の集計は t2 と独立")
        XCTAssertEqual(rows[0].readyN, 3)
        XCTAssertEqual(rows[0].readyMedianMs, 200)
        XCTAssertEqual(rows[0].readyP90Ms, 300)
        XCTAssertEqual(rows[0].readyMissingCounts, ["notReadyBeforeNextAction": 2, "noTarget": 1])
        let out = ResultsRendering.response(rows)
        XCTAssertTrue(out.contains("200"))
    }
}

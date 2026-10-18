// xctrace の記録から iOS 実機の最初のフレームを結果へ入れる純粋な部分。

import XCTest
@testable import FTCore

final class ResponseTracePatchTests: XCTestCase {

    // MARK: 換算

    func testNanosecondsMatchesMachTimebase() {
        // 125/3 = iPhone SE3 の例(1 tick = 41.67 ns)
        XCTAssertEqual(ResponseTracePatch.nanoseconds(ticks: 3, numer: 125, denom: 3), 125)
        XCTAssertEqual(ResponseTracePatch.nanoseconds(ticks: 24_000_000, numer: 125, denom: 3), 1_000_000_000)
        XCTAssertEqual(ResponseTracePatch.nanoseconds(ticks: 0, numer: 125, denom: 3), 0)
        XCTAssertEqual(ResponseTracePatch.nanoseconds(ticks: 7, numer: 1, denom: 1), 7)
    }

    func testNanosecondsIsExactWhereTicksTimesNumerOverflowsInt64() {
        // ticks × numer = 2^63 を超える(素朴に掛けると溢れる)が、結果は Int64 に収まる
        let ticks: UInt64 = 9_000_000_000_000_000_000
        // 9e18 × 125 / 3750 = 3e17
        XCTAssertEqual(ResponseTracePatch.nanoseconds(ticks: ticks, numer: 125, denom: 3750), 300_000_000_000_000_000)
    }

    func testNanosecondsKeepsTheRemainderTerm() {
        // 10 ticks, 125/3: 10×125/3 = 416.67 → 416(切り捨て)
        XCTAssertEqual(ResponseTracePatch.nanoseconds(ticks: 10, numer: 125, denom: 3), 416)
    }

    func testNanosecondsRefusesOverflowAndZeroDenominator() {
        XCTAssertNil(ResponseTracePatch.nanoseconds(ticks: UInt64.max, numer: 125, denom: 1))
        XCTAssertNil(ResponseTracePatch.nanoseconds(ticks: 1, numer: 1, denom: 0))
    }

    // MARK: 表の読み

    private func cell(_ raw: String, fmt: String? = nil) -> XctraceTable.Cell { .init(raw: raw, fmt: fmt) }

    func testTimeInfoReadsRawThenFmt() {
        let table = XctraceTable(columns: ["mabs-epoch", "timebase-info"], rows: [
            ["mabs-epoch": cell("1000"), "timebase-info": cell("", fmt: "125/3")],
        ])
        XCTAssertEqual(ResponseTracePatch.timeInfo(from: table),
                       ResponseTracePatch.TimeInfo(mabsEpochTicks: 1000, numer: 125, denom: 3))
        let raw = XctraceTable(columns: [], rows: [["mabs-epoch": cell("5"), "timebase-info": cell("1/1")]])
        XCTAssertEqual(ResponseTracePatch.timeInfo(from: raw)?.numer, 1)
    }

    func testTimeInfoSkipsRowsWithoutBothAndRejectsBadTimebase() {
        let table = XctraceTable(columns: [], rows: [
            ["mabs-epoch": cell("1")],
            ["mabs-epoch": cell("2"), "timebase-info": cell("x/y")],
            ["mabs-epoch": cell("3"), "timebase-info": cell("0/3")],
        ])
        XCTAssertNil(ResponseTracePatch.timeInfo(from: table))
    }

    func testSurfacesAreDeviceMillisecondsSortedWithLastEnd() {
        // epoch = 24_000_000 ticks × 125/3 = 1e9 ns = 1000 ms
        let info = ResponseTracePatch.TimeInfo(mabsEpochTicks: 24_000_000, numer: 125, denom: 3)
        let table = XctraceTable(columns: [], rows: [
            ["start": cell("300000000"), "duration": cell("2000000")],
            ["start": cell("100000000"), "duration": cell("50000000")],
            ["start": cell("bad")],
            [:],
        ])
        let out = ResponseTracePatch.surfaces(timeInfo: info, table: table)
        XCTAssertEqual(out.times, [1100, 1300])
        XCTAssertEqual(out.lastEndMs, 1302)
    }

    func testCoveragePrefersTocDurationOverLastSurface() {
        let info = ResponseTracePatch.TimeInfo(mabsEpochTicks: 24_000_000, numer: 125, denom: 3)
        XCTAssertEqual(ResponseTracePatch.coverage(timeInfo: info, durationSeconds: 10, lastSurfaceEndMs: 1302),
                       ResponseTracePatch.Coverage(startMs: 1000, endMs: 11_000))
        XCTAssertEqual(ResponseTracePatch.coverage(timeInfo: info, durationSeconds: nil, lastSurfaceEndMs: 1302),
                       ResponseTracePatch.Coverage(startMs: 1000, endMs: 1302))
        XCTAssertNil(ResponseTracePatch.coverage(timeInfo: info, durationSeconds: nil, lastSurfaceEndMs: nil))
    }

    // MARK: 当て込み

    func testFirstSurfaceIsStrictlyAfter() {
        let surfaces: [Double] = [100, 200, 200, 300]
        XCTAssertEqual(ResponseTracePatch.firstSurface(after: 200, in: surfaces), 300, "同時刻は後ではない")
        XCTAssertEqual(ResponseTracePatch.firstSurface(after: 199.9, in: surfaces), 200)
        XCTAssertEqual(ResponseTracePatch.firstSurface(after: 50, in: surfaces), 100)
        XCTAssertNil(ResponseTracePatch.firstSurface(after: 300, in: surfaces))
        XCTAssertNil(ResponseTracePatch.firstSurface(after: 1, in: []))
    }

    private func response(down: Int? = 1000, firstFrame: Int? = nil, missing: ResponseMeasurementRecord.FirstFrameMissing? = nil,
                          busy: Bool = false) -> ResponseMeasurementRecord {
        ResponseMeasurementRecord(busyBeforeAction: busy, quietWaitMs: 5, firstFrameMs: firstFrame,
                                  firstFrameMissing: missing, downTimeMs: down)
    }

    private func record(_ responses: [ResponseMeasurementRecord?]) -> ScenarioRunRecord {
        ScenarioRunRecord(
            scenarioID: "S", platform: "ios", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 1,
            steps: StepCountsRecord(total: responses.count, passed: responses.count),
            timeline: responses.enumerated().map {
                TimelineStepRecord(index: $0.offset, description: "d", status: "passed", response: $0.element)
            })
    }

    private let coverage = ResponseTracePatch.Coverage(startMs: 500, endMs: 5000)

    func testFillsFirstFrameFromTheNextSurface() {
        let out = ResponseTracePatch.apply(surfaceMs: [900, 1047.4, 2000], coverage: coverage, to: record([response()]))
        XCTAssertEqual(out.changed, 1)
        XCTAssertEqual(out.record.timeline?[0].response?.firstFrameMs, 47)
        XCTAssertNil(out.record.timeline?[0].response?.firstFrameMissing)
    }

    func testSurfaceExactlyAtDownTimeIsNotTheAnswer() {
        let out = ResponseTracePatch.apply(surfaceMs: [1000, 1030], coverage: coverage, to: record([response()]))
        XCTAssertEqual(out.record.timeline?[0].response?.firstFrameMs, 30)
    }

    func testNoFrameWhenCoveredButNothingFollows() {
        let out = ResponseTracePatch.apply(surfaceMs: [900], coverage: coverage, to: record([response()]))
        XCTAssertEqual(out.changed, 1)
        XCTAssertNil(out.record.timeline?[0].response?.firstFrameMs)
        XCTAssertEqual(out.record.timeline?[0].response?.firstFrameMissing, .noFrame)
    }

    func testOutsideTheCoveredRangeIsLeftUntouchedAndCounted() {
        let before = response(down: 400)
        let after = response(down: 5001)
        let out = ResponseTracePatch.apply(surfaceMs: [4000], coverage: coverage, to: record([before, after]))
        XCTAssertEqual(out.changed, 0)
        XCTAssertEqual(out.outside, 2)
        XCTAssertEqual(out.record.timeline?[0].response, before)
        XCTAssertEqual(out.record.timeline?[1].response, after)
    }

    func testCoverageBoundsAreInclusive() {
        let edge = ResponseTracePatch.apply(surfaceMs: [], coverage: coverage, to: record([response(down: 500), response(down: 5000)]))
        XCTAssertEqual(edge.changed, 2)
    }

    func testOnlyPatchableStepsAreTouched() {
        let steps: [ResponseMeasurementRecord?] = [
            response(down: nil),                       // 注入の時刻が無い
            response(firstFrame: 12),                  // 既に値がある(Android)
            response(missing: .noInjectedInput),       // 欠けた理由が既にある
            response(missing: .busyBeforeAction, busy: true),
            response(busy: true),                      // 操作の前から描画が続いていた
            nil,                                       // 計測しないステップ
            response(),                                // これだけ
        ]
        let out = ResponseTracePatch.apply(surfaceMs: [1010], coverage: coverage, to: record(steps))
        XCTAssertEqual(out.changed, 1)
        XCTAssertEqual(out.outside, 0)
        let timeline = out.record.timeline!
        XCTAssertEqual(timeline[6].response?.firstFrameMs, 10)
        for index in 0..<6 { XCTAssertEqual(timeline[index].response, steps[index], "step \(index)") }
    }

    func testRecordWithoutTimelineIsReturnedAsIs() {
        let bare = ScenarioRunRecord(scenarioID: "S", platform: "ios", passed: true, startedAt: "x", durationMs: 1,
                                     steps: StepCountsRecord(total: 0, passed: 0))
        let out = ResponseTracePatch.apply(surfaceMs: [1], coverage: coverage, to: bare)
        XCTAssertEqual(out.changed, 0)
        XCTAssertNil(out.record.timeline)
    }

    // MARK: 結果ファイルの書き直し

    func testRewriteScenariosRewritesOnlyWhatTheTransformChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rt-patch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        RunResultsStore.writeScenario(record([response()]), runDir: dir, fileName: "a")
        RunResultsStore.writeScenario(record([response(down: 9999)]), runDir: dir, fileName: "b")
        let rewritten = RunResultsStore.rewriteScenarios(runDir: dir) { record in
            let out = ResponseTracePatch.apply(surfaceMs: [1020], coverage: coverage, to: record)
            return out.changed > 0 ? out.record : nil
        }
        XCTAssertEqual(rewritten, 1)
        let byFirstFrame = RunResultsStore.records(runDir: dir).map { $0.timeline?[0].response?.firstFrameMs }
        XCTAssertEqual(byFirstFrame, [20, nil])
    }

    /// 実機(iPhone SE3・iOS 26.6.2)の `xctrace export` が出した time-info の表そのもの。`timebase-info` は本文を持たず
    /// fmt と子の要素で値を持つ = 想像で作った入力では捕まらない形
    func testTimeInfoFromARealExport() throws {
        let xml = #"""
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[3]'><schema name="time-info" documentation="Raw data needed transform a mach-absolute-time to a trace relative timestamp"><col><mnemonic>update-time</mnemonic><name>Update Time</name><engineering-type>sample-time</engineering-type></col><col><mnemonic>mabs-epoch</mnemonic><name>Run Epoch</name><engineering-type>mach-absolute-time</engineering-type></col><col><mnemonic>mct-epoch</mnemonic><name>Continuous Epoch</name><engineering-type>mach-continuous-time</engineering-type></col><col><mnemonic>timebase-info</mnemonic><name>Timebase</name><engineering-type>mach-timebase-info</engineering-type></col><col><mnemonic>trace-start-time</mnemonic><name>Trace Start Time</name><engineering-type>time-since-epoch</engineering-type></col></schema><row><sample-time id="1" fmt="00:00.000.000">0</sample-time><mach-absolute-time id="2" fmt="50271614940912">50271614940912</mach-absolute-time><mach-continuous-time id="3" fmt="50271614940912">50271614940912</mach-continuous-time><mach-timebase-info id="4" fmt="125/3"><mach-timebase-info-field id="5" fmt="125">125</mach-timebase-info-field><mach-timebase-info-field id="6" fmt="3">3</mach-timebase-info-field></mach-timebase-info><time-since-epoch id="7" fmt="2026/10/18, 22:00:00">1792328400.000000000</time-since-epoch></row>
</node></trace-query-result>
"""#
        let table = try XCTUnwrap(XctraceTable.parse(xml: Data(xml.utf8)))
        XCTAssertEqual(table.rows.count, 1)
        let info = try XCTUnwrap(ResponseTracePatch.timeInfo(from: table))
        XCTAssertEqual(info.mabsEpochTicks, 50271614940912)
        XCTAssertEqual(info.numer, 125)
        XCTAssertEqual(info.denom, 3)
    }
}

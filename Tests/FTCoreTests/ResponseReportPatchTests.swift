// iOS 実機の最初のフレームを Markdown レポートの該当ステップの行へ後から足す純粋な部分。
// 書き手との書式の一致は FTDSLTests の ScenarioReportWriterTests が突き合わせる。

import XCTest
@testable import FTCore

final class ResponseReportPatchTests: XCTestCase {

    private func response(firstFrame: Int? = nil, missing: ResponseMeasurementRecord.FirstFrameMissing? = nil)
        -> ResponseMeasurementRecord {
        ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: 5, firstFrameMs: firstFrame,
                                  firstFrameMissing: missing)
    }

    func testInsertsRightAfterTheDurationBeforeReady() {
        let md = "# T\n\n- ✅ 5. tap \"#x\" — 1.10s · ready 69 ms\n- ✅ 6. tap \"#y\" — 0.50s\n"
        let out = ResponseReportPatch.insertingFirstFrame(markdown: md, stepIndex: 5, response: response(firstFrame: 42))
        XCTAssertEqual(out, "# T\n\n- ✅ 5. tap \"#x\" — 1.10s · first frame 42 ms · ready 69 ms\n- ✅ 6. tap \"#y\" — 0.50s\n")
    }

    func testInsertsAtTheEndWhenThereIsNoReadyPart() {
        let md = "- ✅ 5. tap \"#x\" — 1.10s\n"
        XCTAssertEqual(ResponseReportPatch.insertingFirstFrame(markdown: md, stepIndex: 5, response: response(firstFrame: 7)),
                       "- ✅ 5. tap \"#x\" — 1.10s · first frame 7 ms\n")
        XCTAssertEqual(ResponseReportPatch.insertingFirstFrame(markdown: md, stepIndex: 5, response: response(missing: .noFrame)),
                       "- ✅ 5. tap \"#x\" — 1.10s · first frame - (noFrame)\n")
    }

    func testInsertsBeforeAMissingReadyReason() {
        let md = "- ✅ 5. tap — 1.10s · ready - (noTarget)\n"
        XCTAssertEqual(ResponseReportPatch.insertingFirstFrame(markdown: md, stepIndex: 5, response: response(firstFrame: 7)),
                       "- ✅ 5. tap — 1.10s · first frame 7 ms · ready - (noTarget)\n")
    }

    func testStepNotFoundOrNothingToSayChangesNothing() {
        let md = "- ✅ 5. tap — 1.10s\n"
        XCTAssertNil(ResponseReportPatch.insertingFirstFrame(markdown: md, stepIndex: 15, response: response(firstFrame: 7)))
        XCTAssertNil(ResponseReportPatch.insertingFirstFrame(markdown: md, stepIndex: 5, response: response()))
        // 添字の前方一致(5 と 15)を取り違えない
        XCTAssertNil(ResponseReportPatch.insertingFirstFrame(markdown: "- ✅ 15. tap — 1.10s\n", stepIndex: 5,
                                                              response: response(firstFrame: 7)))
    }

    func testAlreadyPatchedLineIsLeftAlone() {
        let md = "- ✅ 5. tap — 1.10s · first frame 42 ms\n"
        XCTAssertNil(ResponseReportPatch.insertingFirstFrame(markdown: md, stepIndex: 5, response: response(firstFrame: 7)))
    }

    func testFailedStepLineKeepsItsFollowingReasonLine() {
        let md = "- ❌ 5. tap \"#x\" (S.swift:12) — 1.10s · ready - (noTarget)\n  - element not found: ready 3 ms\n- ✅ 6. tap\n"
        let out = ResponseReportPatch.insertingFirstFrame(markdown: md, stepIndex: 5, response: response(firstFrame: 42))
        XCTAssertEqual(out, "- ❌ 5. tap \"#x\" (S.swift:12) — 1.10s · first frame 42 ms · ready - (noTarget)\n  - element not found: ready 3 ms\n- ✅ 6. tap\n")
    }

    func testPatchingAppliesOnlyStepsWhoseResponseChanged() {
        func record(_ responses: [ResponseMeasurementRecord?]) -> ScenarioRunRecord {
            ScenarioRunRecord(
                scenarioID: "S", platform: "ios", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 1,
                steps: StepCountsRecord(total: responses.count, passed: responses.count),
                timeline: responses.enumerated().map {
                    TimelineStepRecord(index: $0.offset + 1, description: "d", status: "passed", response: $0.element)
                })
        }
        let before = record([response(), response(firstFrame: 9), nil])
        let after = record([response(firstFrame: 30), response(firstFrame: 9), nil])
        let md = "- ✅ 1. a — 0.10s\n- ✅ 2. b — 0.10s · first frame 9 ms\n- ✅ 3. c — 0.10s\n"
        XCTAssertEqual(ResponseReportPatch.patching(markdown: md, before: before, after: after),
                       "- ✅ 1. a — 0.10s · first frame 30 ms\n- ✅ 2. b — 0.10s · first frame 9 ms\n- ✅ 3. c — 0.10s\n")
        XCTAssertNil(ResponseReportPatch.patching(markdown: md, before: before, after: before))
    }
}

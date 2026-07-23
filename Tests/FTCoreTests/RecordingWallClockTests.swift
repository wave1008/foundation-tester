// RecordingWallClock の区分計算(壁時計⇔録画位置)の契約を検証する。
// vscode-ftester/src/recordingsModel.ts の offsetMsForWallClock と同じ規則を Swift 側で
// 再実装したもの(単一/複数スパン・欠落・clamp)。

import XCTest
@testable import FTCore

final class RecordingWallClockTests: XCTestCase {

    private let base = ISO8601Millis.date(from: "2026-07-23T12:00:00.000Z")!

    private func at(_ offsetSeconds: Double) -> Date {
        base.addingTimeInterval(offsetSeconds)
    }

    private func segment(startOffset: Double, durationMs: Int) -> RecordingIndexSegment {
        RecordingIndexSegment(startedAt: ISO8601Millis.string(from: at(startOffset)), durationMs: durationMs)
    }

    // MARK: - offsetMs

    func testOffsetMsEmptySegmentsReturnsZero() {
        XCTAssertEqual(RecordingWallClock.offsetMs([], at: at(5)), 0)
    }

    func testOffsetMsWithinSingleSpan() {
        let segments = [segment(startOffset: 0, durationMs: 10_000)]
        XCTAssertEqual(RecordingWallClock.offsetMs(segments, at: at(0)), 0)
        XCTAssertEqual(RecordingWallClock.offsetMs(segments, at: at(3.5)), 3500)
    }

    func testOffsetMsBeforeAllSpansReturnsZero() {
        let segments = [segment(startOffset: 10, durationMs: 5_000)]
        XCTAssertEqual(RecordingWallClock.offsetMs(segments, at: at(0)), 0,
                       "全区間より前は cumulative(先頭では0)")
    }

    func testOffsetMsAfterAllSpansClampsToTotal() {
        let segments = [segment(startOffset: 0, durationMs: 5_000), segment(startOffset: 10, durationMs: 3_000)]
        XCTAssertEqual(RecordingWallClock.offsetMs(segments, at: at(100)), 8_000,
                       "全区間より後は総尺(5000+3000)にclamp")
    }

    func testOffsetMsAcrossMultipleSpans() {
        // span1: [0s, 5s) = 5000ms、span2: [10s, 13s) = 3000ms(5s〜10sは欠落)
        let segments = [segment(startOffset: 0, durationMs: 5_000), segment(startOffset: 10, durationMs: 3_000)]
        XCTAssertEqual(RecordingWallClock.offsetMs(segments, at: at(1)), 1_000, "先頭スパン内")
        XCTAssertEqual(RecordingWallClock.offsetMs(segments, at: at(11)), 6_000,
                       "2番目のスパン内: 先行スパン合計(5000)+差分(1000)")
    }

    func testOffsetMsInGapFallsToNextSpanStart() {
        // 5s〜10sの欠落(span間)に落ちた壁時計は「次スパン先頭」= cumulative(5000)
        let segments = [segment(startOffset: 0, durationMs: 5_000), segment(startOffset: 10, durationMs: 3_000)]
        XCTAssertEqual(RecordingWallClock.offsetMs(segments, at: at(7)), 5_000)
    }

    // MARK: - intersect

    func testIntersectClipsSegmentToRange() {
        let segments = [segment(startOffset: 0, durationMs: 10_000)]
        let result = RecordingWallClock.intersect(segments, range: (at(2), at(6)))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].startedAt, ISO8601Millis.string(from: at(2)))
        XCTAssertEqual(result[0].durationMs, 4_000)
    }

    func testIntersectMultipleSegmentsWithinRange() {
        // span1: [0s,5s)、span2: [10s,13s)。range = [2s, 12s) は両方と交差する
        let segments = [segment(startOffset: 0, durationMs: 5_000), segment(startOffset: 10, durationMs: 3_000)]
        let result = RecordingWallClock.intersect(segments, range: (at(2), at(12)))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].startedAt, ISO8601Millis.string(from: at(2)))
        XCTAssertEqual(result[0].durationMs, 3_000, "[2s,5s) = 3000ms")
        XCTAssertEqual(result[1].startedAt, ISO8601Millis.string(from: at(10)))
        XCTAssertEqual(result[1].durationMs, 2_000, "[10s,12s) = 2000ms")
    }

    func testIntersectExcludesSegmentsOutsideRange() {
        let segments = [segment(startOffset: 0, durationMs: 5_000), segment(startOffset: 100, durationMs: 3_000)]
        let result = RecordingWallClock.intersect(segments, range: (at(0), at(5)))
        XCTAssertEqual(result.count, 1, "range に交差しないセグメントは除外される")
    }

    func testIntersectEmptyWhenRangeOutsideAllSegments() {
        let segments = [segment(startOffset: 0, durationMs: 5_000)]
        let result = RecordingWallClock.intersect(segments, range: (at(10), at(20)))
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - wallClockRange

    func testWallClockRangeSpansFirstStartToLastEnd() throws {
        let segments = [segment(startOffset: 0, durationMs: 5_000), segment(startOffset: 10, durationMs: 3_000)]
        let range = try XCTUnwrap(RecordingWallClock.wallClockRange(of: segments))
        XCTAssertEqual(range.start, at(0))
        XCTAssertEqual(range.end, at(13))
    }

    func testWallClockRangeNilForEmptySegments() {
        XCTAssertNil(RecordingWallClock.wallClockRange(of: []))
    }
}

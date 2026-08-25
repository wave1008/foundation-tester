// `fleetest api host-metrics-summary` の引数解釈と集計。
// 「あの実行は CPU 律速だったか」を実行後に判定する唯一の口なので、集計が静かに間違うと
// 性能判断そのものを誤らせる(docs/performance-tuning.md §4)。

import XCTest
@testable import fleetest

final class HostMetricsSummaryTests: XCTestCase {

    // MARK: - parseBound(--since / --until)

    func testParseBoundAcceptsUnixEpoch() throws {
        XCTAssertEqual(try ApiHostMetricsSummaryCommand.parseBound("1700000000"), 1_700_000_000)
    }

    func testParseBoundConvertsDurationsToAbsoluteEpoch() throws {
        let now = Date().timeIntervalSince1970
        // duration は「今から遡る」指定。単位ごとの秒数を確認する(許容は実行時間ぶんの 5s)
        let cases: [(String, Double)] = [("90s", 90), ("10m", 600), ("2h", 7200), ("1d", 86400)]
        for (raw, seconds) in cases {
            let parsed = try ApiHostMetricsSummaryCommand.parseBound(raw)
            XCTAssertEqual(parsed, now - seconds, accuracy: 5,
                           "\(raw) は \(seconds) 秒前を指すべきです")
        }
    }

    func testParseBoundAcceptsFractionalDuration() throws {
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(try ApiHostMetricsSummaryCommand.parseBound("1.5h"), now - 5400, accuracy: 5)
    }

    func testParseBoundRejectsUnknownFormats() {
        for raw in ["10x", "m10", "", "yesterday", "10 m"] {
            XCTAssertThrowsError(try ApiHostMetricsSummaryCommand.parseBound(raw),
                                 "\(raw) は不正として弾くべきです")
        }
    }

    // MARK: - doubleStat

    func testDoubleStatComputesAveragePeakAndMin() {
        let stat = ApiHostMetricsSummaryCommand.doubleStat([10, 20, 60])
        XCTAssertEqual(stat.avg ?? 0, 30, accuracy: 0.0001)
        XCTAssertEqual(stat.peak, 60)
        XCTAssertEqual(stat.min, 10)
        XCTAssertEqual(stat.count, 3)
    }

    func testDoubleStatOnEmptyIsNilNotZero() {
        // 0 と「サンプルが無い」は意味が違う(GPU 非採取の実行を「GPU 0%」と読ませない)
        let stat = ApiHostMetricsSummaryCommand.doubleStat([])
        XCTAssertNil(stat.avg)
        XCTAssertNil(stat.peak)
        XCTAssertNil(stat.min)
        XCTAssertEqual(stat.count, 0)
    }

    // MARK: - summarize

    private func sample(ts: Double, cpu: Double? = nil, gpu: Double? = nil,
                        memUsed: Int? = nil, memTotal: Int? = nil) -> [String: Any] {
        var obj: [String: Any] = ["ts": ts]
        if let cpu { obj["cpu"] = cpu }
        if let gpu { obj["gpu"] = gpu }
        if let memUsed { obj["memUsedBytes"] = memUsed }
        if let memTotal { obj["memTotalBytes"] = memTotal }
        return obj
    }

    func testSummarizeAggregatesSpanAndStats() {
        let report = ApiHostMetricsSummaryCommand.summarize(
            [sample(ts: 100, cpu: 10, gpu: 5, memUsed: 1000, memTotal: 8000),
             sample(ts: 130, cpu: 50, gpu: 25, memUsed: 3000, memTotal: 8000)],
            logPath: "/tmp/host-metrics.ndjson", runID: "r1", sinceEpoch: nil, untilEpoch: nil)

        XCTAssertEqual(report.samples, 2)
        XCTAssertEqual(report.firstTs, 100)
        XCTAssertEqual(report.lastTs, 130)
        XCTAssertEqual(report.spanSeconds, 30)
        XCTAssertEqual(report.cpu.avg ?? 0, 30, accuracy: 0.0001)
        XCTAssertEqual(report.cpu.peak, 50)
        XCTAssertEqual(report.mem.peakUsedBytes, 3000)
        XCTAssertEqual(report.mem.totalBytes, 8000)
    }

    func testSummarizeIgnoresSamplesWithoutTimestamp() {
        // ts の無い行(書き込み途中・別種のレコード)は数えない
        let report = ApiHostMetricsSummaryCommand.summarize(
            [sample(ts: 100, cpu: 10), ["cpu": 999.0]],
            logPath: "x", runID: nil, sinceEpoch: nil, untilEpoch: nil)
        XCTAssertEqual(report.cpu.count, 1)
        XCTAssertEqual(report.cpu.peak, 10)
    }

    func testSummarizeIsOrderIndependentForSpan() {
        // NDJSON が時刻順に並んでいる保証はない
        let report = ApiHostMetricsSummaryCommand.summarize(
            [sample(ts: 130), sample(ts: 100), sample(ts: 115)],
            logPath: "x", runID: nil, sinceEpoch: nil, untilEpoch: nil)
        XCTAssertEqual(report.firstTs, 100)
        XCTAssertEqual(report.lastTs, 130)
        XCTAssertEqual(report.spanSeconds, 30)
    }

    func testSummarizeTakesLastSeenMemoryTotal() {
        let report = ApiHostMetricsSummaryCommand.summarize(
            [sample(ts: 1, memTotal: 8000), sample(ts: 2, memTotal: 16000)],
            logPath: "x", runID: nil, sinceEpoch: nil, untilEpoch: nil)
        XCTAssertEqual(report.mem.totalBytes, 16000)
    }

    func testSummarizeOnEmptyInputIsZeroSpanNotCrash() {
        let report = ApiHostMetricsSummaryCommand.summarize(
            [], logPath: "x", runID: nil, sinceEpoch: nil, untilEpoch: nil)
        XCTAssertEqual(report.samples, 0)
        XCTAssertEqual(report.spanSeconds, 0)
        XCTAssertNil(report.firstTs)
        XCTAssertNil(report.cpu.avg)
    }
}

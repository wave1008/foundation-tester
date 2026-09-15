import XCTest
@testable import FTCore

final class SlowWorkerDetectorTests: XCTestCase {

    private func record(worker: String, scenarioID: String = "Foo.bar",
                        snapshotSamples: [Int]) -> ScenarioRunRecord {
        let timeline = snapshotSamples.enumerated().map { index, ms in
            TimelineStepRecord(index: index, description: "tap", status: "passed", snapshotMs: ms)
        }
        return ScenarioRunRecord(
            scenarioID: scenarioID, platform: "ios", worker: worker, passed: true,
            startedAt: "2026-09-15T00:00:00.000Z", durationMs: 0,
            steps: StepCountsRecord(total: snapshotSamples.count, passed: snapshotSamples.count),
            timeline: timeline)
    }

    /// 実測の形(2026-09-15 負荷テスト): 1台だけ snapshot が 4,300ms に張り付き、他7台は
    /// 15ラウンドを通じて 4〜20ms に収まっていた。相対 10 倍・絶対 1,000ms の両方を満たすので検出する
    func testDetectsOneSlowLaneAmongEight() {
        let slow = record(worker: "ios:iPhone 17 Pro-04",
                          snapshotSamples: Array(repeating: 4300, count: 41))
        let fastSamples = [4, 6, 8, 10, 12, 14, 16, 18, 20, 12, 10, 8]
        // 遅い台(-04)と同じ名前を他レーンに使わない(同名なら標本が 1 台にまとまる)
        let others = [1, 2, 3, 5, 6, 7, 8].map { lane in
            record(worker: "ios:iPhone 17 Pro-0\(lane)", scenarioID: "Foo.other\(lane)",
                  snapshotSamples: fastSamples)
        }

        let findings = SlowWorkerDetector.detect(records: [slow] + others)

        XCTAssertEqual(findings.count, 1, "遅いのは1台だけであること")
        let finding = try! XCTUnwrap(findings.first)
        XCTAssertEqual(finding.worker, "ios:iPhone 17 Pro-04")
        XCTAssertEqual(finding.medianMs, 4300)
        XCTAssertEqual(finding.samples, 41)
        XCTAssertEqual(finding.fleetMedianMs, 11, "他7台をプールした中央値(fastSamples の中央値)")
        XCTAssertEqual(finding.summary,
                      "ios:iPhone 17 Pro-04: median snapshot 4300ms over 41 samples (other lanes 11ms)")
    }

    /// 全台が同じ速さで遅い(ホスト負荷)ときは、相対条件(他の10倍)を満たさないので
    /// 1台のせいにしない —— 誤って特定の台を名指ししない
    func testAllLanesEquallySlowUnderHostLoadDetectsNothing() {
        let records = (1...8).map { lane in
            record(worker: "ios:iPhone 17 Pro-0\(lane)", scenarioID: "Foo.host\(lane)",
                  snapshotSamples: Array(repeating: 4300, count: 20))
        }

        XCTAssertTrue(SlowWorkerDetector.detect(records: records).isEmpty,
                      "全台が同じ速さで遅い run は1台のせいにしない")
    }

    /// 他ワーカーが1台も居ない(実機1台のプロファイル等)runでは相対比較ができないので判定しない
    func testSingleWorkerRunDetectsNothing() {
        let onlyWorker = record(worker: "ios:iPhone 13",
                                snapshotSamples: Array(repeating: 4300, count: 41))

        XCTAssertTrue(SlowWorkerDetector.detect(records: [onlyWorker]).isEmpty,
                      "比較相手が居ない run では警告を出さない")
    }

    /// 標本数が `minSamples`(8)未満なら、1シナリオの短い台本で偶然の1枚に引っ張られないよう判定しない
    func testFewerThanMinSamplesIsNotJudged() {
        let others = record(worker: "ios:iPhone 17 Pro-01", snapshotSamples: [4, 6, 8, 10])
        let sevenSamples = record(worker: "ios:iPhone 17 Pro-04",
                                  snapshotSamples: Array(repeating: 4300, count: 7))

        XCTAssertTrue(SlowWorkerDetector.detect(records: [sevenSamples, others]).isEmpty,
                      "標本7件は判定しない")

        let eightSamples = record(worker: "ios:iPhone 17 Pro-04",
                                  snapshotSamples: Array(repeating: 4300, count: 8))
        XCTAssertEqual(SlowWorkerDetector.detect(records: [eightSamples, others]).count, 1,
                      "標本8件になれば判定する")
    }

    /// 絶対条件(1,000ms)を満たさない中央値は、相対条件だけ満たしても検出しない —— 元から
    /// 遅い環境(実機USB等)で常に鳴ることを避けるための下限
    func testModestlySlowerLaneBelowAbsoluteFloorIsNotDetected() {
        let modest = record(worker: "ios:iPhone 17 Pro-04",
                            snapshotSamples: Array(repeating: 900, count: 20))
        let others = record(worker: "ios:iPhone 17 Pro-01",
                            snapshotSamples: Array(repeating: 50, count: 20))

        XCTAssertTrue(SlowWorkerDetector.detect(records: [modest, others]).isEmpty,
                      "中央値900msは絶対条件(1,000ms)未満なので検出しない")
    }

    /// timeline/snapshotMs を持たない記録(実機のログ欠落・旧レコード)は静かに無視する
    func testRecordsWithoutTimelineOrSnapshotAreIgnored() {
        let noTimeline = ScenarioRunRecord(
            scenarioID: "Foo.notimeline", platform: "ios", worker: "ios:iPhone 17 Pro-04",
            passed: true, startedAt: "2026-09-15T00:00:00.000Z", durationMs: 0,
            steps: StepCountsRecord())
        let others = record(worker: "ios:iPhone 17 Pro-01", snapshotSamples: [4, 6, 8, 10])

        XCTAssertTrue(SlowWorkerDetector.detect(records: [noTimeline, others]).isEmpty)
    }
}

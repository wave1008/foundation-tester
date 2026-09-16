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
        XCTAssertEqual(finding.samples, 41)
        guard case let .median(medianMs, fleetMedianMs) = finding.kind else {
            return XCTFail("median 判定であること")
        }
        XCTAssertEqual(medianMs, 4300)
        XCTAssertEqual(fleetMedianMs, 11, "他7台をプールした中央値(fastSamples の中央値)")
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

    // MARK: - 間欠的な劣化(中央値は正常域でも一部の照会だけ遅い台)

    /// 実測の再現1(2026-09-16 負荷テスト・M1Max -04・21:55 ios-inapp run): 中央値は8msで
    /// 正常域なのに20/46の照会だけ3579ms(p90)に張り付く。他レーン(4台・計180標本)は
    /// 2秒超0件なので間欠判定が立つ。中央値判定は workerMedian(8ms)が絶対条件(1,000ms)未満で
    /// そもそも不成立 —— 中央値判定では原理的に拾えない形であることも合わせて確認する
    func testDetectsIntermittentSlowLaneInAppRun() {
        let slowSamples = Array(repeating: 8, count: 26) + Array(repeating: 3579, count: 20)
        let slow = record(worker: "ios:iPhone 17 Pro-04", snapshotSamples: slowSamples)
        let others = [1, 2, 3, 5].map { lane in
            record(worker: "ios:iPhone 17 Pro-0\(lane)", scenarioID: "Foo.other\(lane)",
                  snapshotSamples: Array(repeating: 6, count: 45))
        }

        let findings = SlowWorkerDetector.detect(records: [slow] + others)

        XCTAssertEqual(findings.count, 1, "遅いのは1台だけであること")
        let finding = try! XCTUnwrap(findings.first)
        XCTAssertEqual(finding.worker, "ios:iPhone 17 Pro-04")
        XCTAssertEqual(finding.samples, 46)
        guard case let .intermittent(slowCount, p90Ms, fleetSlowCount, fleetSamples) = finding.kind else {
            return XCTFail("intermittent 判定であること")
        }
        XCTAssertEqual(slowCount, 20)
        XCTAssertEqual(p90Ms, 3579)
        XCTAssertEqual(fleetSlowCount, 0)
        XCTAssertEqual(fleetSamples, 180)
        XCTAssertEqual(finding.summary,
                      "ios:iPhone 17 Pro-04: 20 of 46 snapshots took 2000ms+ (p90 3579ms, other lanes 0 of 180)")
    }

    /// 実測の再現2(21:53 ios-xcuitest run・40標本): 2秒超が16/40(40%)・p90 3741ms
    func testDetectsIntermittentSlowLaneXcuitestRun40Samples() {
        let slowSamples = Array(repeating: 293, count: 24) + Array(repeating: 3741, count: 16)
        let slow = record(worker: "ios:iPhone 17 Pro-04", snapshotSamples: slowSamples)
        let others = (1...3).map { lane in
            record(worker: "ios:iPhone 17 Pro-0\(lane)", scenarioID: "Foo.other\(lane)",
                  snapshotSamples: Array(repeating: 68, count: 30))
        }

        let findings = SlowWorkerDetector.detect(records: [slow] + others)

        XCTAssertEqual(findings.count, 1)
        let finding = try! XCTUnwrap(findings.first)
        XCTAssertEqual(finding.samples, 40)
        guard case let .intermittent(slowCount, p90Ms, fleetSlowCount, fleetSamples) = finding.kind else {
            return XCTFail("intermittent 判定であること")
        }
        XCTAssertEqual(slowCount, 16)
        XCTAssertEqual(p90Ms, 3741)
        XCTAssertEqual(fleetSlowCount, 0)
        XCTAssertEqual(fleetSamples, 90)
        XCTAssertEqual(finding.summary,
                      "ios:iPhone 17 Pro-04: 16 of 40 snapshots took 2000ms+ (p90 3741ms, other lanes 0 of 90)")
    }

    /// 実測の再現3(21:50 ios-xcuitest run・91標本): 2秒超が24/91(約26%)・p90 3437ms
    func testDetectsIntermittentSlowLaneXcuitestRun91Samples() {
        let slowSamples = Array(repeating: 167, count: 67) + Array(repeating: 3437, count: 24)
        let slow = record(worker: "ios:iPhone 17 Pro-04", snapshotSamples: slowSamples)
        let others = (1...3).map { lane in
            record(worker: "ios:iPhone 17 Pro-0\(lane)", scenarioID: "Foo.other\(lane)",
                  snapshotSamples: Array(repeating: 62, count: 60))
        }

        let findings = SlowWorkerDetector.detect(records: [slow] + others)

        XCTAssertEqual(findings.count, 1)
        let finding = try! XCTUnwrap(findings.first)
        XCTAssertEqual(finding.samples, 91)
        guard case let .intermittent(slowCount, p90Ms, fleetSlowCount, fleetSamples) = finding.kind else {
            return XCTFail("intermittent 判定であること")
        }
        XCTAssertEqual(slowCount, 24)
        XCTAssertEqual(p90Ms, 3437)
        XCTAssertEqual(fleetSlowCount, 0)
        XCTAssertEqual(fleetSamples, 180)
        XCTAssertEqual(finding.summary,
                      "ios:iPhone 17 Pro-04: 24 of 91 snapshots took 2000ms+ (p90 3437ms, other lanes 0 of 180)")
    }

    /// 健全な run(2026-09-16 全緑フル E2E・127レーンの最大値): 22標本中2本が2100msでも、
    /// 遅い照会が intermittentMinSlowSamples(5本)未満なので間欠判定は立たない
    func testHealthyRunWithOccasionalSlowSnapshotDoesNotFire() {
        let healthySamples = Array(repeating: 50, count: 20) + [2100, 2100]
        let lane = record(worker: "ios:iPhone 17 Pro-01", snapshotSamples: healthySamples)
        let others = (2...3).map { n in
            record(worker: "ios:iPhone 17 Pro-0\(n)", scenarioID: "Foo.other\(n)",
                  snapshotSamples: healthySamples)
        }

        XCTAssertTrue(SlowWorkerDetector.detect(records: [lane] + others).isEmpty,
                      "健全なレーンの稀な2秒超(2/22)は間欠判定の最小本数(5)未満なので立たない")
    }

    /// ホスト全体が遅い run(全レーンが同じ割合で2秒超)は、間欠判定の相対条件
    /// (他レーン全体の割合がこのレーンの1/10以下)を満たさないので1台のせいにしない ——
    /// 既存の中央値判定と同じ思想
    func testHostWideSlowRunDoesNotFireIntermittent() {
        let laneSamples = Array(repeating: 50, count: 14) + Array(repeating: 3000, count: 6)
        let records = (1...8).map { lane in
            record(worker: "ios:iPhone 17 Pro-0\(lane)", scenarioID: "Foo.host\(lane)",
                  snapshotSamples: laneSamples)
        }

        XCTAssertTrue(SlowWorkerDetector.detect(records: records).isEmpty,
                      "全レーンが同じ割合で2秒超なら1台のせいにしない")
    }

    /// 標本不足(9標本中2本が2500ms。負荷テスト中の健全なレーンと同じ形)は、遅い照会が
    /// intermittentMinSlowSamples(5本)未満なので間欠判定は立たない
    func testInsufficientSlowSamplesDoesNotFireIntermittent() {
        let samples = Array(repeating: 50, count: 7) + [2500, 2500]
        let lane = record(worker: "ios:iPhone 17 Pro-01", snapshotSamples: samples)
        let others = record(worker: "ios:iPhone 17 Pro-02", scenarioID: "Foo.other2",
                            snapshotSamples: Array(repeating: 40, count: 12))

        XCTAssertTrue(SlowWorkerDetector.detect(records: [lane, others]).isEmpty,
                      "標本9本中2本の遅延は間欠判定の最小本数(5)未満なので立たない")
    }
}

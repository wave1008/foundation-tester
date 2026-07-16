import XCTest
@testable import FTCore

final class RunResultsQueryTests: XCTestCase {

    // MARK: - parseSince

    func testParseSinceRelativeDays() {
        let reference = ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z")!
        let result = RunResultsQuery.parseSince("30d", referenceDate: reference)
        XCTAssertEqual(result, reference.addingTimeInterval(-30 * 86400))
    }

    func testParseSinceRelativeHours() {
        let reference = ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z")!
        let result = RunResultsQuery.parseSince("12h", referenceDate: reference)
        XCTAssertEqual(result, reference.addingTimeInterval(-12 * 3600))
    }

    func testParseSinceAbsoluteDate() {
        let result = RunResultsQuery.parseSince("2026-06-01")
        let expected = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")
        XCTAssertEqual(result, expected)
    }

    func testParseSinceInvalidReturnsNil() {
        XCTAssertNil(RunResultsQuery.parseSince("bogus"))
        XCTAssertNil(RunResultsQuery.parseSince("30"))
        XCTAssertNil(RunResultsQuery.parseSince("-5d"))
    }

    // MARK: - isSkippedSynthetic

    func testIsSkippedSynthetic() {
        let skipped = makeRecord(
            scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 0,
            steps: StepCountsRecord(total: 1, skipped: 1))
        XCTAssertTrue(RunResultsQuery.isSkippedSynthetic(skipped))

        let real = makeRecord(
            scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 0,
            steps: StepCountsRecord(total: 1, failed: 1))
        XCTAssertFalse(RunResultsQuery.isSkippedSynthetic(real))
    }

    // MARK: - recentRuns

    func testRecentRunsSortsDescendingAndLimits() {
        let runs = [
            makeMeta(runID: "20260101-000000Z-m-0001"),
            makeMeta(runID: "20260103-000000Z-m-0003"),
            makeMeta(runID: "20260102-000000Z-m-0002"),
        ]
        let result = RunResultsQuery.recentRuns(runs, limit: 2)
        XCTAssertEqual(result.map(\.runID), [
            "20260103-000000Z-m-0003", "20260102-000000Z-m-0002",
        ])
    }

    // MARK: - scenarioSummary

    func testScenarioSummaryComputesRateAvgMedianAndSortsAscending() {
        let records = [
            makeRecord(scenarioID: "Flaky.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
            makeRecord(scenarioID: "Flaky.a", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 200),
            makeRecord(scenarioID: "Flaky.a", passed: true, startedAt: "2026-01-03T00:00:00Z", durationMs: 300),
            makeRecord(scenarioID: "Stable.b", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 50),
            makeRecord(scenarioID: "Stable.b", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 60),
        ]
        let rows = RunResultsQuery.scenarioSummary(records)
        XCTAssertEqual(rows.map(\.scenarioID), ["Flaky.a", "Stable.b"])  // 成功率昇順(問題のあるものが上)

        let flaky = rows[0]
        XCTAssertEqual(flaky.runs, 3)
        XCTAssertEqual(flaky.successRate, 200.0 / 3, accuracy: 0.001)
        XCTAssertEqual(flaky.avgDurationMs, 200)
        XCTAssertEqual(flaky.medianDurationMs, 200)
        XCTAssertEqual(flaky.lastRunAt, "2026-01-03T00:00:00Z")
        XCTAssertEqual(flaky.lastPassed, true)

        let stable = rows[1]
        XCTAssertEqual(stable.successRate, 100)
        XCTAssertEqual(stable.avgDurationMs, 55)
        XCTAssertEqual(stable.medianDurationMs, 55)
    }

    func testScenarioSummaryExcludesSkippedSyntheticFromDuration() {
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 0,
                steps: StepCountsRecord(total: 1, skipped: 1)),
        ]
        let rows = RunResultsQuery.scenarioSummary(records)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].runs, 2)
        XCTAssertEqual(rows[0].successRate, 50)
        XCTAssertEqual(rows[0].avgDurationMs, 100)  // スキップ合成レコードの durationMs=0 を含めない
    }

    // MARK: - flakyScenarios

    func testFlakyScenariosDetectsMixedResultsAndScore() {
        // P F P F P: 4 transitions / 4 gaps = 1.0
        let records = (0..<5).map { i in
            makeRecord(
                scenarioID: "Flaky.a", passed: i % 2 == 0,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.flakyScenarios(records, minRuns: 5)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].scenarioID, "Flaky.a")
        XCTAssertEqual(rows[0].runs, 5)
        XCTAssertEqual(rows[0].flakinessScore, 1.0, accuracy: 0.001)
        XCTAssertEqual(rows[0].failureRate, 40, accuracy: 0.001)  // 2 failed / 5
        // 新しい順: index4(P) index3(F) index2(P) index1(F) index0(P)
        XCTAssertEqual(rows[0].recentResults, [true, false, true, false, true])
    }

    func testFlakyScenariosExcludesAllPassOrAllFail() {
        let stable = (0..<5).map { i in
            makeRecord(
                scenarioID: "Stable.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        XCTAssertTrue(RunResultsQuery.flakyScenarios(stable, minRuns: 5).isEmpty)
    }

    func testFlakyScenariosExcludesBelowMinRuns() {
        let records = (0..<3).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: i % 2 == 0,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        XCTAssertTrue(RunResultsQuery.flakyScenarios(records, minRuns: 5).isEmpty)
        XCTAssertEqual(RunResultsQuery.flakyScenarios(records, minRuns: 3).count, 1)
    }

    // MARK: - trend

    func testTrendFiltersAndSortsAscending() {
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-03T00:00:00Z", durationMs: 300),
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
            makeRecord(scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 200),
        ]
        let rows = RunResultsQuery.trend(records, scenarioID: "Foo.a")
        XCTAssertEqual(rows.map(\.startedAt), [
            "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z",
        ])
        XCTAssertTrue(rows.allSatisfy { $0.scenarioID == "Foo.a" })
    }

    // MARK: - deviceSummary

    func testDeviceSummaryGroupsByWorkerAndPlatform() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                platform: "ios", worker: "ios:iPhone 17"),
            makeRecord(
                scenarioID: "Foo.b", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 200,
                platform: "ios", worker: "ios:iPhone 17"),
            makeRecord(
                scenarioID: "Foo.c", passed: true, startedAt: "2026-01-03T00:00:00Z", durationMs: 300,
                platform: "android", worker: nil),
        ]
        let report = RunResultsQuery.deviceSummary(records)

        XCTAssertEqual(report.byWorker.map(\.worker), ["(worker不明)", "ios:iPhone 17"])
        let iphoneRow = report.byWorker.first { $0.worker == "ios:iPhone 17" }
        XCTAssertEqual(iphoneRow?.runs, 2)
        XCTAssertEqual(iphoneRow?.successRate, 50)
        XCTAssertEqual(iphoneRow?.avgDurationMs, 150)

        XCTAssertEqual(report.byPlatform.map(\.platform), ["android", "ios"])
        let androidRow = report.byPlatform.first { $0.platform == "android" }
        XCTAssertEqual(androidRow?.runs, 1)
        XCTAssertEqual(androidRow?.successRate, 100)
    }

    // MARK: - dailyRates

    func testDailyRatesGroupsByDateAndSortsAscending() {
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T10:00:00Z", durationMs: 100),
            makeRecord(scenarioID: "Foo.b", passed: false, startedAt: "2026-01-01T23:00:00Z", durationMs: 100),
            makeRecord(scenarioID: "Foo.c", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 100),
        ]
        let rows = RunResultsQuery.dailyRates(records, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(rows.map(\.date), ["2026-01-01", "2026-01-02"])
        XCTAssertEqual(rows[0].total, 2)
        XCTAssertEqual(rows[0].passed, 1)
        XCTAssertEqual(rows[0].failed, 1)
        XCTAssertEqual(rows[1].total, 1)
        XCTAssertEqual(rows[1].passed, 1)
        XCTAssertEqual(rows[1].failed, 0)
    }

    func testDailyRatesUsesGivenTimeZoneForDayBoundary() {
        // 20:00 UTC は JST(UTC+9)では翌日 05:00 になる → 日付境界が timeZone 引数に従うことを確認
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T20:00:00Z", durationMs: 100),
        ]
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        let rows = RunResultsQuery.dailyRates(records, timeZone: jst)
        XCTAssertEqual(rows.map(\.date), ["2026-01-02"])
    }

    // MARK: - slowTests

    func testSlowTestsComputesAvgP90AndSortsDescending() {
        let records = [
            makeRecord(scenarioID: "Fast.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
            makeRecord(scenarioID: "Slow.b", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
            makeRecord(scenarioID: "Slow.b", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 200),
            makeRecord(scenarioID: "Slow.b", passed: true, startedAt: "2026-01-03T00:00:00Z", durationMs: 900),
        ]
        let rows = RunResultsQuery.slowTests(records, limit: 10)
        XCTAssertEqual(rows.map(\.scenarioID), ["Slow.b", "Fast.a"])
        XCTAssertEqual(rows[0].runs, 3)
        XCTAssertEqual(rows[0].avgDurationMs, 400, accuracy: 0.001)
        XCTAssertEqual(rows[0].p90DurationMs, 900)  // nearest-rank: ceil(0.9*3)=3件目
    }

    func testSlowTestsExcludesSkippedSyntheticAndRespectsLimit() {
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 0,
                steps: StepCountsRecord(total: 1, skipped: 1)),
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 500),
        ]
        let rows = RunResultsQuery.slowTests(records, limit: 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].scenarioID, "Foo.b")
        let fooA = RunResultsQuery.slowTests(records, limit: 10).first { $0.scenarioID == "Foo.a" }
        XCTAssertEqual(fooA?.runs, 1, "スキップ合成レコードは runs から除外")
    }

    func testSlowTestsDeltaPctNilBelowFourRuns() {
        let records = (0..<3).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.slowTests(records, limit: 10)
        XCTAssertNil(rows[0].deltaPct)
    }

    func testSlowTestsDeltaPctComputesIncreaseAndDecrease() throws {
        // 前半 [100, 100] avg=100 / 後半 [200, 200] avg=200 → +100%
        let increasing = (0..<4).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: i < 2 ? 100 : 200)
        }
        let increasingRows = RunResultsQuery.slowTests(increasing, limit: 10)
        XCTAssertEqual(try XCTUnwrap(increasingRows[0].deltaPct), 100, accuracy: 0.001)

        // 前半 [200, 200] avg=200 / 後半 [100, 100] avg=100 → -50%
        let decreasing = (0..<4).map { i in
            makeRecord(
                scenarioID: "Foo.b", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: i < 2 ? 200 : 100)
        }
        let decreasingRows = RunResultsQuery.slowTests(decreasing, limit: 10)
        XCTAssertEqual(try XCTUnwrap(decreasingRows[0].deltaPct), -50, accuracy: 0.001)
    }

    func testSlowTestsSlowestScene() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 300,
                scenes: [
                    SceneResultRecord(scene: 1, title: "Login", passed: true, durationMs: 100),
                    SceneResultRecord(scene: 2, title: "Checkout", passed: true, durationMs: 200),
                ]),
        ]
        let rows = RunResultsQuery.slowTests(records, limit: 10)
        XCTAssertEqual(rows[0].slowestScene, "Checkout")
        XCTAssertEqual(rows[0].slowestSceneAvgMs, 200)
    }

    func testSlowTestsSlowestSceneNilWithoutSceneData() {
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
        ]
        let rows = RunResultsQuery.slowTests(records, limit: 10)
        XCTAssertNil(rows[0].slowestScene)
        XCTAssertNil(rows[0].slowestSceneAvgMs)
    }

    // MARK: - insights: newFailure / consecutiveFailures

    func testInsightsNewFailureAfterThreeConsecutivePasses() {
        let records = (0..<4).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: i < 3,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        let row = try? XCTUnwrap(rows.first { $0.kind == "newFailure" })
        XCTAssertEqual(row?.severity, "critical")
        XCTAssertEqual(row?.scenarioID, "Foo.a")
        XCTAssertEqual(row?.count, 3)
        XCTAssertFalse(rows.contains { $0.kind == "consecutiveFailures" })
    }

    func testInsightsNoNewFailureWithOnlyTwoPriorPasses() {
        let records = (0..<3).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: i < 2,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "newFailure" })
    }

    func testInsightsConsecutiveFailuresAtThreshold() {
        let records = (0..<3).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        let row = try? XCTUnwrap(rows.first { $0.kind == "consecutiveFailures" })
        XCTAssertEqual(row?.severity, "critical")
        XCTAssertEqual(row?.count, 3)
        XCTAssertFalse(rows.contains { $0.kind == "newFailure" }, "consecutiveFailures を優先し newFailure は出さない")
    }

    func testInsightsNoConsecutiveFailuresBelowThreshold() {
        let records = (0..<2).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "consecutiveFailures" })
        XCTAssertFalse(rows.contains { $0.kind == "newFailure" })
    }

    // MARK: - insights: infraFailures

    func testInsightsInfraFailuresAtThreshold() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                timedOut: true),
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                errorLogs: ["❌ bridge disconnected"]),
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-03T00:00:00Z", durationMs: 100),
        ]
        let rows = RunResultsQuery.insights(records: records, runs: [])
        let row = try? XCTUnwrap(rows.first { $0.kind == "infraFailures" })
        XCTAssertEqual(row?.severity, "warn")
        XCTAssertEqual(row?.count, 2)
        XCTAssertTrue(row?.message.contains("アサーション起因0件") ?? false)
    }

    func testInsightsNoInfraFailuresBelowThreshold() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                timedOut: true),
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 100),
        ]
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "infraFailures" })
    }

    // MARK: - insights: selectorDecay

    func testInsightsSelectorDecayAtThreshold() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 3, healed: 2)),
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 4, passedViaFallback: 1)),
        ]
        let rows = RunResultsQuery.insights(records: records, runs: [])
        let row = try? XCTUnwrap(rows.first { $0.kind == "selectorDecay" })
        XCTAssertEqual(row?.severity, "warn")
        XCTAssertEqual(row?.count, 3)
    }

    func testInsightsNoSelectorDecayBelowThreshold() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 3, healed: 2)),
        ]
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "selectorDecay" })
    }

    // MARK: - insights: deviceBias

    func testInsightsDeviceBiasWhenWorkerFailureRateDoubled() {
        // worker A: 3敗/3件=100% / worker B: 0敗/3件=0% → 全体失敗率50%、A は 100% >= 50%*2
        let records =
            (0..<3).map { i in
                makeRecord(
                    scenarioID: "Foo.a", passed: false,
                    startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100,
                    worker: "ios:A")
            } +
            (0..<3).map { i in
                makeRecord(
                    scenarioID: "Foo.a", passed: true,
                    startedAt: String(format: "2026-01-1%dT00:00:00Z", i), durationMs: 100,
                    worker: "ios:B")
            }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        let row = try? XCTUnwrap(rows.first { $0.kind == "deviceBias" })
        XCTAssertEqual(row?.severity, "warn")
        XCTAssertEqual(row?.worker, "ios:A")
        XCTAssertEqual(row?.count, 3)
    }

    func testInsightsNoDeviceBiasWithSingleWorkerKind() {
        let records = (0..<3).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100,
                worker: "ios:A")
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "deviceBias" }, "worker が 1 種類のみでは偏り判定不能")
    }

    func testInsightsNoDeviceBiasBelowMinRunsPerWorker() {
        // worker A: 2件のみ(最小実行回数 3 未満)
        let records =
            (0..<2).map { i in
                makeRecord(
                    scenarioID: "Foo.a", passed: false,
                    startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100,
                    worker: "ios:A")
            } +
            (0..<3).map { i in
                makeRecord(
                    scenarioID: "Foo.a", passed: true,
                    startedAt: String(format: "2026-01-1%dT00:00:00Z", i), durationMs: 100,
                    worker: "ios:B")
            }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "deviceBias" })
    }

    // MARK: - insights: durationRegression

    func testInsightsDurationRegressionAtThreshold() throws {
        // 前半 avg=100 / 後半 avg=140 → +40%(閾値 30% 以上)
        let records = (0..<4).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: i < 2 ? 100 : 140)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        let row = try XCTUnwrap(rows.first { $0.kind == "durationRegression" })
        XCTAssertEqual(row.severity, "warn")
        XCTAssertEqual(try XCTUnwrap(row.deltaPct), 40, accuracy: 0.001)
    }

    func testInsightsNoDurationRegressionBelowThreshold() {
        // 前半 avg=100 / 後半 avg=110 → +10%(閾値未満)
        let records = (0..<4).map { i in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: i < 2 ? 100 : 110)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "durationRegression" })
    }

    // MARK: - insights: unfinishedRuns

    func testInsightsUnfinishedRunsWhenFinishedAtMissing() {
        let runs = [makeMeta(runID: "20260101-000000Z-m-0001", finishedAt: nil)]
        let rows = RunResultsQuery.insights(records: [], runs: runs)
        let row = try? XCTUnwrap(rows.first { $0.kind == "unfinishedRuns" })
        XCTAssertEqual(row?.severity, "info")
        XCTAssertEqual(row?.scenarioID, nil)
        XCTAssertEqual(row?.count, 1)
    }

    func testInsightsNoUnfinishedRunsWhenAllFinished() {
        let runs = [makeMeta(runID: "20260101-000000Z-m-0001", finishedAt: "2026-01-01T00:10:00Z")]
        let rows = RunResultsQuery.insights(records: [], runs: runs)
        XCTAssertFalse(rows.contains { $0.kind == "unfinishedRuns" })
    }

    // MARK: - insights: 並び順・0 件

    func testInsightsEmptyWhenNothingDetected() {
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100),
        ]
        XCTAssertTrue(RunResultsQuery.insights(records: records, runs: []).isEmpty)
    }

    func testInsightsSortsBySeverityThenCountDescending() {
        // critical(consecutiveFailures, count=3) と info(unfinishedRuns, count=1) と
        // warn(selectorDecay, count=3) を混在させ、severity 順(critical→warn→info)を確認
        let failing = (0..<3).map { i in
            makeRecord(
                scenarioID: "Foo.fail", passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", i + 1), durationMs: 100)
        }
        let decaying = [
            makeRecord(
                scenarioID: "Foo.decay", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 2, healed: 3)),
        ]
        let runs = [makeMeta(runID: "20260101-000000Z-m-0001", finishedAt: nil)]
        let rows = RunResultsQuery.insights(records: failing + decaying, runs: runs)
        XCTAssertEqual(rows.map(\.kind), ["consecutiveFailures", "selectorDecay", "unfinishedRuns"])
    }

    // MARK: - フィクスチャ

    private func makeMeta(runID: String, finishedAt: String? = nil) -> RunMetaRecord {
        RunMetaRecord(
            runID: runID, project: "SampleApp", profile: nil, machine: "testmachine",
            trigger: "cli", startedAt: "2026-01-01T00:00:00Z", finishedAt: finishedAt)
    }

    private func makeRecord(
        scenarioID: String, passed: Bool, startedAt: String, durationMs: Int,
        steps: StepCountsRecord? = nil, platform: String = "ios", worker: String? = nil,
        timedOut: Bool? = nil, scenes: [SceneResultRecord] = [],
        failedSteps: [FailedStepRecord]? = nil, errorLogs: [String]? = nil
    ) -> ScenarioRunRecord {
        ScenarioRunRecord(
            scenarioID: scenarioID, platform: platform, worker: worker, machine: "testmachine",
            passed: passed, timedOut: timedOut, startedAt: startedAt, durationMs: durationMs,
            scenes: scenes, steps: steps ?? StepCountsRecord(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1),
            failedSteps: failedSteps, errorLogs: errorLogs)
    }
}

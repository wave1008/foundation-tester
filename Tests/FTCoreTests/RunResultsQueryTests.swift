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

        XCTAssertEqual(report.byWorker.map(\.worker), ["(unknown worker)", "ios:iPhone 17"])
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
        XCTAssertTrue(row?.message.contains("vs 0 assertion-caused") ?? false)
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

    /// 1 run あたりの件数が**増えている**ときに出る(合計ではない)
    func testInsightsSelectorDecayWhenRelianceGrows() {
        let counts = [0, 1, 2, 3]   // 前半平均 0.5 → 後半平均 2.5
        let records = counts.enumerated().map { index, fallbacks in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 5 - fallbacks, passedViaFallback: fallbacks))
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        let row = try? XCTUnwrap(rows.first { $0.kind == "selectorDecay" })
        XCTAssertEqual(row?.severity, "warn")
        XCTAssertEqual(row?.count, 6, "合計は説明のために出す(判定の材料ではない)")
        // **分割位置まで固定する**: 前半 [0,1]=0.5 → 後半 [2,3]=2.5 で +400%。
        // ここを緩めると「先頭1件 vs 残り」のような別の分け方でも通ってしまう
        XCTAssertEqual(row?.deltaPct ?? 0, 400, accuracy: 0.01)
    }

    /// run 数が足りないうちは判定しない。**旧実装は合計だけを見ていた**ので、
    /// 毎 run 1 件フォールバックするシナリオが 3 run 目から永久に鳴っていた
    func testInsightsNoSelectorDecayBeforeEnoughRunsToSeeATrend() {
        let records = (0..<3).map { index in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 4, passedViaFallback: 1))
        }
        XCTAssertFalse(RunResultsQuery.insights(records: records, runs: [])
            .contains { $0.kind == "selectorDecay" }, "3 run では増減を言えない(合計は 3 で旧閾値ちょうど)")
    }

    /// **一定なら劣化ではない**。フォールバックを意図的に検証するシナリオは毎 run 同じ件数を出し、
    /// 合計だけで判定すると永久に鳴り続ける(実測 2118 run で 2107 件 = 1件/run が一定)
    func testInsightsNoSelectorDecayWhenRelianceIsFlat() {
        let records = (0..<10).map { index in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-%02dT00:00:00Z", index + 1), durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 4, passedViaFallback: 1))
        }
        XCTAssertFalse(RunResultsQuery.insights(records: records, runs: [])
            .contains { $0.kind == "selectorDecay" })
    }

    /// **わずかな増加では出さない**(閾値が効いていることの検証。一定との対だけだと、
    /// 「増えているか」の条件と閾値の条件が互いを覆い隠して、どちらを壊しても落ちない)
    func testInsightsNoSelectorDecayWhenTheRiseIsSmall() {
        let counts = [4, 4, 4, 5]   // 前半 4.0 → 後半 4.5 = +12.5%(閾値 30% 未満)
        let records = counts.enumerated().map { index, fallbacks in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100,
                steps: StepCountsRecord(total: 10, passed: 10 - fallbacks, passedViaFallback: fallbacks))
        }
        XCTAssertFalse(RunResultsQuery.insights(records: records, runs: [])
            .contains { $0.kind == "selectorDecay" })
    }

    /// 無かったものが出始めた場合も合図にする(前半 0 は比率が出せないので率は載せない)
    func testInsightsSelectorDecayWhenItNewlyAppears() {
        let counts = [0, 0, 2, 2]
        let records = counts.enumerated().map { index, healed in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 5 - healed, healed: healed))
        }
        let row = RunResultsQuery.insights(records: records, runs: [])
            .first { $0.kind == "selectorDecay" }
        XCTAssertNotNil(row)
        XCTAssertNil(row?.deltaPct, "前半 0 では変化率を出さない")
        XCTAssertTrue(row?.message.contains("newly appeared") ?? false)
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

    /// worker ごとの記録を作る(deviceBias は実行回数と失敗回数の両方に下限があるので数が要る)
    private func workerRecords(worker: String, runs: Int, failures: Int,
                               dayOffset: Int) -> [ScenarioRunRecord] {
        (0..<runs).map { index in
            makeRecord(
                scenarioID: "Foo.a", passed: index >= failures,
                startedAt: String(format: "2026-01-%02dT%02d:00:00Z", dayOffset + 1, index % 24),
                durationMs: 100, worker: worker)
        }
    }

    func testInsightsDeviceBiasWhenFailuresClusterOnOneWorker() {
        // A: 12 run 中 8 敗(67%)/ B: 20 run 全通 → 全体 25%。67% >= 25%*2 かつ 8 >= 最小失敗回数
        let records = workerRecords(worker: "ios:A", runs: 12, failures: 8, dayOffset: 0)
            + workerRecords(worker: "ios:B", runs: 20, failures: 0, dayOffset: 1)
        let rows = RunResultsQuery.insights(records: records, runs: [])
        let row = try? XCTUnwrap(rows.first { $0.kind == "deviceBias" })
        XCTAssertEqual(row?.severity, "warn")
        XCTAssertEqual(row?.worker, "ios:A")
        XCTAssertEqual(row?.count, 8)
    }

    /// **率だけでは出さない**。単発〜数件の失敗は率を跳ね上げるが偏りの証拠にならない
    /// (実データで 69 行出ていた主因。3 run 中 1 敗 = 33% が全体 4% の 2 倍を軽く超えていた)
    func testInsightsNoDeviceBiasWhenTheWorkerHasTooFewFailures() {
        // A: 20 run 中 4 敗(20%)/ B: 20 run 全通 → 全体 10%、率は 2 倍だが失敗回数が足りない
        let records = workerRecords(worker: "ios:A", runs: 20, failures: 4, dayOffset: 0)
            + workerRecords(worker: "ios:B", runs: 20, failures: 0, dayOffset: 1)
        XCTAssertFalse(RunResultsQuery.insights(records: records, runs: [])
            .contains { $0.kind == "deviceBias" })
    }

    func testInsightsNoDeviceBiasWithSingleWorkerKind() {
        let records = workerRecords(worker: "ios:A", runs: 12, failures: 8, dayOffset: 0)
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "deviceBias" }, "worker が 1 種類のみでは偏り判定不能")
    }

    /// 実行回数が足りない worker は判定しない(率が安定しない)
    func testInsightsNoDeviceBiasBelowMinRunsPerWorker() {
        // A: 8 run 中 8 敗(100%)—— 失敗回数は足りるが run 数が下限未満
        let records = workerRecords(worker: "ios:A", runs: 8, failures: 8, dayOffset: 0)
            + workerRecords(worker: "ios:B", runs: 20, failures: 0, dayOffset: 1)
        XCTAssertFalse(RunResultsQuery.insights(records: records, runs: [])
            .contains { $0.kind == "deviceBias" })
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
        // selectorDecay は傾向で判定するので、増えていく系列を与える(合計 3 件)
        let decaying = [0, 0, 1, 2].enumerated().map { index, healed in
            makeRecord(
                scenarioID: "Foo.decay", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100,
                steps: StepCountsRecord(total: 5, passed: 5 - healed, healed: healed))
        }
        let runs = [makeMeta(runID: "20260101-000000Z-m-0001", finishedAt: nil)]
        let rows = RunResultsQuery.insights(records: failing + decaying, runs: runs)
        XCTAssertEqual(rows.map(\.kind), ["consecutiveFailures", "selectorDecay", "unfinishedRuns"])
    }

    // MARK: - insights: retiredScenarios

    /// **実行されなくなったシナリオは検知から外す**。--since の窓(既定 90d)に古い記録が
    /// 残るかぎり、削除・_disabled 化されたシナリオの末尾の失敗は永久に critical を出し、
    /// severity 順の先頭を占めて本物を押し下げる(実測: 12 行中 5 行がこれだった)
    func testInsightsExcludesScenariosThatAreNoLongerRun() {
        let retired = (0..<3).map { index in
            makeRecord(
                scenarioID: "Foo.gone", passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100)
        }
        // 別のシナリオが 20 日後まで回っている = 基準はこちら
        let live = [
            makeRecord(scenarioID: "Foo.live", passed: true,
                       startedAt: "2026-01-21T00:00:00Z", durationMs: 100),
        ]

        let rows = RunResultsQuery.insights(records: retired + live, runs: [])

        XCTAssertFalse(rows.contains { $0.scenarioID == "Foo.gone" },
                       "回されていないシナリオの失敗が critical に残っている")
        let notice = rows.first { $0.kind == "retiredScenarios" }
        XCTAssertEqual(notice?.severity, "info")
        XCTAssertEqual(notice?.count, 1, "黙って落とさず、外したことは出す")
        XCTAssertTrue(notice?.message.contains("Foo.gone") ?? false)
    }

    /// まだ回っているシナリオは当然そのまま出ること(上の除外が広すぎないことの対)
    func testInsightsKeepsScenariosStillBeingRun() {
        let records = (0..<3).map { index in
            makeRecord(
                scenarioID: "Foo.a", passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertTrue(rows.contains { $0.kind == "consecutiveFailures" })
        XCTAssertFalse(rows.contains { $0.kind == "retiredScenarios" })
    }

    /// しばらく回していないプロジェクトで**全部が retired になる**のを防ぐ(基準は最新記録からの相対)
    func testInsightsDoesNotRetireEverythingWhenTheWholeProjectIsOld() {
        let records = (0..<3).map { index in
            makeRecord(
                scenarioID: "Foo.a", passed: false,
                startedAt: String(format: "2020-01-0%dT00:00:00Z", index + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "retiredScenarios" })
        XCTAssertTrue(rows.contains { $0.kind == "consecutiveFailures" })
    }

    // MARK: - insights: healReliance(ヒールキャッシュ依存)

    /// 同じセレクタの修正提案が続いている = **緑だがセレクタは壊れている**状態が放置されている
    func testInsightsHealRelianceWhenTheSameSelectorKeepsBeingSuggested() {
        let records = (0..<3).map { index in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100,
                fixSuggestions: [FixSuggestionRecord(oldSelector: "#old_id", newSelector: "#new_id")])
        }
        let row = RunResultsQuery.insights(records: records, runs: [])
            .first { $0.kind == "healReliance" }
        XCTAssertEqual(row?.severity, "warn")
        XCTAssertEqual(row?.count, 3)
        XCTAssertTrue(row?.message.contains("#old_id") ?? false)
    }

    /// 1〜2 run なら出さない(直せば済む段階では鳴らさない)
    func testInsightsNoHealRelianceForAOneOffSuggestion() {
        let records = (0..<2).map { index in
            makeRecord(
                scenarioID: "Foo.a", passed: true,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100,
                fixSuggestions: [FixSuggestionRecord(oldSelector: "#old_id", newSelector: "#new_id")])
        }
        XCTAssertFalse(RunResultsQuery.insights(records: records, runs: [])
            .contains { $0.kind == "healReliance" })
    }

    /// 同じ run に同じセレクタが複数回出ても **run 数**として 1 と数える
    /// (ステップ数で数えると、1 run しか無いのに閾値を超える)
    func testInsightsHealRelianceCountsRunsNotSuggestions() {
        let many = (0..<5).map { _ in FixSuggestionRecord(oldSelector: "#old_id", newSelector: "#new_id") }
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z",
                       durationMs: 100, fixSuggestions: many),
        ]
        XCTAssertFalse(RunResultsQuery.insights(records: records, runs: [])
            .contains { $0.kind == "healReliance" })
    }

    // MARK: - insights: retiredScenarios(ソース照合)

    /// **ソースに無いクラスは日付を問わず retired**(削除・_disabled 化。日数の窓では消えない)
    func testInsightsRetiresScenariosMissingFromTheSource() {
        let records = (0..<3).map { index in
            makeRecord(
                scenarioID: "Gone.a", passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [], definedClasses: ["Live"])
        XCTAssertFalse(rows.contains { $0.scenarioID == "Gone.a" })
        XCTAssertEqual(rows.first { $0.kind == "retiredScenarios" }?.count, 1)
    }

    /// **空集合を「全部消えた」と読まない**(走査に失敗したときに検知が丸ごと黙るのを防ぐ)
    func testInsightsTreatsAnEmptyDefinedSetAsUnknown() {
        let records = (0..<3).map { index in
            makeRecord(
                scenarioID: "Foo.a", passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100)
        }
        let rows = RunResultsQuery.insights(records: records, runs: [], definedClasses: [])
        XCTAssertTrue(rows.contains { $0.kind == "consecutiveFailures" })
        XCTAssertFalse(rows.contains { $0.kind == "retiredScenarios" })
    }

    // MARK: - matrix

    func testMatrixBasicPivot() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 2),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z", total: 2),
        ]
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 100, runID: "R2"),
            makeRecord(
                scenarioID: "Foo.b", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 100, runID: "R2"),
        ]
        let report = RunResultsQuery.matrix(records: records, runs: runs, limit: 10)
        XCTAssertEqual(report.runs.map(\.runID), ["R2", "R1"])  // startedAt 降順

        let fooA = report.scenarios.first { $0.scenarioID == "Foo.a" }
        XCTAssertEqual(fooA?.cells, [0, 1])  // 列順は runs と同じ(R2: fail, R1: pass)→ flaky

        let fooB = report.scenarios.first { $0.scenarioID == "Foo.b" }
        XCTAssertEqual(fooB?.cells, [1, nil])  // R2: pass, R1: このシナリオの記録なし
    }

    func testMatrixOrderingGroupsAndExcludesOutOfWindowScenarios() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 2),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z", total: 2),
            makeMeta(runID: "R3", startedAt: "2026-01-03T00:00:00Z", total: 2),
            makeMeta(runID: "R4", startedAt: "2026-01-04T00:00:00Z", total: 2),
        ]
        let records = [
            // flaky(挿入順をわざとアルファベット逆にして並び替えを検証)
            makeRecord(
                scenarioID: "Zeta.flaky", passed: false, startedAt: "2026-01-03T00:00:00Z", durationMs: 100,
                runID: "R3"),
            makeRecord(
                scenarioID: "Zeta.flaky", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                runID: "R2"),
            makeRecord(
                scenarioID: "Alpha.flaky", passed: true, startedAt: "2026-01-04T00:00:00Z", durationMs: 100,
                runID: "R4"),
            makeRecord(
                scenarioID: "Alpha.flaky", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                runID: "R2"),
            // all-fail
            makeRecord(
                scenarioID: "Yankee.fail", passed: false, startedAt: "2026-01-04T00:00:00Z", durationMs: 100,
                runID: "R4"),
            makeRecord(
                scenarioID: "Bravo.fail", passed: false, startedAt: "2026-01-03T00:00:00Z", durationMs: 100,
                runID: "R3"),
            // all-pass
            makeRecord(
                scenarioID: "Mike.pass", passed: true, startedAt: "2026-01-04T00:00:00Z", durationMs: 100,
                runID: "R4"),
            makeRecord(
                scenarioID: "Charlie.pass", passed: true, startedAt: "2026-01-03T00:00:00Z", durationMs: 100,
                runID: "R3"),
            // window(直近3件=R4,R3,R2)の外(R1)にしか出現しないので除外される
            makeRecord(
                scenarioID: "Never.outside", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                runID: "R1"),
        ]
        let report = RunResultsQuery.matrix(records: records, runs: runs, limit: 3)
        XCTAssertEqual(report.runs.map(\.runID), ["R4", "R3", "R2"])
        XCTAssertEqual(report.scenarios.map(\.scenarioID), [
            "Alpha.flaky", "Zeta.flaky", "Bravo.fail", "Yankee.fail", "Charlie.pass", "Mike.pass",
        ])
    }

    func testMatrixWindowSelectionUsesStartedAtNotArrayOrder() {
        // runs 配列の並びと startedAt の並びを意図的にずらす
        let runs = [
            makeMeta(runID: "R3", startedAt: "2026-01-03T00:00:00Z", total: 1),
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 1),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z", total: 1),
        ]
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 100, runID: "R2"),
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-03T00:00:00Z", durationMs: 100, runID: "R3"),
        ]
        let report = RunResultsQuery.matrix(records: records, runs: runs, limit: 2)
        XCTAssertEqual(report.runs.map(\.runID), ["R3", "R2"])  // 新しい2件のみ(R1 は限界外)
        let fooA = report.scenarios.first { $0.scenarioID == "Foo.a" }
        XCTAssertEqual(fooA?.cells, [0, 1])
    }

    func testMatrixExcludesRunsWithNilOrZeroTotal() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 2),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z", total: 0),
            makeMeta(runID: "R3", startedAt: "2026-01-03T00:00:00Z", total: nil),
        ]
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 100, runID: "R2"),
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-03T00:00:00Z", durationMs: 100, runID: "R3"),
        ]
        let report = RunResultsQuery.matrix(records: records, runs: runs, limit: 10)
        XCTAssertEqual(report.runs.map(\.runID), ["R1"])  // total==0/nil の R2/R3 は窓から除外
        let fooA = report.scenarios.first { $0.scenarioID == "Foo.a" }
        XCTAssertEqual(fooA?.cells, [1])  // R2/R3 のレコードはセルに現れない
    }

    func testMatrixLimitZeroReturnsEmptyReport() {
        let runs = [makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 2)]
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
        ]
        let report = RunResultsQuery.matrix(records: records, runs: runs, limit: 0)
        XCTAssertTrue(report.runs.isEmpty)
        XCTAssertTrue(report.scenarios.isEmpty)
    }

    func testMatrixDuplicateRunScenarioPairPicksLatestStartedAt() {
        let runs = [makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 2)]
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
            // ~2 サフィックスのリトライ相当。startedAt が後発の方が勝つ
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:05:00Z", durationMs: 100, runID: "R1"),
        ]
        let report = RunResultsQuery.matrix(records: records, runs: runs, limit: 10)
        let fooA = report.scenarios.first { $0.scenarioID == "Foo.a" }
        XCTAssertEqual(fooA?.cells, [1])
    }

    func testMatrixTitleUsesChronologicallyLatestRecord() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 1),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z", total: 1),
        ]
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                runID: "R1", title: "Old Title"),
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                runID: "R2", title: "New Title"),
        ]
        let report = RunResultsQuery.matrix(records: records, runs: runs, limit: 10)
        XCTAssertEqual(report.scenarios.first { $0.scenarioID == "Foo.a" }?.title, "New Title")
    }

    // MARK: - triage

    func testTriageGroupsBySectionCommandAndFailureKind() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                failedSteps: [FailedStepRecord(
                    index: 0, section: "action", description: "tap #btn", command: "tap",
                    failureKind: "assertionFailed")]),
            makeRecord(
                scenarioID: "Foo.b", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                failedSteps: [FailedStepRecord(
                    index: 0, section: "action", description: "tap #btn", command: "tap",
                    failureKind: "assertionFailed")]),
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-03T00:00:00Z", durationMs: 100,
                failedSteps: [FailedStepRecord(
                    index: 0, section: "action", description: "tap #btn", command: "tap",
                    failureKind: "assertionFailed")]),
        ]
        let report = RunResultsQuery.triage(records)
        XCTAssertEqual(report.totalFailed, 3)
        XCTAssertEqual(report.unreachedCount, 0)
        XCTAssertEqual(report.rows.count, 1)
        let row = report.rows[0]
        XCTAssertEqual(row.section, "action")
        XCTAssertEqual(row.command, "tap")
        XCTAssertEqual(row.failureKind, "assertionFailed")
        XCTAssertEqual(row.count, 3)
        XCTAssertEqual(row.scenarioCount, 2, "distinct scenarioID(Foo.a, Foo.b)")
    }

    /// failedSteps が nil/空(ステップ未到達)は rows に混ざらず unreachedCount へ分かれる
    func testTriageCountsUnreachedFailuresSeparatelyFromRows() {
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                       failedSteps: nil),
            makeRecord(scenarioID: "Foo.b", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                       failedSteps: []),
        ]
        let report = RunResultsQuery.triage(records)
        XCTAssertEqual(report.totalFailed, 2)
        XCTAssertEqual(report.unreachedCount, 2)
        XCTAssertTrue(report.rows.isEmpty)
    }

    /// **丸めない**: nil の欄と値ありの欄は別グループのまま残す(CLAUDE.md「その他に丸めない」)
    func testTriageKeepsNilFieldsAsASeparateGroupFromValuedOnes() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                failedSteps: [FailedStepRecord(index: 0, description: "x")]),
            makeRecord(
                scenarioID: "Foo.b", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                failedSteps: [FailedStepRecord(
                    index: 0, section: "action", description: "x", command: "tap",
                    failureKind: "assertionFailed")]),
        ]
        let report = RunResultsQuery.triage(records)
        XCTAssertEqual(report.rows.count, 2)
        XCTAssertTrue(report.rows.contains { $0.section == nil && $0.command == nil && $0.failureKind == nil })
        XCTAssertTrue(report.rows.contains { $0.section == "action" && $0.command == "tap" })
    }

    func testTriageScenarioIDsAreDistinctSortedAndCappedAtFive() {
        let ids = ["S6.a", "S1.a", "S4.a", "S2.a", "S5.a", "S3.a"]
        var records = ids.enumerated().map { index, id in
            makeRecord(
                scenarioID: id, passed: false,
                startedAt: String(format: "2026-01-0%dT00:00:00Z", index + 1), durationMs: 100,
                failedSteps: [FailedStepRecord(
                    index: 0, section: "action", description: "x", command: "tap",
                    failureKind: "assertionFailed")])
        }
        // 同じ scenarioID(S1.a)の2件目を足す。distinct 数はこれで増えないことを確かめる
        records.append(makeRecord(
            scenarioID: "S1.a", passed: false, startedAt: "2026-01-07T00:00:00Z", durationMs: 100,
            failedSteps: [FailedStepRecord(
                index: 0, section: "action", description: "x", command: "tap",
                failureKind: "assertionFailed")]))

        let report = RunResultsQuery.triage(records)
        XCTAssertEqual(report.rows.count, 1)
        let row = report.rows[0]
        XCTAssertEqual(row.count, 7)
        XCTAssertEqual(row.scenarioCount, 6)
        XCTAssertEqual(row.scenarioIDs, ["S1.a", "S2.a", "S3.a", "S4.a", "S5.a"])
    }

    func testTriageNoteCountsAggregatesAndSorts() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                failedSteps: [FailedStepRecord(index: 0, description: "x", notes: ["noteB", "noteA"])]),
            makeRecord(
                scenarioID: "Foo.b", passed: false, startedAt: "2026-01-02T00:00:00Z", durationMs: 100,
                failedSteps: [FailedStepRecord(index: 0, description: "x", notes: ["noteA"])]),
        ]
        let report = RunResultsQuery.triage(records)
        XCTAssertEqual(report.noteCounts.count, 2)
        XCTAssertEqual(report.noteCounts[0].note, "noteA")
        XCTAssertEqual(report.noteCounts[0].count, 2)
        XCTAssertEqual(report.noteCounts[1].note, "noteB")
        XCTAssertEqual(report.noteCounts[1].count, 1)
    }

    func testTriageIgnoresPassedRecords() {
        let records = [
            makeRecord(
                scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100,
                failedSteps: [FailedStepRecord(
                    index: 0, section: "action", description: "x", command: "tap",
                    failureKind: "assertionFailed", notes: ["someNote"])]),
        ]
        let report = RunResultsQuery.triage(records)
        XCTAssertEqual(report.totalFailed, 0)
        XCTAssertEqual(report.unreachedCount, 0)
        XCTAssertTrue(report.rows.isEmpty)
        XCTAssertTrue(report.noteCounts.isEmpty)
    }

    // MARK: - fullSuiteDaily

    func testFullSuiteDailyExcludesRunsBelowMinScenarios() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 2),
            makeMeta(runID: "R2", startedAt: "2026-01-01T00:00:00Z", total: 3),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R2"),
        ]
        let rows = RunResultsQuery.fullSuiteDaily(
            records: records, runs: runs, minScenarios: 3, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].total, 1, "total=2 の R1 は除外される")
    }

    func testFullSuiteDailyExcludesUnfinishedRuns() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: nil),
            makeMeta(runID: "R2", startedAt: "2026-01-01T00:00:00Z", total: 3),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R2"),
        ]
        let rows = RunResultsQuery.fullSuiteDaily(
            records: records, runs: runs, minScenarios: 3, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].total, 1, "total=nil(未完了)の R1 は除外される")
    }

    func testFullSuiteDailyIncludesRunsAtOrAboveThreshold() {
        let runs = [makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", total: 3)]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
            makeRecord(scenarioID: "Foo.b", passed: false, startedAt: "2026-01-01T00:00:00Z", durationMs: 100, runID: "R1"),
        ]
        let rows = RunResultsQuery.fullSuiteDaily(
            records: records, runs: runs, minScenarios: 3, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].total, 2)
        XCTAssertEqual(rows[0].passed, 1)
        XCTAssertEqual(rows[0].failed, 1)
    }

    // MARK: - performance

    func testPerformanceReportExcludesRunsWithoutPerformanceModeAndCountsInvalid() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 1),  // 既定モード run(performanceMode なし)
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z",
                     finishedAt: "2026-01-02T00:01:00Z", total: 1,
                     performanceMode: true, measurementInvalid: true),  // 計測無効
            makeMeta(runID: "R3", startedAt: "2026-01-03T00:00:00Z",
                     finishedAt: "2026-01-03T00:01:00Z", total: 1, performanceMode: true),  // 有効
        ]
        let report = RunResultsQuery.performanceReport(records: [], runs: runs)
        XCTAssertEqual(report.runs.map(\.runID), ["R3"])
        XCTAssertEqual(report.invalidCount, 1)
    }

    func testPerformanceReportComputesWallClockMsAndNilsOnMissingFinishedAt() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:30Z", total: 1, performanceMode: true),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z",
                     finishedAt: nil, total: 1, performanceMode: true),
        ]
        let report = RunResultsQuery.performanceReport(records: [], runs: runs)
        XCTAssertEqual(report.runs.first { $0.runID == "R1" }?.wallClockMs, 90_000)
        XCTAssertNil(report.runs.first { $0.runID == "R2" }?.wallClockMs)
    }

    func testPerformanceReportScenarioTotalsExcludeSkippedSynthetic() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 2, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 300, runID: "R1"),
            makeRecord(
                scenarioID: "Foo.b", passed: false, startedAt: "2026-01-01T00:00:20Z", durationMs: 0,
                steps: StepCountsRecord(total: 1, skipped: 1), runID: "R1"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        let row = report.runs.first
        XCTAssertEqual(row?.scenarioTotalMs, 300)
        XCTAssertEqual(row?.scenarioCount, 1)
    }

    func testPerformanceComparisonOnlyIncludesScenariosPresentInBoth() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 2, performanceMode: true),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z",
                     finishedAt: "2026-01-02T00:01:00Z", total: 2, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 100, runID: "R1"),
            // R2 に居ない → 比較対象外
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-01T00:00:20Z",
                       durationMs: 100, runID: "R1"),
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-02T00:00:10Z",
                       durationMs: 150, runID: "R2"),
            // R1 に居ない → 比較対象外
            makeRecord(scenarioID: "Foo.c", passed: true, startedAt: "2026-01-02T00:00:20Z",
                       durationMs: 100, runID: "R2"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertEqual(report.comparedRunID, "R1")
        XCTAssertEqual(report.comparison.map(\.scenarioID), ["Foo.a"], "両方に居る組だけ比較する")
        let delta = report.comparison[0]
        XCTAssertEqual(delta.latestMs, 150)
        XCTAssertEqual(delta.previousMs, 100)
        XCTAssertEqual(delta.deltaPct, 50, accuracy: 0.001)
    }

    /// 失敗レコードの durationMs はタイムアウト等「失敗経路の長さ」であって性能ではない。
    /// どちらか片側でも失敗していた組は比較に混ぜない(巨大な偽の悪化が先頭に並ぶ)
    func testPerformanceComparisonExcludesFailedRecords() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 2, performanceMode: true),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z",
                     finishedAt: "2026-01-02T00:01:00Z", total: 2, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 100, runID: "R1"),
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-01T00:00:20Z",
                       durationMs: 100, runID: "R1"),
            // 最新側で失敗(タイムアウト相当の長大な所要)→ この組は比較に出ない
            makeRecord(scenarioID: "Foo.a", passed: false, startedAt: "2026-01-02T00:00:10Z",
                       durationMs: 90_000, runID: "R2"),
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-02T00:00:20Z",
                       durationMs: 120, runID: "R2"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertEqual(report.comparison.map(\.scenarioID), ["Foo.b"],
                       "失敗した Foo.a の組は比較から外れる")
    }

    /// 相手の選定は同じ (profile, host) の run だけを対象にする。別 profile の run を挟んでも
    /// 飛び越して正しい相手を選ぶこと
    func testPerformanceComparisonSkipsPastADifferentProfileRunToFindTheSamePair() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", finishedAt: "2026-01-01T00:01:00Z",
                     total: 1, profile: "p1", host: "m1", performanceMode: true),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z", finishedAt: "2026-01-02T00:01:00Z",
                     total: 1, profile: "p2", host: "m1", performanceMode: true),
            makeMeta(runID: "R3", startedAt: "2026-01-03T00:00:00Z", finishedAt: "2026-01-03T00:01:00Z",
                     total: 1, profile: "p1", host: "m1", performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 100, runID: "R1"),
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-02T00:00:10Z",
                       durationMs: 999, runID: "R2"),
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-03T00:00:10Z",
                       durationMs: 200, runID: "R3"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertEqual(report.comparedRunID, "R1", "別 profile の R2 を飛び越えて同じ (profile,host) の R1 を選ぶ")
        XCTAssertEqual(report.comparison.first?.previousMs, 100)
        XCTAssertEqual(report.comparison.first?.latestMs, 200)
    }

    func testPerformanceComparisonEmptyWhenNoPartnerRun() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 1, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 100, runID: "R1"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertTrue(report.comparison.isEmpty)
        XCTAssertNil(report.comparedRunID)
    }

    func testPerformanceComparisonExcludesZeroPreviousDuration() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 1, performanceMode: true),
            makeMeta(runID: "R2", startedAt: "2026-01-02T00:00:00Z",
                     finishedAt: "2026-01-02T00:01:00Z", total: 1, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 0, runID: "R1"),
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-02T00:00:10Z",
                       durationMs: 100, runID: "R2"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertTrue(report.comparison.isEmpty, "previous==0 は比率が発散するため除外")
        XCTAssertEqual(report.comparedRunID, "R1", "比較相手自体は選ばれる(除外されるのは組だけ)")
    }

    func testPerformanceReportMaxScenarioTiesBreakByScenarioIDAscending() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 3, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Zebra.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 500, runID: "R1"),
            makeRecord(scenarioID: "Alpha.a", passed: true, startedAt: "2026-01-01T00:00:20Z",
                       durationMs: 500, runID: "R1"),
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:30Z",
                       durationMs: 100, runID: "R1"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        let row = report.runs.first
        XCTAssertEqual(row?.maxScenarioMs, 500)
        XCTAssertEqual(row?.maxScenarioID, "Alpha.a", "同値は scenarioID 昇順")
    }

    func testPerformanceReportMaxScenarioNilWhenNoRecords() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 0, performanceMode: true),
        ]
        let report = RunResultsQuery.performanceReport(records: [], runs: runs)
        let row = report.runs.first
        XCTAssertNil(row?.maxScenarioMs)
        XCTAssertNil(row?.maxScenarioID)
    }

    func testPerformanceReportLaneCountExcludesNilWorker() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 4, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 100, worker: "ios:iPhone 17", runID: "R1"),
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-01T00:00:20Z",
                       durationMs: 100, worker: "ios:iPhone 17", runID: "R1"),
            makeRecord(scenarioID: "Foo.c", passed: true, startedAt: "2026-01-01T00:00:30Z",
                       durationMs: 100, worker: "android:Pixel 9", runID: "R1"),
            makeRecord(scenarioID: "Foo.d", passed: true, startedAt: "2026-01-01T00:00:40Z",
                       durationMs: 100, worker: nil, runID: "R1"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertEqual(report.runs.first?.laneCount, 2, "distinct worker 2 種(worker nil のレコードは数えない)")
    }

    func testPerformanceReportAvgLaneUtilisationComputesPercentage() {
        // wallClockMs = 100_000 / laneCount = 2 / scenarioTotalMs = 150_000 → 150000/(2*100000)*100 = 75%
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:40Z", total: 2, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 80_000, worker: "ios:A", runID: "R1"),
            makeRecord(scenarioID: "Foo.b", passed: true, startedAt: "2026-01-01T00:00:20Z",
                       durationMs: 70_000, worker: "ios:B", runID: "R1"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertEqual(report.runs.first?.avgLaneUtilisationPct ?? 0, 75, accuracy: 0.001)
    }

    func testPerformanceReportAvgLaneUtilisationNilWhenWallClockMissing() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z", finishedAt: nil,
                     total: 1, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 100, worker: "ios:A", runID: "R1"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertNil(report.runs.first?.avgLaneUtilisationPct)
    }

    func testPerformanceReportAvgLaneUtilisationNilWhenNoLanes() {
        let runs = [
            makeMeta(runID: "R1", startedAt: "2026-01-01T00:00:00Z",
                     finishedAt: "2026-01-01T00:01:00Z", total: 1, performanceMode: true),
        ]
        let records = [
            makeRecord(scenarioID: "Foo.a", passed: true, startedAt: "2026-01-01T00:00:10Z",
                       durationMs: 100, worker: nil, runID: "R1"),
        ]
        let report = RunResultsQuery.performanceReport(records: records, runs: runs)
        XCTAssertNil(report.runs.first?.avgLaneUtilisationPct, "laneCount==0")
    }

    // MARK: - フィクスチャ

    private func makeMeta(
        runID: String, startedAt: String = "2026-01-01T00:00:00Z", finishedAt: String? = nil, total: Int? = 1,
        profile: String? = nil, host: String = "testmachine",
        performanceMode: Bool? = nil, measurementInvalid: Bool? = nil
    ) -> RunMetaRecord {
        RunMetaRecord(
            runID: runID, project: "SampleApp", profile: profile, host: host,
            trigger: "cli", startedAt: startedAt, finishedAt: finishedAt, total: total,
            measurementInvalid: measurementInvalid, performanceMode: performanceMode)
    }

    private func makeRecord(
        scenarioID: String, passed: Bool, startedAt: String, durationMs: Int,
        steps: StepCountsRecord? = nil, platform: String = "ios", worker: String? = nil,
        timedOut: Bool? = nil, scenes: [SceneResultRecord] = [],
        failedSteps: [FailedStepRecord]? = nil, errorLogs: [String]? = nil,
        runID: String = "", title: String? = nil,
        fixSuggestions: [FixSuggestionRecord]? = nil
    ) -> ScenarioRunRecord {
        ScenarioRunRecord(
            runID: runID, scenarioID: scenarioID, title: title, platform: platform, worker: worker,
            host: "testmachine",
            passed: passed, timedOut: timedOut, startedAt: startedAt, durationMs: durationMs,
            scenes: scenes, steps: steps ?? StepCountsRecord(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1),
            failedSteps: failedSteps, fixSuggestions: fixSuggestions, errorLogs: errorLogs)
    }
}

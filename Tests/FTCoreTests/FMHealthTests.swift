import XCTest
@testable import FTCore

/// FM 呼び出しの回数・レイテンシ集計。要件は2つ:
/// (1) 全滅して機能が黙って無効になったことを実行後に検知できる
/// (2) FM は直列化するため、コスト(回数と時間)を結果 JSON まで運べる
final class FMHealthTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FMHealth.reset()
    }

    override func tearDown() {
        FMHealth.reset()
        super.tearDown()
    }

    /// 未使用なら警告も usage も出さない。FM を使わない実行を汚さないため
    func testSilentWhenNeverCalled() {
        XCTAssertNil(FMHealth.warningText())
        XCTAssertNil(FMHealth.usage())
        XCTAssertEqual(FMHealth.snapshot().attempted, 0)
    }

    /// 全て成功なら失敗警告は出ないが、コストは記録される(成功実行こそコスト分析に必要)
    func testSuccessOnlyStillReportsCost() throws {
        FMHealth.record(kind: "occlusion", ms: 1200, ok: true)
        FMHealth.record(kind: "occlusion", ms: 800, ok: true)
        XCTAssertNil(FMHealth.warningText())

        let usage = try XCTUnwrap(FMHealth.usage())
        XCTAssertEqual(usage.calls, 2)
        XCTAssertEqual(usage.failures, 0)
        XCTAssertEqual(usage.totalMs, 2000)
    }

    /// 全滅: allFailed が立ち、警告に「無効でした」と最初のエラーが載る
    func testAllFailedProducesWarning() {
        FMHealth.record(kind: "occlusion", ms: 90, ok: false, error: "ModelManagerError 1001")
        FMHealth.record(kind: "occlusion", ms: 95, ok: false, error: "後続は捨てられる")
        let snap = FMHealth.snapshot()
        XCTAssertTrue(snap.allFailed)
        XCTAssertEqual(snap.failures, 2)

        let warning = FMHealth.warningText()
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("disabled for this run"), warning!)
        XCTAssertTrue(warning!.contains("ModelManagerError 1001"), warning!)
        // firstError は最初の1件だけ保持する(同一原因が連続するため)
        XCTAssertEqual(snap.firstError, "ModelManagerError 1001")
    }

    /// 部分失敗は allFailed にしない(全滅と区別する)が、警告は出す
    func testPartialFailureWarnsButIsNotAllFailed() {
        FMHealth.record(kind: "occlusion", ms: 1000, ok: true)
        FMHealth.record(kind: "screenLooksLike", ms: 50, ok: false, error: "boom")
        XCTAssertFalse(FMHealth.snapshot().allFailed)
        XCTAssertTrue(FMHealth.warningText()!.contains("Some FM calls failed"))
    }

    /// 用途別に内訳が取れる(occlusion が支配的かを実行後に判定するため)
    func testUsageIsBrokenDownByKind() {
        FMHealth.record(kind: "occlusion", ms: 1000, ok: true)
        FMHealth.record(kind: "occlusion", ms: 3000, ok: true)
        FMHealth.record(kind: "heal", ms: 500, ok: true)

        let usage = FMHealth.usage()!
        XCTAssertEqual(usage.calls, 3)
        XCTAssertEqual(usage.totalMs, 4500)
        XCTAssertEqual(usage.byKind["occlusion"]?.calls, 2)
        XCTAssertEqual(usage.byKind["occlusion"]?.totalMs, 4000)
        XCTAssertEqual(usage.byKind["occlusion"]?.maxMs, 3000)
        XCTAssertEqual(usage.byKind["heal"]?.calls, 1)
        XCTAssertNil(usage.byKind["screenLooksLike"])
    }

    /// p50 / max がレイテンシ分布を反映する
    func testPercentileAndMax() {
        for ms in [100.0, 200.0, 300.0, 4000.0] {
            FMHealth.record(kind: "occlusion", ms: ms, ok: true)
        }
        let usage = FMHealth.usage()!
        XCTAssertEqual(usage.maxMs, 4000)
        XCTAssertEqual(usage.totalMs, 4600)
        // 4件の p50 はソート後 index 2 = 300
        XCTAssertEqual(usage.p50Ms, 300)
    }

    /// 結果 JSON へ載るため Codable でラウンドトリップできること
    func testUsageRecordRoundTripsThroughJSON() throws {
        FMHealth.record(kind: "occlusion", ms: 1200, ok: true)
        FMHealth.record(kind: "heal", ms: 300, ok: false, error: "e")
        let usage = try XCTUnwrap(FMHealth.usage())

        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(FMUsageRecord.self, from: data)
        XCTAssertEqual(decoded.calls, 2)
        XCTAssertEqual(decoded.failures, 1)
        XCTAssertEqual(decoded.totalMs, 1500)
        XCTAssertEqual(decoded.byKind["occlusion"]?.calls, 1)
    }

    /// scenarioFinished に載せて NDJSON 経由で往復できること(親プロセスへの伝達経路)
    func testSurvivesScenarioEventNDJSONRoundTrip() throws {
        FMHealth.record(kind: "occlusion", ms: 9400, ok: true)
        var event = ScenarioEvent(kind: "scenarioFinished")
        event.fm = FMHealth.usage()

        let decoded = try XCTUnwrap(ScenarioEvent.decode(line: event.encodedLine()))
        XCTAssertEqual(decoded.fm?.calls, 1)
        XCTAssertEqual(decoded.fm?.totalMs, 9400)
    }

    /// FM 未使用のシナリオでは fm キーごと省略され、旧クライアントを壊さない
    func testAbsentWhenUnusedInNDJSON() throws {
        var event = ScenarioEvent(kind: "scenarioFinished")
        event.fm = FMHealth.usage()   // nil
        let line = event.encodedLine()
        XCTAssertFalse(line.contains("\"fm\""), line)
    }

    /// runner → 親 → 結果 JSON まで届くこと(集計はこの JSON を舐めて行うため経路が命)
    func testReachesScenarioRunRecordViaBuilder() throws {
        FMHealth.record(kind: "occlusion", ms: 1200, ok: true)
        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.fm = FMHealth.usage()
        finished.reportPath = "/tmp/r.md"

        var builder = ScenarioRecordBuilder(scenarioID: "S.T", platform: "ios",
                                            title: "t", worker: "ios:dev-01")
        builder.consume(finished)
        let record = builder.build(passed: true, timedOut: false, startedAt: Date(),
                                   durationMs: 5000, packageRoot: nil)

        XCTAssertEqual(record.fm?.calls, 1)
        XCTAssertEqual(record.fm?.totalMs, 1200)

        // 結果 JSON へ実際に載ること
        let json = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(ScenarioRunRecord.self, from: json)
        XCTAssertEqual(back.fm?.byKind["occlusion"]?.calls, 1)
    }

    /// 成功シナリオでも fm は残る(failedSteps 等と違い、コスト分析は成功実行こそ必要)
    func testFMKeptOnPassedScenarioUnlikeFailureFields() throws {
        FMHealth.record(kind: "occlusion", ms: 900, ok: true)
        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.fm = FMHealth.usage()

        var builder = ScenarioRecordBuilder(scenarioID: "S.T", platform: "ios",
                                            title: nil, worker: nil)
        builder.consume(finished)
        let record = builder.build(passed: true, timedOut: false, startedAt: Date(),
                                   durationMs: 1000, packageRoot: nil)
        XCTAssertNil(record.failedSteps)      // 失敗系は passed で落とされる
        XCTAssertNotNil(record.fm)            // FM 実測は残る
    }

    /// 並行記録でカウンタが失われない(FM 呼び出しは複数タスクから走る)
    func testConcurrentRecordingIsLockProtected() {
        let iterations = 500
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            FMHealth.record(kind: i.isMultiple(of: 2) ? "occlusion" : "heal",
                            ms: 10, ok: i.isMultiple(of: 3), error: "e")
        }
        XCTAssertEqual(FMHealth.snapshot().attempted, iterations)
        XCTAssertEqual(FMHealth.usage()?.calls, iterations)
    }

    /// ゲート待ちを1度も記録しなければ 3欄とも 0(呼び出し自体はある = usage は nil ではない)
    func testGateWaitDefaultsToZeroWhenNeverRecorded() throws {
        FMHealth.record(kind: "occlusion", ms: 100, ok: true)
        let usage = try XCTUnwrap(FMHealth.usage())
        XCTAssertEqual(usage.gateWaitTotalMs, 0)
        XCTAssertEqual(usage.gateWaitP50Ms, 0)
        XCTAssertEqual(usage.gateWaitMaxMs, 0)
    }

    /// 単一サンプルなら total/p50/max が全て同じ値になる
    func testGateWaitSingleSample() throws {
        FMHealth.record(kind: "occlusion", ms: 100, ok: true)
        FMHealth.recordGateWait(ms: 42)
        let usage = try XCTUnwrap(FMHealth.usage())
        XCTAssertEqual(usage.gateWaitTotalMs, 42)
        XCTAssertEqual(usage.gateWaitP50Ms, 42)
        XCTAssertEqual(usage.gateWaitMaxMs, 42)
    }

    /// 偶数個: p50 は totalMs/maxMs と別軸で集計されている(呼び出しコストと混ざらない)
    func testGateWaitEvenCount() throws {
        FMHealth.record(kind: "occlusion", ms: 100, ok: true)
        for ms in [10.0, 20.0, 30.0, 40.0] {
            FMHealth.recordGateWait(ms: ms)
        }
        let usage = try XCTUnwrap(FMHealth.usage())
        XCTAssertEqual(usage.gateWaitTotalMs, 100)
        // 4件の p50 はソート後 index 2 = 30(FMHealth.percentileMs と同じ単純規則)
        XCTAssertEqual(usage.gateWaitP50Ms, 30)
        XCTAssertEqual(usage.gateWaitMaxMs, 40)
    }

    /// 奇数個: p50 は中央のサンプルを直接返す
    func testGateWaitOddCount() throws {
        FMHealth.record(kind: "occlusion", ms: 100, ok: true)
        for ms in [10.0, 20.0, 30.0] {
            FMHealth.recordGateWait(ms: ms)
        }
        let usage = try XCTUnwrap(FMHealth.usage())
        XCTAssertEqual(usage.gateWaitTotalMs, 60)
        XCTAssertEqual(usage.gateWaitP50Ms, 20)
        XCTAssertEqual(usage.gateWaitMaxMs, 30)
    }

    /// 古い結果 JSON(gateWait* 欄が無い)をデコードしても失敗せず 0 で埋まる
    func testDecodingWithoutGateWaitFieldsDefaultsToZero() throws {
        let legacyJSON = """
        {"calls":2,"failures":0,"totalMs":1500,"p50Ms":700,"maxMs":800,"byKind":{}}
        """
        let decoded = try JSONDecoder().decode(FMUsageRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.calls, 2)
        XCTAssertEqual(decoded.totalMs, 1500)
        XCTAssertEqual(decoded.gateWaitTotalMs, 0)
        XCTAssertEqual(decoded.gateWaitP50Ms, 0)
        XCTAssertEqual(decoded.gateWaitMaxMs, 0)
    }

    /// 新しい結果 JSON は gateWait* を含めて往復する
    func testGateWaitRoundTripsThroughJSON() throws {
        FMHealth.record(kind: "occlusion", ms: 100, ok: true)
        FMHealth.recordGateWait(ms: 55)
        let usage = try XCTUnwrap(FMHealth.usage())
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(FMUsageRecord.self, from: data)
        XCTAssertEqual(decoded.gateWaitTotalMs, 55)
        XCTAssertEqual(decoded.gateWaitP50Ms, 55)
        XCTAssertEqual(decoded.gateWaitMaxMs, 55)
    }

    /// usage() は recordSkip() の件数を Snapshot.skipped と同じ値で載せる
    func testUsageCarriesSkippedCount() throws {
        FMHealth.record(kind: "occlusion", ms: 100, ok: true)
        FMHealth.recordSkip()
        FMHealth.recordSkip()
        let usage = try XCTUnwrap(FMHealth.usage())
        XCTAssertEqual(usage.skipped, 2)
        XCTAssertEqual(usage.skipped, FMHealth.snapshot().skipped)
    }

    /// 古い結果 JSON(skipped 欄が無い)をデコードしても失敗せず 0 で埋まる
    /// (gateWait* と同じ流儀。CLAUDE.md: 「読めない」と「呼び出し 0 件」を混ぜない ——
    /// ここは skipped という欄自体が無い版の話なので 0 で埋めてよい)
    func testDecodingWithoutSkippedFieldDefaultsToZero() throws {
        let legacyJSON = """
        {"calls":2,"failures":0,"totalMs":1500,"p50Ms":700,"maxMs":800,"byKind":{}}
        """
        let decoded = try JSONDecoder().decode(FMUsageRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.calls, 2)
        XCTAssertEqual(decoded.skipped, 0)
    }
}

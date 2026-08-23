import XCTest
@testable import FTCore

/// 注記の**表示文言と機械可読コードが同じ事象を指すこと**、およびコードが
/// results/ まで運ばれて run 横断で数えられることの検証。
/// 経路は StepNote.swift の doc(StepExecutor → StepOutcome → ScenarioEvent → TimelineStepRecord)。
final class StepNoteTests: XCTestCase {

    // MARK: - 表示とコードの対

    /// 文言だけを書き換えて集計を素通りさせないための固定。**この値を変えると
    /// 過去の results/ と比較できなくなる**(rawValue は永続化されるため)
    func testRawValuesArePersistedIdentifiers() {
        XCTAssertEqual(StepNote.settleCapped.rawValue, "settle-capped")
        XCTAssertEqual(StepNote.heldValue.rawValue, "held-value")
        XCTAssertEqual(StepNote.visibilityGuardSkipped.rawValue, "visibility-guard-skipped")
        XCTAssertEqual(StepNote.systemAlertPresent.rawValue, "system-alert-present")
    }

    // MARK: - 永続化(results/ まで運ばれるか)

    func testRecordBuilderCarriesNotesAndCountsHeldValue() {
        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", platform: "ios",
                                            title: nil, worker: nil)
        builder.consume(stepEvent(index: 1, notes: [StepNote.settleCapped.rawValue]))
        builder.consume(stepEvent(index: 2, notes: [StepNote.heldValue.rawValue]))
        builder.consume(stepEvent(index: 3, notes: nil))

        let record = builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 1,
                                   packageRoot: nil)

        XCTAssertEqual(record.timeline?.map { $0.notes ?? [] },
                       [["settle-capped"], ["held-value"], []])
        XCTAssertEqual(record.steps.viaHeldValue, 1)
    }

    /// notes を持たない過去の results/ が読めること(Optional の後発追加である契約)
    func testLegacyRecordWithoutNotesStillDecodes() throws {
        let json = """
        {"schemaVersion":1,"runID":"r","scenarioID":"Foo.a","platform":"ios","machine":"m",
         "passed":true,"startedAt":"2026-01-01T00:00:00Z","durationMs":1,"scenes":[],
         "steps":{"total":1,"passed":1,"failed":0,"skipped":0,"healed":0,"passedViaFallback":0},
         "timeline":[{"index":1,"description":"tap","status":"passed"}]}
        """
        let record = try JSONDecoder().decode(ScenarioRunRecord.self,
                                              from: Data(json.utf8))
        XCTAssertNil(record.timeline?.first?.notes)
        XCTAssertNil(record.steps.viaHeldValue)
    }

    // MARK: - 集計(insights)

    func testUnsettledStepsWarnsWhenItRecursAcrossRuns() {
        let records = [
            runRecord(cappedSteps: 2), runRecord(cappedSteps: 1), runRecord(cappedSteps: 0),
        ]

        let rows = RunResultsQuery.insights(records: records, runs: [])

        let row = rows.first { $0.kind == "unsettledSteps" }
        XCTAssertEqual(row?.severity, "warn")
        XCTAssertEqual(row?.count, 3, "打ち切られたステップ数の合計")
        XCTAssertEqual(row?.scenarioID, "Foo.a")
    }

    /// 単発は出さないこと(1/3 = 33% でも run 数が閾値未満なら黙る側)
    func testUnsettledStepsStaysSilentBelowTheThreshold() {
        let rare = [runRecord(cappedSteps: 1)] + (0..<9).map { _ in runRecord(cappedSteps: 0) }
        XCTAssertNil(RunResultsQuery.insights(records: rare, runs: [])
            .first { $0.kind == "unsettledSteps" })

        let tooFewRuns = [runRecord(cappedSteps: 1), runRecord(cappedSteps: 1)]
        XCTAssertNil(RunResultsQuery.insights(records: tooFewRuns, runs: [])
            .first { $0.kind == "unsettledSteps" }, "run 数が足りないうちは判定しない")
    }

    /// notes を持たない旧レコードだけなら黙ること(「測れていない」を「異常あり」と言わない)
    func testUnsettledStepsStaysSilentForLegacyRecords() {
        let legacy = (0..<5).map { _ in
            ScenarioRunRecord(runID: "r", scenarioID: "Foo.a", title: nil, platform: "ios",
                              worker: nil, machine: "m", passed: true, timedOut: nil,
                              startedAt: "2026-01-01T00:00:00Z", durationMs: 1, scenes: [],
                              steps: StepCountsRecord(total: 1, passed: 1), timeline: nil)
        }
        XCTAssertNil(RunResultsQuery.insights(records: legacy, runs: [])
            .first { $0.kind == "unsettledSteps" })
    }

    // MARK: - ヘルパ

    private func stepEvent(index: Int, notes: [String]?) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "step")
        event.index = index
        event.description = "step \(index)"
        event.status = "passed"
        event.notes = notes
        return event
    }

    private func runRecord(cappedSteps: Int) -> ScenarioRunRecord {
        let timeline = (0..<3).map { index in
            TimelineStepRecord(index: index, description: "step", status: "passed",
                               notes: index < cappedSteps ? [StepNote.settleCapped.rawValue] : nil)
        }
        return ScenarioRunRecord(runID: "r", scenarioID: "Foo.a", title: nil, platform: "ios",
                                 worker: nil, machine: "m", passed: true, timedOut: nil,
                                 startedAt: "2026-01-01T00:00:00Z", durationMs: 1, scenes: [],
                                 steps: StepCountsRecord(total: 3, passed: 3), timeline: timeline)
    }
}

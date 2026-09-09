// ステップの締め切り(FTSync.commandTimeout = 壁時計 120 秒)が妥当かを判定するための計器。
//
// **なぜ要るか**(実測 2026-09-10): フル E2E で 20 秒を超えたステップ 38 件は、
// snapshot/action/wait のどれにも計上されない時間が **99.7%** を占めていた。壁時計だけでは
// 「相手が固まっていた」と「順番待ち・ホスト飽和で進めなかった」を区別できない。
//   - scheduleDelayMs: async タスクを作ってから最初の1命令が走るまで(順番待ち)
//   - cpuMs: その間にプロセスが実際に貰えた CPU 時間
//
// ここが守るのは「不明を 0 に丸めない」ことと、CPU 時間が単調に増えること。

import XCTest
@testable import FTCore

final class StepBudgetInstrumentTests: XCTestCase {

    func testProcessCPUTimeIsMonotonicAndPositive() {
        guard let first = ProcessCPUTime.milliseconds() else {
            XCTFail("getrusage が取れない環境は想定していない")
            return
        }
        // 実際に CPU を使う(ここが 0 のままだと増分の検証にならない)
        var sink = 0
        for i in 0..<2_000_000 { sink &+= i }
        XCTAssertNotEqual(sink, -1)
        guard let second = ProcessCPUTime.milliseconds() else {
            XCTFail("2回目が取れない")
            return
        }
        XCTAssertGreaterThanOrEqual(second, first, "CPU 時間は減らない")
        XCTAssertGreaterThanOrEqual(ProcessCPUTime.delta(from: first, to: second) ?? -1, 0)
    }

    /// **不明は nil のまま**(0 に丸めない)。片方でも欠ければ増分は言えない
    func testDeltaIsNilWhenEitherEndIsUnknown() {
        XCTAssertNil(ProcessCPUTime.delta(from: nil, to: 10))
        XCTAssertNil(ProcessCPUTime.delta(from: 10, to: nil))
        XCTAssertEqual(ProcessCPUTime.delta(from: 10, to: 25), 15)
    }

    /// 時計が巻き戻って見えても負の増分にしない(0 で止める)
    func testDeltaNeverGoesNegative() {
        XCTAssertEqual(ProcessCPUTime.delta(from: 25, to: 10), 0)
    }

    /// 記録の欄が **timeline まで通っている**こと(欄が落ちると分析そのものができない)
    func testTimelineRecordCarriesTheInstruments() throws {
        let record = TimelineStepRecord(
            index: 1, description: "select \"#x\"", status: "failed", durationMs: 120_000,
            scheduleDelayMs: 119_500, cpuMs: 3)
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(TimelineStepRecord.self, from: data)
        XCTAssertEqual(back.scheduleDelayMs, 119_500)
        XCTAssertEqual(back.cpuMs, 3)
        // 旧レコード(欄なし)は nil で読める = 不明
        let legacy = #"{"index":1,"description":"x","status":"passed"}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(TimelineStepRecord.self, from: legacy)
        XCTAssertNil(old.scheduleDelayMs)
        XCTAssertNil(old.cpuMs)
    }

    /// **記録の経路まで通っていること**(欄を足しても写像を忘れると nil のまま出る)。
    /// TimelineStepRecord を直接組み立てるのではなく ScenarioRecordBuilder を通す
    func testBuilderCarriesTheInstrumentsIntoTheTimeline() {
        var event = ScenarioEvent(kind: "step")
        event.index = 1
        event.description = "select \"#x\""
        event.status = "failed"
        event.durationMs = 120_000
        event.scheduleDelayMs = 119_500
        event.cpuMs = 3
        event.ioBlockedMs = 4
        event.stallMs = 5
        event.poolStallMs = 6
        event.guardMs = 118_000
        event.ocrMs = 1_300
        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", platform: "ios",
                                            title: nil, worker: nil)
        builder.consume(event)
        let record = builder.build(passed: false, timedOut: false, startedAt: Date(),
                                   durationMs: 120_000, packageRoot: nil)
        XCTAssertEqual(record.timeline?.first?.scheduleDelayMs, 119_500)
        XCTAssertEqual(record.timeline?.first?.cpuMs, 3)
        XCTAssertEqual(record.timeline?.first?.ioBlockedMs, 4)
        XCTAssertEqual(record.timeline?.first?.stallMs, 5)
        XCTAssertEqual(record.timeline?.first?.poolStallMs, 6)
        XCTAssertEqual(record.timeline?.first?.guardMs, 118_000)
        XCTAssertEqual(record.timeline?.first?.ocrMs, 1_300)
    }
}

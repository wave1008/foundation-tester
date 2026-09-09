// FTSync.ScheduleDelay の性質。**測っているのは「順番待ち」であって所要ではない** ——
// タスクを作ってから最初の1命令が走るまでで、ここが大きいステップは1命令も実行しないまま
// 壁時計の締め切り(FTSync.commandTimeout)に食われている。

import XCTest
@testable import FTDSL

final class ScheduleDelayInstrumentTests: XCTestCase {

    /// **最初の1回だけ**記録する(再入・再試行で上書きすると、後の周回の待ちに化ける)
    func testRecordsOnlyTheFirstValue() {
        let delay = FTSync.ScheduleDelay()
        delay.record(7)
        delay.record(999)
        XCTAssertEqual(delay.milliseconds, 7)
    }

    /// 記録前は **nil = 不明**(0 に丸めない)
    func testUnrecordedIsUnknownNotZero() {
        XCTAssertNil(FTSync.ScheduleDelay().milliseconds)
    }

    /// run() を通すと必ず値が入る(渡し忘れると永久に nil = 分析ができない)
    func testRunRecordsTheDelay() {
        let delay = FTSync.ScheduleDelay()
        let result = FTSync.run(timeout: 10, scheduleDelay: delay) { 42 }
        XCTAssertEqual(result, 42)
        guard let ms = delay.milliseconds else {
            XCTFail("run(scheduleDelay:) が記録していない")
            return
        }
        XCTAssertGreaterThanOrEqual(ms, 0)
    }
}

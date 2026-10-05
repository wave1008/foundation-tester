// モニターの周回の間隔は開始から開始まで(ApiMonitorCommand.sleepBeforeNextCycle)。
// witness: run 中(配信が止まり静止画の周回だけ)で 1 周 約 7.5 秒 = 処理(状態の確認 1.3 秒 + 確認 2 秒 + 撮影 2 秒)の後に
// interval の 2 秒を丸ごと足していた

import XCTest
@testable import fleetest

final class MonitorCycleCadenceTests: XCTestCase {

    func testSleepsOnlyTheRestOfTheInterval() {
        XCTAssertEqual(ApiMonitorCommand.sleepBeforeNextCycle(interval: 2.0, elapsed: .milliseconds(500)),
                       1.5, accuracy: 0.001)
    }

    /// 処理が interval を超えても、休まず回り続けない
    func testKeepsTheMinimumGapWhenTheCycleRanLong() {
        XCTAssertEqual(ApiMonitorCommand.sleepBeforeNextCycle(interval: 2.0, elapsed: .seconds(5)),
                       ApiMonitorCommand.minimumCycleGap, accuracy: 0.001)
        XCTAssertEqual(ApiMonitorCommand.sleepBeforeNextCycle(interval: 2.0, elapsed: .milliseconds(1800)),
                       0.5, accuracy: 0.001, "残り 0.2 秒より最低の空きが勝つ")
    }

    func testMinimumGapIsPinned() {
        XCTAssertEqual(ApiMonitorCommand.minimumCycleGap, 0.5)
    }

    /// 配線: 撮影は並列の fetchScreenshots を通し、周回の終わりは sleepBeforeNextCycle で待つ
    func testLoopUsesParallelFetchAndCadence() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiMonitorCommand.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("await Self.fetchScreenshots(captureStates"))
        XCTAssertFalse(source.contains("png = try await Self.fetchScreenshot(state:"),
                       "1台ずつ撮る形に戻っている")
        XCTAssertTrue(source.contains("seconds: Self.sleepBeforeNextCycle(interval: interval,"))
    }
}

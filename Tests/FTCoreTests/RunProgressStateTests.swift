// RunProgressState(RunOrchestrator の run 進捗の記帳。docs/design.md §18)の検証。
// 守るもの: ①前回と同じ内容なら書かない(壁時計だけが進む周期で emit させない、の actor 側の砦)
// ②再キュー(laneIdled)は done/failed を増やさない ③scenarioFinished は done を必ず、
// 失敗なら failed も増やす ④finish() は remove を呼ぶ。

import XCTest
@testable import FTCore

final class RunProgressStateTests: XCTestCase {

    private final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var writes: [RunProgressRecord] = []
        private(set) var removeCount = 0
        func recordWrite(_ record: RunProgressRecord) {
            lock.lock(); writes.append(record); lock.unlock()
        }
        func recordRemove() {
            lock.lock(); removeCount += 1; lock.unlock()
        }
    }

    private func makeState(_ journal: Journal, total: Int = 3) -> RunProgressState {
        RunProgressState(pid: 4242, runID: "r1", runGroup: nil, issuer: "alice@air",
                         project: "ec-mobile", profile: "ios-smoke", startedAt: Date(), total: total,
                         write: { journal.recordWrite($0) }, remove: { journal.recordRemove() })
    }

    func testJoiningTheSameLaneWithIdenticalContentDoesNotWriteTwice() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        XCTAssertEqual(journal.writes.count, 1, "内容が変わっていない2回目は書かないはず")
    }

    func testScenarioStartedThenFinishedWritesOnEachRealChange() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.scenarioFinished(laneKey: "UDID-A", passed: true)
        XCTAssertEqual(journal.writes.count, 3)
        XCTAssertEqual(journal.writes.last?.done, 1)
        XCTAssertEqual(journal.writes.last?.failed, 0)
        XCTAssertNil(journal.writes.last?.lanes.first?.scenario, "終了後は待機中(scenario nil)へ戻る")
    }

    func testScenarioFinishedWithFailureIncrementsBothDoneAndFailed() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioFinished(laneKey: "UDID-A", passed: false)
        XCTAssertEqual(journal.writes.last?.done, 1)
        XCTAssertEqual(journal.writes.last?.failed, 1)
    }

    /// 再キュー(結果を捨てて別デバイスへ回す)は**まだ終わっていない** —— done/failed を増やさない
    func testLaneIdledDoesNotCountAsFinished() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.laneIdled(laneKey: "UDID-A")
        XCTAssertEqual(journal.writes.last?.done, 0)
        XCTAssertEqual(journal.writes.last?.failed, 0)
        XCTAssertNil(journal.writes.last?.lanes.first?.scenario)
    }

    func testLaneLeftRemovesTheLaneFromTheSnapshot() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.laneLeft(key: "UDID-A")
        XCTAssertEqual(journal.writes.last?.lanes, [])
    }

    /// total は run 開始時に確定した値のまま —— scenarioFinished を何度呼んでも動かない
    func testTotalNeverChanges() async {
        let journal = Journal()
        let state = makeState(journal, total: 12)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        for _ in 0..<3 {
            await state.scenarioFinished(laneKey: "UDID-A", passed: true)
        }
        XCTAssertEqual(journal.writes.last?.total, 12)
    }

    func testFinishCallsRemove() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.finish()
        XCTAssertEqual(journal.removeCount, 1)
    }
}

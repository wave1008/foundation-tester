// フリート横断の run 進捗(docs/design.md §18)を `api monitor` が拡張へ渡す形に直す
// `ApiMonitorCommand.monitorRuns` の検証。守るもの: ①経過は台帳の ISO8601 をそのまま流さず
// 呼び出し側の `now` で秒に直す(§18.3) ②issuer が nil のときは mine=false
// (不明を自分扱いにしない。HostOccupancy と同じ向き) ③etaSeconds は常に nil(段5は未実装)。

import FTCore
import XCTest

@testable import fleetest

final class ApiMonitorRunProgressTests: XCTestCase {

    private func record(issuer: String? = "alice@air", lanes: [RunProgressLane] = []) -> RunProgressRecord {
        RunProgressRecord(
            pid: 41233, runID: "r1", runGroup: nil, issuer: issuer, project: "ec-mobile",
            profile: "ios-smoke", startedAt: "2026-09-20T10:03:12Z", total: 12, done: 7, failed: 2,
            etaSeconds: 999, lanes: lanes)
    }

    private let now = ISO8601DateFormatter().date(from: "2026-09-20T10:07:33Z")!

    func testElapsedSecondsIsComputedFromTheCallersNow() {
        let out = ApiMonitorCommand.monitorRuns(records: [record()], now: now, myIssuer: "bob@office")
        XCTAssertEqual(out.first?.elapsedSeconds, 261, "10:03:12 → 10:07:33 は 261 秒")
    }

    func testScenarioElapsedSecondsIsComputedPerLaneAndNilWithoutAScenario() {
        let lanes = [
            RunProgressLane(key: "UDID-A", name: "iPhone 17-01", platform: "ios",
                            scenario: "05_検索", scenarioStartedAt: "2026-09-20T10:06:21Z"),
            RunProgressLane(key: "UDID-B", name: "iPhone 17-02", platform: "ios",
                            scenario: nil, scenarioStartedAt: nil),
        ]
        let out = ApiMonitorCommand.monitorRuns(records: [record(lanes: lanes)], now: now, myIssuer: "bob@office")
        XCTAssertEqual(out.first?.lanes.count, 2)
        XCTAssertEqual(out.first?.lanes[0].scenarioElapsedSeconds, 72, "10:06:21 → 10:07:33 は 72 秒")
        XCTAssertNil(out.first?.lanes[1].scenarioElapsedSeconds, "scenario が nil のレーンは経過も nil")
    }

    func testMineIsTrueOnlyWhenIssuerMatchesExactly() {
        let mine = ApiMonitorCommand.monitorRuns(records: [record(issuer: "bob@office")],
                                                 now: now, myIssuer: "bob@office")
        XCTAssertEqual(mine.first?.mine, true)
        let others = ApiMonitorCommand.monitorRuns(records: [record(issuer: "alice@air")],
                                                    now: now, myIssuer: "bob@office")
        XCTAssertEqual(others.first?.mine, false)
    }

    /// **issuer が nil のときは false**(不明を自分扱いにしない)。myIssuer と偶然 nil 同士で
    /// 一致してしまう形を作らない
    func testMineIsFalseWhenIssuerIsNil() {
        let out = ApiMonitorCommand.monitorRuns(records: [record(issuer: nil)], now: now, myIssuer: "bob@office")
        XCTAssertEqual(out.first?.mine, false)
    }

    /// 段5(残り見積もり)は未実装 —— 台帳に値が入っていても常に nil で渡す
    func testEtaSecondsIsAlwaysNilRegardlessOfTheLedgerValue() {
        let out = ApiMonitorCommand.monitorRuns(records: [record()], now: now, myIssuer: "bob@office")
        XCTAssertNil(out.first?.etaSeconds)
    }

    func testResultIsOrderedByPID() {
        let a = RunProgressRecord(pid: 300, runID: nil, runGroup: nil, issuer: nil, project: "p",
                                  profile: nil, startedAt: "2026-09-20T10:00:00Z", total: 1, done: 0,
                                  failed: 0, etaSeconds: nil, lanes: [])
        let b = RunProgressRecord(pid: 100, runID: nil, runGroup: nil, issuer: nil, project: "p",
                                  profile: nil, startedAt: "2026-09-20T10:00:00Z", total: 1, done: 0,
                                  failed: 0, etaSeconds: nil, lanes: [])
        let out = ApiMonitorCommand.monitorRuns(records: [a, b], now: now, myIssuer: "bob@office")
        XCTAssertEqual(out.map(\.pid), [100, 300])
    }

    // MARK: - shouldEmitRuns

    /// **run が 0 本でも最初の1行は出す**。出さないと拡張は「一度も聞いていない = 不明」のままで、
    /// 「空き」を表現できない(モニターの機械の要約が永久に「? 不明」になっていた)
    func testFirstTickEmitsEvenWhenThereAreNoRuns() {
        XCTAssertTrue(ApiMonitorCommand.shouldEmitRuns(current: [], last: nil))
    }

    /// 2周目以降、内容が同じなら出さない(毎周期の再送で拡張を起こさない)
    func testUnchangedRecordsDoNotEmitAgain() {
        XCTAssertFalse(ApiMonitorCommand.shouldEmitRuns(current: [], last: []))
        let record = record()
        XCTAssertFalse(ApiMonitorCommand.shouldEmitRuns(current: [record], last: [record]))
    }

    func testChangedRecordsEmit() {
        let record = record()
        XCTAssertTrue(ApiMonitorCommand.shouldEmitRuns(current: [record], last: []))
        XCTAssertTrue(ApiMonitorCommand.shouldEmitRuns(current: [], last: [record]))
    }
}

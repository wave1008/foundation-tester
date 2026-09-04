// 起動中ランナーの引き取り判定(StartingRunnerVerdict)と ps etime パーサ(PSElapsedTime)の固定。
// 期待値はリテラル(production の定数から導かない)。

import XCTest
@testable import FTBridgeClient

final class StartingRunnerVerdictTests: XCTestCase {

    // MARK: - PSElapsedTime.parse

    func testParsesMinutesSeconds() {
        XCTAssertEqual(PSElapsedTime.parse("00:07"), 7)
    }

    func testParsesHoursMinutesSeconds() {
        // 1*3600 + 46*60 + 13 = 3600 + 2760 + 13 = 6373
        XCTAssertEqual(PSElapsedTime.parse("01:46:13"), 6373)
    }

    func testParsesDaysPrefix() {
        // 3*86400 + 1*3600 + 2*60 + 3 = 259200 + 3600 + 120 + 3 = 262923
        XCTAssertEqual(PSElapsedTime.parse("3-01:02:03"), 262_923)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(PSElapsedTime.parse("   12:34 \n"), 754)
    }

    func testGarbageIsNil() {
        XCTAssertNil(PSElapsedTime.parse(""))
        XCTAssertNil(PSElapsedTime.parse("not-a-time"))
        XCTAssertNil(PSElapsedTime.parse(":::"))
        XCTAssertNil(PSElapsedTime.parse("1:2:3:4"))
    }

    // MARK: - StartingRunnerVerdict.decide

    func testUnknownElapsedWaits() {
        XCTAssertEqual(StartingRunnerVerdict.decide(elapsed: nil, budget: 180), .wait)
    }

    func testJustUnderBudgetWaits() {
        XCTAssertEqual(StartingRunnerVerdict.decide(elapsed: 179, budget: 180), .wait)
    }

    func testExactlyAtBudgetRestarts() {
        XCTAssertEqual(StartingRunnerVerdict.decide(elapsed: 180, budget: 180), .restart)
    }

    func testWellOverBudgetRestarts() {
        XCTAssertEqual(StartingRunnerVerdict.decide(elapsed: 900, budget: 180), .restart)
    }
}

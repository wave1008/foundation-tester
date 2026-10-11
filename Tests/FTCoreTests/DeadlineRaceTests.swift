// DeadlineRace.first: 期限が先なら nil を返し、応答しない処理を**待たない**(FM の死んだ ANE では respond が戻らない)。

import XCTest
@testable import FTCore

final class DeadlineRaceTests: XCTestCase {

    /// **キャンセルにも応じず戻らない処理**を、期限で見切って返す(withTaskGroup だとここで止まる)
    func testAnOperationThatNeverReturnsIsAbandonedAtTheDeadline() async {
        let started = Date()
        let result: Int? = await DeadlineRace.first(seconds: 0.2) {
            await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }   // 決して resume しない
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "戻らない処理を待った")
    }

    func testAFastOperationReturnsItsValue() async {
        let result = await DeadlineRace.first(seconds: 5) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testAThrowingOperationReturnsNil() async {
        struct Boom: Error {}
        let result: Int? = await DeadlineRace.first(seconds: 5) { throw Boom() }
        XCTAssertNil(result)
    }
}

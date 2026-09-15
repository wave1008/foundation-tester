// StartingBridgeAge.isStillStarting: pid ファイルの年齢だけで「起動中ではあり得ない」ことを言う
// 純粋関数。F24 実測(2026-09-15 M1Ultra): 直前2 run で健全だった長寿の xcuitest ブリッジが
// 無応答になったとき、StartingRunnerVerdict.decide の quietFor(起動ログの mtime)は
// 「最近書かれた」と誤読して .wait を返し、waitUntilReady が満額 180 秒を無駄に待ってから
// 建て直した。pid ファイルは起動時に一度だけ書かれるので、その年齢は「起動中の最大寿命」を
// 超え得ない —— 超えていれば待たずに建て直しへ回してよい。

import XCTest
@testable import FTBridgeClient

final class StartingBridgeAgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testJustUnderBudgetIsStillStarting() {
        let modified = now.addingTimeInterval(-179)
        XCTAssertTrue(StartingBridgeAge.isStillStarting(
            pidFileModified: modified, now: now, startupTimeout: 180))
    }

    func testExactlyAtBudgetIsNotStillStarting() {
        // 180 秒ちょうどは「起動に許された時間を使い切った」なので starting ではない
        // (StartingRunnerVerdict.decide の「ちょうど budget と同値は restart」と同じ向き)
        let modified = now.addingTimeInterval(-180)
        XCTAssertFalse(StartingBridgeAge.isStillStarting(
            pidFileModified: modified, now: now, startupTimeout: 180))
    }

    func testJustOverBudgetIsNotStillStarting() {
        let modified = now.addingTimeInterval(-181)
        XCTAssertFalse(StartingBridgeAge.isStillStarting(
            pidFileModified: modified, now: now, startupTimeout: 180))
    }

    func testFreshPidIsStillStarting() {
        XCTAssertTrue(StartingBridgeAge.isStillStarting(
            pidFileModified: now, now: now, startupTimeout: 180))
    }

    func testLongLivedReusedRunnerIsNotStillStarting() {
        // F24 の実測そのもの: 直前2 run ぶん(数分〜数十分)生き続けたランナー
        let modified = now.addingTimeInterval(-1800)
        XCTAssertFalse(StartingBridgeAge.isStillStarting(
            pidFileModified: modified, now: now, startupTimeout: 180))
    }
}

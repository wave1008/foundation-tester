import XCTest
@testable import fleetest

/// パネルの表示切替は抑止を全台 ⇄ 0 台で反転させ、差分が全台になる(63 台で1行 5KB 超)。
/// 名前は上限まで・残りは件数で出すことを固定する
final class MonitorSuppressionLogTests: XCTestCase {
    func testSingleDeviceChangeListsTheName() {
        let line = ApiMonitorCommand.suppressionDeltaLine(ids: ["ios:a", "ios:b"], previous: ["ios:a"])
        XCTAssertEqual(line, "[monitor] Frame suppression: 2 device(s) + 1: ios:b")
    }

    func testUnchangedSet() {
        let line = ApiMonitorCommand.suppressionDeltaLine(ids: ["ios:a"], previous: ["ios:a"])
        XCTAssertEqual(line, "[monitor] Frame suppression: 1 device(s) (unchanged)")
    }

    func testBulkReleaseIsCappedAtEightNames() {
        let all = Set((1...20).map { String(format: "d%02d", $0) })
        let line = ApiMonitorCommand.suppressionDeltaLine(ids: [], previous: all)
        XCTAssertEqual(line, "[monitor] Frame suppression: 0 device(s) - 20: "
                       + "d01, d02, d03, d04, d05, d06, d07, d08, … (12 more)")
    }

    func testExactlyEightNamesHasNoRemainder() {
        let eight = Set((1...8).map { "d\($0)" })
        let line = ApiMonitorCommand.suppressionDeltaLine(ids: eight, previous: [])
        XCTAssertFalse(line.contains("more"), line)
        XCTAssertTrue(line.hasPrefix("[monitor] Frame suppression: 8 device(s) + 8: "), line)
    }

    func testAddedAndRemovedBothShown() {
        let line = ApiMonitorCommand.suppressionDeltaLine(ids: ["x"], previous: ["y"])
        XCTAssertEqual(line, "[monitor] Frame suppression: 1 device(s) + 1: x; - 1: y")
    }
}

import XCTest
@testable import FTCore

final class PollBackoffTests: XCTestCase {

    func testDefaultSequenceIsDeterministic() {
        var backoff = PollBackoff()
        let expectedMs = [100, 200, 400, 800, 1000, 1000, 1000]
        for expected in expectedMs {
            XCTAssertEqual(backoff.nextDelay(), .milliseconds(expected))
        }
    }

    func testClampsAtCap() {
        var backoff = PollBackoff(initialMs: 300, capMs: 500)
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(300))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(500))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(500))
    }

    func testInitialAboveCapClampsImmediately() {
        var backoff = PollBackoff(initialMs: 2000, capMs: 1000)
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(1000))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(1000))
    }

    /// 値型前提の回帰検知(参照型化すると状態共有してしまう)
    func testIndependentInstancesDoNotShareState() {
        var a = PollBackoff()
        _ = a.nextDelay()
        _ = a.nextDelay()
        var b = PollBackoff()
        XCTAssertEqual(b.nextDelay(), .milliseconds(100))
    }
}

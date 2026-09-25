import XCTest
@testable import FTBridgeClient

/// 起動しきれないランナーの掃除の判定(maintainer-notes §51.11)。実プロセスでは「起動予算を超えた・待受を拒否した」を
/// 作れないので、判定そのものを純粋関数で縛る。止めてよいのは4条件が揃ったときだけ
final class StuckRunnerReapDecisionTests: XCTestCase {
    func testReapsOnlyWhenEveryConditionHolds() {
        XCTAssertTrue(StaleLedgerSweep.shouldReapStuckRunner(
            readyMarked: false, connect: .refused, destinationHeld: false, verdict: .restart))
    }

    /// 一度でも ready になったランナーは、今は待受を拒否していても止めない
    func testNeverReapsARunnerThatWasOnceReady() {
        XCTAssertFalse(StaleLedgerSweep.shouldReapStuckRunner(
            readyMarked: true, connect: .refused, destinationHeld: false, verdict: .restart))
    }

    /// connect の時間切れ(busy の可能性)は「待受なし」ではない
    func testConnectTimeoutIsNotTreatedAsNobodyListening() {
        XCTAssertFalse(StaleLedgerSweep.shouldReapStuckRunner(
            readyMarked: false, connect: .unknown, destinationHeld: false, verdict: .restart))
        XCTAssertFalse(StaleLedgerSweep.shouldReapStuckRunner(
            readyMarked: false, connect: .connected, destinationHeld: false, verdict: .restart))
    }

    func testNeverReapsWhenTheDeviceHasARunOrMCPSession() {
        XCTAssertFalse(StaleLedgerSweep.shouldReapStuckRunner(
            readyMarked: false, connect: .refused, destinationHeld: true, verdict: .restart))
    }

    func testWaitsWhileTheStartupBudgetIsNotExhausted() {
        XCTAssertFalse(StaleLedgerSweep.shouldReapStuckRunner(
            readyMarked: false, connect: .refused, destinationHeld: false, verdict: .wait))
    }

    /// 非同期 connect の結末: 時間切れ・SO_ERROR が読めない・拒否以外のエラーは不明
    func testPendingConnectClassification() {
        XCTAssertEqual(BridgeDiscovery.classifyPendingConnect(pollReady: false, soError: nil), .unknown)
        XCTAssertEqual(BridgeDiscovery.classifyPendingConnect(pollReady: true, soError: nil), .unknown)
        XCTAssertEqual(BridgeDiscovery.classifyPendingConnect(pollReady: true, soError: 0), .connected)
        XCTAssertEqual(BridgeDiscovery.classifyPendingConnect(pollReady: true, soError: ECONNREFUSED), .refused)
        XCTAssertEqual(BridgeDiscovery.classifyPendingConnect(pollReady: true, soError: ETIMEDOUT), .unknown)
    }
}

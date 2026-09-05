import XCTest
@testable import FTBridgeClient

/// StaleLedgerSweep.decide: .pid/.inapp/.endpoint/.device の掃除判定(純粋関数)。
/// 実測 2026-09-05: 誰も LISTEN していない .inapp と、対になる .pid が無い .endpoint/.device が
/// 手元に残っていた(BridgeProvisioner.swift の sweepStaleLedgers 冒頭コメント参照)。
final class StaleLedgerSweepTests: XCTestCase {

    private func inputs(hasPid: Bool = false, pidAlive: Bool = false,
                        hasInApp: Bool = false, inappListening: Bool = false,
                        hasEndpoint: Bool = false, hasDevice: Bool = false) -> StaleLedgerSweep.Inputs {
        .init(hasPid: hasPid, pidAlive: pidAlive, hasInApp: hasInApp, inappListening: inappListening,
              hasEndpoint: hasEndpoint, hasDevice: hasDevice)
    }

    /// (a) .inapp あり・LISTEN 無し → 削除
    func testInAppWithoutListenerIsStale() {
        let stale = StaleLedgerSweep.decide(inputs(hasInApp: true, inappListening: false))
        XCTAssertEqual(stale, [.inapp])
    }

    /// (b) .inapp あり・LISTEN あり → 残す
    func testInAppWithListenerIsKept() {
        let stale = StaleLedgerSweep.decide(inputs(hasInApp: true, inappListening: true))
        XCTAssertEqual(stale, [])
    }

    /// (c) .endpoint+.device あり・.pid 無し → 削除
    func testEndpointAndDeviceWithoutPidAreStale() {
        let stale = StaleLedgerSweep.decide(inputs(hasEndpoint: true, hasDevice: true))
        XCTAssertEqual(stale, [.endpoint, .device])
    }

    /// (d) .pid 生存 → 全部残す
    func testAlivePidKeepsEverything() {
        let stale = StaleLedgerSweep.decide(inputs(
            hasPid: true, pidAlive: true, hasInApp: true, inappListening: true,
            hasEndpoint: true, hasDevice: true))
        XCTAssertEqual(stale, [])
    }

    /// (e) .pid 死亡 → .pid と .endpoint/.device を削除
    func testDeadPidRemovesPidAndEndpointAndDevice() {
        let stale = StaleLedgerSweep.decide(inputs(
            hasPid: true, pidAlive: false, hasEndpoint: true, hasDevice: true))
        XCTAssertEqual(stale, [.pid, .endpoint, .device])
    }

    /// 何も無ければ何も消えない(全フラグ false の既定入力)
    func testNothingPresentStaysEmpty() {
        XCTAssertEqual(StaleLedgerSweep.decide(inputs()), [])
    }
}

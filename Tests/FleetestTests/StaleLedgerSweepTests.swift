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

    // MARK: - StaleLedgerSweep.sweepIproxyPidFiles(stateDir:)
    //
    // F27 実測: .fleetest/iproxy-<port>.pid(実機 USB トンネル)は bridge-<port>.* とは別の台帳で、
    // 上の .decide が回る bridge- プレフィックスのループには乗らない。物理デバイスを使わない run を
    // 挟むと、死んだ pid のまま消されず残り続けた。

    private func makeStateDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-stale-iproxy-\(UUID().uuidString)/.fleetest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDeadIproxyPidFileIsRemoved() throws {
        let stateDir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir.deletingLastPathComponent()) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        let url = stateDir.appendingPathComponent("iproxy-8136.pid")
        try String(process.processIdentifier).write(to: url, atomically: true, encoding: .utf8)

        StaleLedgerSweep.sweepIproxyPidFiles(stateDir: stateDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "死んだ iproxy pid ファイルは消えること")
    }

    func testLiveIproxyPidFileIsKept() throws {
        let stateDir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir.deletingLastPathComponent()) }

        let livePid = ProcessInfo.processInfo.processIdentifier
        let url = stateDir.appendingPathComponent("iproxy-8138.pid")
        try String(livePid).write(to: url, atomically: true, encoding: .utf8)

        StaleLedgerSweep.sweepIproxyPidFiles(stateDir: stateDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "生きている iproxy pid ファイルは残すこと")
    }

    func testUnrelatedPidFilesAreUntouched() throws {
        let stateDir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir.deletingLastPathComponent()) }

        // bridge-<port>.pid は別の掃除経路(sweepStalePidFiles)の担当。ここでは触らない
        let bridgePid = stateDir.appendingPathComponent("bridge-8150.pid")
        try "99999999".write(to: bridgePid, atomically: true, encoding: .utf8)

        StaleLedgerSweep.sweepIproxyPidFiles(stateDir: stateDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: bridgePid.path),
                      "bridge-<port>.pid はこのスイープの対象外")
    }
}

// ブリッジを失った USB トンネル(iproxy)だけがポートを握っている形を、供給の入口で掃除する。
// 実地 2026-09-23 の負荷テスト: 画面ロックで実機のランナーが死ぬたびにトンネルが残り、
// 誰も片付けられないまま採番の窓(32 ポート)を食い潰して `--broadcast` が
// `no free port` で全滅した。
//
// **台帳のあるポートには触らない**(起動中のブリッジは `.pid` をトンネルより先に書く)ので、
// 進行中の起動を巻き込まない。ここではその「触らない」側だけを実プロセス抜きで固定する
// (実際に止める枝は PortHolder.stopTunnelHolder = lsof/ps を伴うので、
//  PortHolderClassifyTests の commandIsIproxyForPort が純粋な判定を担う)。

import XCTest
@testable import FTBridgeClient

final class TunnelOnlyPortSweepTests: XCTestCase {

    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    /// `.pid` があるポート(= 起動中/稼働中のランナーが記録済み)は走査対象にしない
    func testPortsWithABridgeLedgerAreLeftAlone() throws {
        let port: UInt16 = 8123
        try "12345".write(to: stateDir.appendingPathComponent("bridge-\(port).pid"),
                          atomically: true, encoding: .utf8)
        var logs: [String] = []
        StaleLedgerSweep.sweepTunnelOnlyPorts(portRange: port...port, stateDir: stateDir,
                                              log: { logs.append($0) })
        XCTAssertTrue(logs.isEmpty, "台帳のあるポートに手を出している: \(logs)")
    }

    /// `.inapp` があるポートも同じ(in-app ブリッジは pid ファイルを持たない)
    func testPortsWithAnInAppLedgerAreLeftAlone() throws {
        let port: UInt16 = 8124
        try "UDID com.example.app digest".write(
            to: InAppBridgeState.url(stateDir: stateDir, port: port),
            atomically: true, encoding: .utf8)
        var logs: [String] = []
        StaleLedgerSweep.sweepTunnelOnlyPorts(portRange: port...port, stateDir: stateDir,
                                              log: { logs.append($0) })
        XCTAssertTrue(logs.isEmpty, "台帳のあるポートに手を出している: \(logs)")
    }

    /// 台帳が無く、誰も待受していないポートは何もせず素通りする(止めるものが無い)。
    /// **採番の窓の外のポートで踏む** —— 窓の中は同じ機械で走っている run / MCP が使うので、
    /// テストが実プロセスに手を出しかねない(並列テストはホストの実体を共有する)
    func testFreePortIsANoOp() {
        var logs: [String] = []
        StaleLedgerSweep.sweepTunnelOnlyPorts(portRange: 59999...59999, stateDir: stateDir,
                                              log: { logs.append($0) })
        XCTAssertTrue(logs.isEmpty)
    }
}

/// 起動しきれないまま生き続けているランナーの掃除。**判定は StartingRunnerVerdict の再利用**で、
/// ここでは「掃除が見る条件」を明示的に踏む(実プロセスを作らずに踏めるのは「台帳が無い」
/// 「pid が死んでいる」側 —— 生きたランナーを止める枝は実地確認 2026-09-23 と
/// StartingRunnerVerdictTests が担う)。
final class StuckStartingRunnerSweepTests: XCTestCase {

    private var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("stuck-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    /// 死んだ pid の台帳は対象外(`isOurRunner` が false。別の掃除が pid ファイルを片付ける)
    func testDeadPidIsNotReapedHere() throws {
        try "999999".write(to: repoRoot.appendingPathComponent(".fleetest/bridge-8199.pid"),
                           atomically: true, encoding: .utf8)
        var logs: [String] = []
        StaleLedgerSweep.sweepStuckStartingRunners(repoRoot: repoRoot, log: { logs.append($0) })
        XCTAssertTrue(logs.isEmpty, "死んだ pid をこの掃除が名乗って消している: \(logs)")
    }

    /// 台帳が1つも無ければ何もしない
    func testNoLedgersIsANoOp() {
        var logs: [String] = []
        StaleLedgerSweep.sweepStuckStartingRunners(repoRoot: repoRoot, log: { logs.append($0) })
        XCTAssertTrue(logs.isEmpty)
    }
}

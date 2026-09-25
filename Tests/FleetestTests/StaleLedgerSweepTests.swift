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

    // MARK: - BridgeProvisioner.sweepStaleLedgers(repoRoot:) の .toolchain 対応
    //
    // .toolchain は StaleLedgerSweep.Ledger に無い独立ファイル(BridgeProvisioner の該当箇所参照)。
    // decide() の等号テストでは拾えないので、実際のディレクトリ走査を通して確かめる。

    private func makeRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-sweep-toolchain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        return root
    }

    /// .pid も .inapp も無い(実機ランナー不在と同じ形)ポートの .toolchain は
    /// .endpoint/.device と一緒に消える
    func testSweepRemovesOrphanToolchainWithoutPidOrInApp() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent(".fleetest")
        let port: UInt16 = 8199
        try "127.0.0.1".write(to: stateDir.appendingPathComponent("bridge-\(port).endpoint"),
                              atomically: true, encoding: .utf8)
        try "udid".write(to: stateDir.appendingPathComponent("bridge-\(port).device"),
                         atomically: true, encoding: .utf8)
        BridgeToolchainLedger.record(stateDir: stateDir, port: port, toolchain: "Xcode 27.0")

        BridgeProvisioner.sweepStaleLedgers(repoRoot: root)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BridgeToolchainLedger.url(stateDir: stateDir, port: port).path),
            "対応する .pid/.inapp が無い .toolchain は消えること(死んだブリッジの指紋を残さない)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stateDir.appendingPathComponent("bridge-\(port).endpoint").path))
    }

    /// 実際に LISTEN している in-app ブリッジの .toolchain は残る(生きている限り消さない ——
    /// 消すと reuse 判定が毎回「控え無し」で建て直しになる)
    /// 生きているポートの `.toolchain` は残すこと。**実ポートを掴まない** —— 並列テストで
    /// ホストの共有資源(ポート)を取り合うと、判定と無関係な理由で赤くなる。生死の入力は
    /// 呼び出し側が測るので、ここは規則そのものを全組み合わせで固める
    func testToolchainIsOrphanOnlyWhenTheBridgeIsGone() {
        // 生きている(xcuitest は .pid / in-app は LISTEN)なら残す
        XCTAssertFalse(StaleLedgerSweep.toolchainIsOrphan(
            hasToolchain: true, hasPid: true, inappListening: false))
        XCTAssertFalse(StaleLedgerSweep.toolchainIsOrphan(
            hasToolchain: true, hasPid: false, inappListening: true))
        XCTAssertFalse(StaleLedgerSweep.toolchainIsOrphan(
            hasToolchain: true, hasPid: true, inappListening: true))
        // どちらの生存の印も無ければ消す(残すと死んだブリッジの指紋が一致し続ける)
        XCTAssertTrue(StaleLedgerSweep.toolchainIsOrphan(
            hasToolchain: true, hasPid: false, inappListening: false))
        // 控えが無ければ何もしない
        XCTAssertFalse(StaleLedgerSweep.toolchainIsOrphan(
            hasToolchain: false, hasPid: false, inappListening: false))
    }

    // MARK: - StaleLedgerSweep.readyIsOrphan(.ready = BridgeReadyLedger の孤児判定)
    //
    // .toolchain と同じ形の判定(そのポートのランナーが生きているかの1点だけ)。
    // sweepStuckStartingRunners が読む「一度でも ready だったか」の印を、死んだポートに
    // 残したままにしない(残すと同じポートに立った別ランナーが誤って「前にも ready だった」と読む)。

    func testReadyIsOrphanOnlyWhenTheBridgeIsGone() {
        XCTAssertFalse(StaleLedgerSweep.readyIsOrphan(
            hasReady: true, hasPid: true, inappListening: false))
        XCTAssertFalse(StaleLedgerSweep.readyIsOrphan(
            hasReady: true, hasPid: false, inappListening: true))
        XCTAssertTrue(StaleLedgerSweep.readyIsOrphan(
            hasReady: true, hasPid: false, inappListening: false))
        XCTAssertFalse(StaleLedgerSweep.readyIsOrphan(
            hasReady: false, hasPid: false, inappListening: false))
    }

    /// 実際の掃除経路(BridgeProvisioner.sweepStaleLedgers)を通した確認。.pid が死んでいれば
    /// 対の .ready も一緒に消える
    func testSweepRemovesOrphanReadyMarkWithoutAPid() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent(".fleetest")
        let port: UInt16 = 8198
        BridgeReadyLedger.mark(stateDir: stateDir, port: port, pid: 4242)
        // .pid も .inapp も無い(実機ランナー不在と同じ形)ことを保証するため endpoint/device と
        // 同じダミー台帳を1つ添える(ports の走査対象に入れる。この2つ自体は今回の主張と無関係)
        try "127.0.0.1".write(to: stateDir.appendingPathComponent("bridge-\(port).endpoint"),
                              atomically: true, encoding: .utf8)

        BridgeProvisioner.sweepStaleLedgers(repoRoot: root)

        XCTAssertFalse(BridgeReadyLedger.exists(stateDir: stateDir, port: port),
                       "対応する .pid が無い .ready は消えること")
    }
}

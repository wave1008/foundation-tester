// iproxy-<port>.pid の台帳リーク: isIproxyRunning は生死・iproxy 判定を確かめるだけで、
// 外れたときに pid ファイル自体を片付けていなかった(BridgeProvisioner.StaleLedgerSweep と
// 同じ「台帳はプロセスの実体で掃除する」規律を iproxy 側にも適用する)。

import FTCore
import XCTest
@testable import FTBridgeClient

final class IproxyPidLedgerTests: XCTestCase {

    private func makeRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-iproxy-pid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        return root
    }

    func testDeadPidIsReportedNotRunningAndFileIsRemoved() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPid = process.processIdentifier

        let url = IOSDeviceTransport.pidURL(hostPort: 8188, repoRoot: root)
        try String(deadPid).write(to: url, atomically: true, encoding: .utf8)

        let running = IOSDeviceTransport.isIproxyRunning(
            hostPort: 8188, deviceUDID: "any-udid", repoRoot: root)

        XCTAssertFalse(running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "死んだ pid の台帳ファイルは片付けること")
    }

    func testLiveNonIproxyPidIsReportedNotRunningAndFileIsRemoved() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // このテストプロセス自身の pid = 生きているが iproxy ではない
        let livePid = ProcessInfo.processInfo.processIdentifier

        let url = IOSDeviceTransport.pidURL(hostPort: 8189, repoRoot: root)
        try String(livePid).write(to: url, atomically: true, encoding: .utf8)

        let running = IOSDeviceTransport.isIproxyRunning(
            hostPort: 8189, deviceUDID: "any-udid", repoRoot: root)

        XCTAssertFalse(running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "pid 再利用で無関係プロセスに化けた台帳ファイルも片付けること")
    }

    // MARK: - isPortHeldByIproxy(hostPort:repoRoot:) — F8: 採番(assignPort/freePort)が実機の
    // USB トンネルを空きと誤認しないための専用チェック。isIproxyRunning と違って UDID を問わない
    // (どの UDID 向けでも同じホストポートは使えないため)。

    func testDeadIproxyPidIsNotHeld() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPid = process.processIdentifier

        let url = IOSDeviceTransport.pidURL(hostPort: 8190, repoRoot: root)
        try String(deadPid).write(to: url, atomically: true, encoding: .utf8)

        XCTAssertFalse(IOSDeviceTransport.isPortHeldByIproxy(hostPort: 8190, repoRoot: root),
                       "死んだ pid は空き(採番除外の対象外)")
    }

    func testLiveNonIproxyPidIsNotHeld() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let livePid = ProcessInfo.processInfo.processIdentifier
        let url = IOSDeviceTransport.pidURL(hostPort: 8191, repoRoot: root)
        try String(livePid).write(to: url, atomically: true, encoding: .utf8)

        XCTAssertFalse(IOSDeviceTransport.isPortHeldByIproxy(hostPort: 8191, repoRoot: root),
                       "生きていても iproxy でなければ空き扱い(pid 再利用ガード)")
    }

    func testMissingPidFileIsNotHeld() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(IOSDeviceTransport.isPortHeldByIproxy(hostPort: 8192, repoRoot: root))
    }
}

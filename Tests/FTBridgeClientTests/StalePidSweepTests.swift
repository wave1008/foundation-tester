// sweepStalePidFiles: TTL 自主終了後に残る pid ファイルの回収
// (残すと assignPort がそのポートを使用中とみなし採番がドリフトする)。

import XCTest
@testable import FTBridgeClient

final class StalePidSweepTests: XCTestCase {

    private func makeRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        return root
    }

    private func writePid(_ content: String, port: Int, repoRoot: URL) throws -> URL {
        let url = repoRoot.appendingPathComponent(".fleetest/bridge-\(port).pid")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRemovesDeadPidFile() throws {
        let root = try makeRepoRoot()
        // pid_max を超える値 = 実在し得ないプロセス
        let dead = try writePid("999999999", port: 8126, repoRoot: root)
        BridgeLauncher.sweepStalePidFiles(repoRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path),
                       "死んだランナーの pid ファイルは掃除される")
    }

    func testRemovesReusedPidFile() throws {
        let root = try makeRepoRoot()
        // 自プロセスの pid = 生きているがランナーではない(PID 再利用のケース)
        let reused = try writePid(String(ProcessInfo.processInfo.processIdentifier),
                                  port: 8127, repoRoot: root)
        BridgeLauncher.sweepStalePidFiles(repoRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reused.path),
                       "ランナー以外に再利用された pid の pid ファイルも掃除される")
    }

    func testRemovesUnparsablePidFile() throws {
        let root = try makeRepoRoot()
        let broken = try writePid("not-a-pid", port: 8128, repoRoot: root)
        BridgeLauncher.sweepStalePidFiles(repoRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path),
                       "読めない pid ファイルも掃除される")
    }

    func testKeepsNonPidFiles() throws {
        let root = try makeRepoRoot()
        let log = root.appendingPathComponent(".fleetest/bridge-8126.log")
        try "log".write(to: log, atomically: true, encoding: .utf8)
        BridgeLauncher.sweepStalePidFiles(repoRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
                      "pid 以外の状態ファイルには触らない")
    }
}

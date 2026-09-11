// BridgeProvisioner.sweepStaleLeases: 死んだ pid の run-*.lease / recording-*.lease の掃除。
// RunLease/RecordingLease の isFresh 判定は pid+mtime で既に安全だが、書き手が `.remove()` を
// 呼べずに落ちる(SIGKILL・クラッシュ)とファイル自体は永久に残る。ここではファイルが実際に
// 消えることを確認する(StalePidSweepTests.swift と同じ構成)。

import XCTest
@testable import FTBridgeClient

final class StaleLeaseSweepTests: XCTestCase {

    private func makeRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        return root
    }

    private func writeLease(_ content: String, name: String, repoRoot: URL) throws -> URL {
        let url = repoRoot.appendingPathComponent(".fleetest/\(name).lease")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRemovesRunLeaseWithDeadPid() throws {
        let root = try makeRepoRoot()
        let dead = try writeLease("999999999", name: "run-TEST-UDID-0000", repoRoot: root)
        BridgeProvisioner.sweepStaleLeases(repoRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path),
                       "死んだ pid の run-lease は掃除される")
    }

    func testRemovesRecordingLeaseWithDeadPid() throws {
        let root = try makeRepoRoot()
        let dead = try writeLease("999999999", name: "recording-emulator-5554", repoRoot: root)
        BridgeProvisioner.sweepStaleLeases(repoRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path),
                       "死んだ pid の recording-lease は掃除される")
    }

    func testRemovesUnparsableLease() throws {
        let root = try makeRepoRoot()
        let broken = try writeLease("not-a-pid", name: "run-TEST-UDID-0001", repoRoot: root)
        BridgeProvisioner.sweepStaleLeases(repoRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path),
                       "読めない pid の lease も掃除される")
    }

    /// 生存判定は pid だけ(mtime では消さない)。古い mtime でも保持者が生きていれば残す
    func testKeepsLeaseWithAlivePidEvenIfMtimeIsOld() throws {
        let root = try makeRepoRoot()
        let alive = try writeLease(String(ProcessInfo.processInfo.processIdentifier),
                                   name: "run-TEST-UDID-0002", repoRoot: root)
        let past = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: alive.path)
        BridgeProvisioner.sweepStaleLeases(repoRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: alive.path),
                      "生きている保持者の lease は mtime に関わらず残す")
    }

    func testKeepsUnrelatedFiles() throws {
        let root = try makeRepoRoot()
        let log = root.appendingPathComponent(".fleetest/bridge-8126.log")
        try "log".write(to: log, atomically: true, encoding: .utf8)
        BridgeProvisioner.sweepStaleLeases(repoRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
                      ".lease 以外の状態ファイルには触らない")
    }
}

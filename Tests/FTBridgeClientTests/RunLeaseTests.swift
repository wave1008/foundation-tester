// RunLease の契約(生存 pid + mtime 鮮度)を検証する。RecordingLeaseTests.swift と同型。
// 実プロセス起動不要: 自プロセスの pid を「生存」、999999 を「非生存」として使う。

import XCTest
@testable import FTBridgeClient
import FTCore

final class RunLeaseTests: XCTestCase {
    let udid = "TEST-UDID-0000"

    func makeStateDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return dir
    }

    func testIsFreshTrueImmediatelyAfterWrite() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        RunLease.write(stateDir: stateDir, key: udid, pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(RunLease.isFresh(stateDir: stateDir, key: udid))
    }

    func testIsFreshFalseWhenPidNotAlive() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try String(999999).write(to: RunLease.leaseURL(stateDir: stateDir, key: udid),
                                 atomically: true, encoding: .utf8)
        XCTAssertFalse(RunLease.isFresh(stateDir: stateDir, key: udid))
    }

    func testIsFreshFalseWhenStale() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        RunLease.write(stateDir: stateDir, key: udid, pid: ProcessInfo.processInfo.processIdentifier)
        let url = RunLease.leaseURL(stateDir: stateDir, key: udid)
        let past = Date().addingTimeInterval(-30)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        XCTAssertFalse(RunLease.isFresh(stateDir: stateDir, key: udid))
    }

    func testIsFreshFalseWhenLeaseFileMissing() {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        XCTAssertFalse(RunLease.isFresh(stateDir: stateDir, key: udid))
    }

    func testAndroidSerialKeyRoundTrips() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let serial = "emulator-5554"

        RunLease.write(stateDir: stateDir, key: serial, pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(RunLease.isFresh(stateDir: stateDir, key: serial))

        RunLease.remove(stateDir: stateDir, key: serial)
        XCTAssertFalse(RunLease.isFresh(stateDir: stateDir, key: serial))
    }

    // RunLeaseGuard は isFresh ではなく holderPID(保持者 pid)を読む。isFresh の3条件
    // (存在+生存+鮮度)を holderPID も同じく守ることを確認する(戻す revert すると
    // pid が取れず 二重使用の拒否メッセージから保持者 pid が消える)
    func testHolderPIDReturnsPIDWhenFresh() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let pid = ProcessInfo.processInfo.processIdentifier

        RunLease.write(stateDir: stateDir, key: udid, pid: pid)
        XCTAssertEqual(RunLease.holderPID(stateDir: stateDir, key: udid), pid)
    }

    func testHolderPIDNilWhenStaleOrDeadOrMissing() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        XCTAssertNil(RunLease.holderPID(stateDir: stateDir, key: udid))

        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try String(999999).write(to: RunLease.leaseURL(stateDir: stateDir, key: udid),
                                 atomically: true, encoding: .utf8)
        XCTAssertNil(RunLease.holderPID(stateDir: stateDir, key: udid))

        RunLease.write(stateDir: stateDir, key: udid, pid: ProcessInfo.processInfo.processIdentifier)
        let past = Date().addingTimeInterval(-30)
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: RunLease.leaseURL(stateDir: stateDir, key: udid).path)
        XCTAssertNil(RunLease.holderPID(stateDir: stateDir, key: udid))
    }
}

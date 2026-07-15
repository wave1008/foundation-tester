// MonitorLease の契約(生存 pid + mtime 鮮度)を検証する。
// 実プロセス起動不要: 自プロセスの pid を「生存」、999999 を「非生存」として使う。

import XCTest
@testable import FTBridgeClient
import FTCore

final class MonitorLeaseTests: XCTestCase {
    let udid = "TEST-UDID-0000"

    func makeStateDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return dir
    }

    func testIsFreshTrueImmediatelyAfterWrite() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        MonitorLease.write(stateDir: stateDir, udid: udid, pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(MonitorLease.isFresh(stateDir: stateDir, udid: udid))
    }

    func testIsFreshFalseWhenPidNotAlive() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try String(999999).write(to: MonitorLease.leaseURL(stateDir: stateDir, udid: udid),
                                 atomically: true, encoding: .utf8)
        XCTAssertFalse(MonitorLease.isFresh(stateDir: stateDir, udid: udid))
    }

    func testIsFreshFalseWhenStale() throws {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        MonitorLease.write(stateDir: stateDir, udid: udid, pid: ProcessInfo.processInfo.processIdentifier)
        let url = MonitorLease.leaseURL(stateDir: stateDir, udid: udid)
        let past = Date().addingTimeInterval(-30)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        XCTAssertFalse(MonitorLease.isFresh(stateDir: stateDir, udid: udid))
    }

    func testIsFreshFalseWhenLeaseFileMissing() {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }

        XCTAssertFalse(MonitorLease.isFresh(stateDir: stateDir, udid: udid))
    }
}

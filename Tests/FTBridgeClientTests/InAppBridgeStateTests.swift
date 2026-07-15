// in-app ブリッジ状態ファイル(.ftester/bridge-<port>.inapp)の書式往復と、
// stopAll/stop がそれを stale 許容で後始末することを検証する。
// simctl は実機がないと成功しない(架空 udid/bundleID で失敗する)ため、
// terminateAndRemove の失敗許容(ファイル削除は必ず起きる)だけを見る。

import XCTest
@testable import FTBridgeClient

final class InAppBridgeStateTests: XCTestCase {
    private var repoRoot: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftbridge-inapp-\(UUID().uuidString)")
        stateDir = repoRoot.appendingPathComponent(".ftester")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    func testWriteReadRoundTrip() throws {
        InAppBridgeState.write(stateDir: stateDir, port: 8210, udid: "UDID-A", bundleID: "com.example.app")
        let path = InAppBridgeState.url(stateDir: stateDir, port: 8210)

        let state = InAppBridgeState.read(at: path)

        XCTAssertEqual(state?.udid, "UDID-A")
        XCTAssertEqual(state?.bundleID, "com.example.app")
    }

    func testReadReturnsNilForMissingOrMalformedFile() throws {
        let missing = InAppBridgeState.url(stateDir: stateDir, port: 8211)
        XCTAssertNil(InAppBridgeState.read(at: missing))

        let malformed = InAppBridgeState.url(stateDir: stateDir, port: 8212)
        try "only-one-field".write(to: malformed, atomically: true, encoding: .utf8)
        XCTAssertNil(InAppBridgeState.read(at: malformed))
    }

    func testTerminateAndRemoveDeletesFileEvenWhenSimctlFails() throws {
        let path = InAppBridgeState.url(stateDir: stateDir, port: 8213)
        try "FAKE-UDID com.example.nonexistent".write(to: path, atomically: true, encoding: .utf8)

        InAppBridgeState.terminateAndRemove(at: path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testStopAllTerminatesAndRemovesStaleInappFiles() throws {
        let path = InAppBridgeState.url(stateDir: stateDir, port: 8214)
        try "FAKE-UDID com.example.nonexistent".write(to: path, atomically: true, encoding: .utf8)

        let stopped = BridgeLauncher.stopAll(repoRoot: repoRoot)

        XCTAssertEqual(stopped, ["8214"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testInstanceStopHandlesInappFileWhenNoPidFile() throws {
        let launcher = BridgeLauncher(repoRoot: repoRoot, port: 8215)
        InAppBridgeState.write(stateDir: stateDir, port: 8215, udid: "FAKE-UDID", bundleID: "com.example.nonexistent")

        XCTAssertNoThrow(try launcher.stop())

        let path = InAppBridgeState.url(stateDir: stateDir, port: 8215)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testInstanceStopThrowsWhenNeitherPidNorInappFileExists() throws {
        let launcher = BridgeLauncher(repoRoot: repoRoot, port: 8216)
        XCTAssertThrowsError(try launcher.stop())
    }
}

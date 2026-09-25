// BridgeReadyLedger の mark/exists/remove ラウンドトリップ(純粋なファイル IO)。

import XCTest
@testable import FTBridgeClient

final class BridgeReadyLedgerTests: XCTestCase {

    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ready-ledger-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    func testAbsentByDefault() {
        XCTAssertFalse(BridgeReadyLedger.exists(stateDir: stateDir, port: 8123))
    }

    func testMarkThenExists() {
        BridgeReadyLedger.mark(stateDir: stateDir, port: 8123, pid: 4242)
        XCTAssertTrue(BridgeReadyLedger.exists(stateDir: stateDir, port: 8123))
    }

    func testMarkDoesNotAffectOtherPorts() {
        BridgeReadyLedger.mark(stateDir: stateDir, port: 8123, pid: 4242)
        XCTAssertFalse(BridgeReadyLedger.exists(stateDir: stateDir, port: 8124))
    }

    func testRemoveClearsTheMark() {
        BridgeReadyLedger.mark(stateDir: stateDir, port: 8123, pid: 4242)
        BridgeReadyLedger.remove(stateDir: stateDir, port: 8123)
        XCTAssertFalse(BridgeReadyLedger.exists(stateDir: stateDir, port: 8123))
    }

    func testRemoveOfAnAbsentMarkIsANoOp() {
        BridgeReadyLedger.remove(stateDir: stateDir, port: 8123)
        XCTAssertFalse(BridgeReadyLedger.exists(stateDir: stateDir, port: 8123))
    }

    /// 同じポートで建て直された次のランナー(別 pid)は「ready だった」と読まない
    func testMarkBelongsToTheRunnerThatBecameReady() {
        BridgeReadyLedger.mark(stateDir: stateDir, port: 8123, pid: 4242)
        XCTAssertTrue(BridgeReadyLedger.isMarked(stateDir: stateDir, port: 8123, pid: 4242))
        XCTAssertFalse(BridgeReadyLedger.isMarked(stateDir: stateDir, port: 8123, pid: 5151))
        XCTAssertFalse(BridgeReadyLedger.isMarked(stateDir: stateDir, port: 8124, pid: 4242))
    }
}

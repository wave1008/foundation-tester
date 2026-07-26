// SupplyLeaseHolder が供給フェーズの run-lease を保持・解放することの検証。
// 読み手(ApiMonitorCommand の inRun 判定)は RunLease.isFresh なので、そちらで確認する。

import XCTest
@testable import FTBridgeClient

final class SupplyLeaseHolderTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftsupplylease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    func testHoldMakesLeaseFreshAndReleaseClearsIt() {
        let holder = SupplyLeaseHolder(stateDir: stateDir)
        XCTAssertFalse(RunLease.isFresh(stateDir: stateDir, key: "UDID-A"))

        holder.hold(keys: ["UDID-A", "emulator-5554"])
        XCTAssertTrue(RunLease.isFresh(stateDir: stateDir, key: "UDID-A"))
        XCTAssertTrue(RunLease.isFresh(stateDir: stateDir, key: "emulator-5554"))

        holder.release()
        XCTAssertFalse(RunLease.isFresh(stateDir: stateDir, key: "UDID-A"))
        XCTAssertFalse(RunLease.isFresh(stateDir: stateDir, key: "emulator-5554"))
    }

    /// iOS 供給が後から合流する経路(Android を先に hold → iOS を追加)で既存キーが消えない
    func testHoldIsAdditive() {
        let holder = SupplyLeaseHolder(stateDir: stateDir)
        holder.hold(keys: ["emulator-5554"])
        holder.hold(keys: ["UDID-A"])
        XCTAssertTrue(RunLease.isFresh(stateDir: stateDir, key: "emulator-5554"))
        XCTAssertTrue(RunLease.isFresh(stateDir: stateDir, key: "UDID-A"))
        holder.release()
    }

    /// 空文字キー(connection に udid/serial が無い非プロファイル経路)は書かない
    func testIgnoresEmptyKeys() {
        let holder = SupplyLeaseHolder(stateDir: stateDir)
        holder.hold(keys: [""])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: RunLease.leaseURL(stateDir: stateDir, key: "").path))
        holder.release()
    }
}

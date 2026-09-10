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

    private func leaseExists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: RunLease.leaseURL(stateDir: stateDir, key: key).path)
    }

    /// 陽性対照: 手放していないキーは、消されてもハートビートが書き戻す(= 下の handOff の検証で
    /// ハートビートが実際に回っていることの確認。回っていなければ handOff の検証は素通しになる)
    func testHeartbeatRewritesAKeyStillHeld() async throws {
        let holder = SupplyLeaseHolder(stateDir: stateDir, heartbeatSeconds: 0.05)
        holder.hold(keys: ["emulator-5554"])
        RunLease.remove(stateDir: stateDir, key: "emulator-5554")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(leaseExists("emulator-5554"))
        holder.release()
    }

    /// orchestrator へ手放したキーは、orchestrator が消した後に書き戻さない
    /// (書き戻すと担当を終えた台が run の最後まで run 中に見え、モニターの配信が明滅する)
    func testHandedOffKeyIsNotRewrittenAfterItsOwnerRemovesIt() async throws {
        let holder = SupplyLeaseHolder(stateDir: stateDir, heartbeatSeconds: 0.05)
        holder.hold(keys: ["emulator-5554", "emulator-5556"])
        holder.handOff(key: "emulator-5554")
        XCTAssertTrue(leaseExists("emulator-5554"), "handOff はファイルを消さない(持ち主が移るだけ)")
        RunLease.remove(stateDir: stateDir, key: "emulator-5554")  // orchestrator の release
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(leaseExists("emulator-5554"), "手放したキーを書き戻した")
        XCTAssertTrue(RunLease.isFresh(stateDir: stateDir, key: "emulator-5556"))
        // release は手放したキーに触れない(orchestrator が書いたものを消さない)
        RunLease.write(stateDir: stateDir, key: "emulator-5554", pid: ProcessInfo.processInfo.processIdentifier)
        holder.release()
        XCTAssertTrue(leaseExists("emulator-5554"))
        XCTAssertFalse(leaseExists("emulator-5556"))
    }

    /// release の後はハートビートが1度も書かない
    func testNothingIsWrittenAfterRelease() async throws {
        let holder = SupplyLeaseHolder(stateDir: stateDir, heartbeatSeconds: 0.02)
        holder.hold(keys: ["UDID-A"])
        try await Task.sleep(nanoseconds: 100_000_000)
        holder.release()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(leaseExists("UDID-A"))
    }

    /// 既定の打ち直し間隔(読み手の失効 15 秒より十分短い)
    func testDefaultHeartbeatIsPinned() {
        XCTAssertEqual(SupplyLeaseHolder.defaultHeartbeatSeconds, 5)
        XCTAssertLessThan(SupplyLeaseHolder.defaultHeartbeatSeconds * 2, RunLease.stalenessSeconds)
    }
}

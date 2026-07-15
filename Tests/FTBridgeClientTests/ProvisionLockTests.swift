// ProvisionLock(provision() のクロスプロセス排他)が、同一ロックファイルへの2つの独立した
// 取得を直列化することを検証する。flock は open file description 単位のため、同一プロセス内の
// 別インスタンス(別 fd)同士でも相互排他が効く=これでクロスプロセス排他の中核を検証できる。

import XCTest
@testable import FTBridgeClient

final class ProvisionLockTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftprovlock-\(UUID().uuidString)")
        // ProvisionLock.init が stateDir を作るため事前作成は不要
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    func testSerializesConcurrentAcquire() async throws {
        let lock1 = try ProvisionLock(stateDir: stateDir)
        let lock2 = try ProvisionLock(stateDir: stateDir)

        await lock1.acquire()
        // lock1 保持中に lock2 を取りに行くタスク。取得できた時刻を返す。
        let secondAcquire = Task { () -> Date in
            await lock2.acquire()
            return Date()
        }
        try await Task.sleep(nanoseconds: 300_000_000)  // lock2 はこの間ブロックされ続けるはず
        let releaseTime = Date()
        lock1.release()
        let acquiredTime = await secondAcquire.value
        lock2.release()

        // lock2 の取得は lock1 の解放後(release より前に取得できていたら排他が効いていない)
        XCTAssertGreaterThanOrEqual(
            acquiredTime.timeIntervalSince(releaseTime), -0.05,
            "lock2 は lock1 の解放後に取得されるべき(flock で直列化)")
    }
}

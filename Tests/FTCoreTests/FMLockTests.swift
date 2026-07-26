// FMLock(FM 呼び出しのホスト単位の直列化)の検証。
// ここが壊れると FM が並列に投げられ、modelmanagerd のモデル積み降ろしが増える。

import XCTest
@testable import FTCore

final class FMLockTests: XCTestCase {

    /// 殺しスイッチが立っているときは排他しないのが正しい挙動なので、排他の検証は飛ばす
    private func requireSerializationEnabled() throws {
        if !FMLock.isEnabled { throw XCTSkip("FT_FM_SERIALIZE=0 では排他しない") }
    }

    override func tearDown() {
        FMLock.release()  // テストが途中で落ちてもロックを残さない
        super.tearDown()
    }

    /// 保持中は同一プロセスの別要求が取れない(flock は同じ fd では素通りするため、
    /// プロセス内の排他が別に要る = この検証が無いと直列化が効かない)
    func testSecondAcquireFailsWhileHeld() async throws {
        try requireSerializationEnabled()
        var acquired = await FMLock.acquire(timeoutSeconds: 1)
        XCTAssertTrue(acquired)
        let second = await FMLock.acquire(timeoutSeconds: 0.3)
        XCTAssertFalse(second, "保持中は取れないはず")
        FMLock.release()
    }

    /// 解放後は取れる
    func testAcquireSucceedsAfterRelease() async throws {
        try requireSerializationEnabled()
        var acquired = await FMLock.acquire(timeoutSeconds: 1)
        XCTAssertTrue(acquired)
        FMLock.release()
        acquired = await FMLock.acquire(timeoutSeconds: 1)
        XCTAssertTrue(acquired)
        FMLock.release()
    }

    /// timeout はおおむね守る(待ち続けてシナリオのタイムアウトを食い潰さない)
    func testAcquireRespectsTimeout() async throws {
        try requireSerializationEnabled()
        var acquired = await FMLock.acquire(timeoutSeconds: 1)
        XCTAssertTrue(acquired)
        let started = Date()
        _ = await FMLock.acquire(timeoutSeconds: 0.5)
        let waited = Date().timeIntervalSince(started)
        XCTAssertLessThan(waited, 2.0, "timeout を大きく超えて待ってはいけない")
        XCTAssertGreaterThan(waited, 0.3, "timeout より極端に早く諦めてもいけない")
        FMLock.release()
    }

    /// 二重 release は無害(defer と早期 return が重なっても壊れない)
    func testDoubleReleaseIsHarmless() async throws {
        try requireSerializationEnabled()
        var acquired = await FMLock.acquire(timeoutSeconds: 1)
        XCTAssertTrue(acquired)
        FMLock.release()
        FMLock.release()
        acquired = await FMLock.acquire(timeoutSeconds: 1)
        XCTAssertTrue(acquired)
        FMLock.release()
    }

    /// 殺しスイッチ(A/B 計測用)。無効時は常に取れる = 素通り
    func testKillSwitchMakesAcquireAlwaysSucceed() async throws {
        guard ProcessInfo.processInfo.environment["FT_FM_SERIALIZE"] == "0" else {
            throw XCTSkip("FT_FM_SERIALIZE=0 のときだけ意味を持つ検証")
        }
        var acquired = await FMLock.acquire(timeoutSeconds: 0.1)
        XCTAssertTrue(acquired)
        acquired = await FMLock.acquire(timeoutSeconds: 0.1)
        XCTAssertTrue(acquired, "無効時は保持中でも素通りする")
    }
}

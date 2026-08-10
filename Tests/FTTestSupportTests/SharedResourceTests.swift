// SharedResource(flock ベースの資源ロック)の契約を固定する。
// 全テストに終了期限を持たせる(実装バグでハングしても swift test 自体は止まらないようにする)。

import XCTest
@testable import FTTestSupport

final class SharedResourceTests: XCTestCase {

    struct Boom: Error {}

    func testBodyExecutesAndReturnsValue() throws {
        let value = try SharedResource.hostCaches.locked { 42 }
        XCTAssertEqual(value, 42)
    }

    /// throw する body でもロックは解放される(解放されていなければ次の取得が
    /// 120 秒のタイムアウトを待つので、素早く成功することで確かめる)
    func testThrowingBodyStillReleasesLock() {
        XCTAssertThrowsError(try SharedResource.hostCaches.locked { throw Boom() })
        let start = Date()
        XCTAssertNoThrow(try SharedResource.hostCaches.locked { })
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "解放されていない疑い(タイムアウト待ちに近い時間がかかった)")
    }

    /// 同じキーを2スレッドから取り、入れ子にならないこと(start,end,start,end)を確認する。
    /// flock は open file description 単位なので、同一プロセスでも fd を分ければ競合する
    /// —— サブプロセスを起こさずに相互排他を検証できる
    func testMutualExclusionAcrossThreads() {
        let resource = SharedResource.iosSimulatorHost
        let eventsLock = NSLock()
        var events: [String] = []
        func record(_ event: String) {
            eventsLock.lock()
            events.append(event)
            eventsLock.unlock()
        }
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            Thread {
                try? resource.locked {
                    record("start")
                    Thread.sleep(forTimeInterval: 0.2)
                    record("end")
                }
                group.leave()
            }.start()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success, "スレッドが時間内に終わらない")
        XCTAssertEqual(events, ["start", "end", "start", "end"], "入れ子になっている(相互排他が効いていない)")
    }

    /// 異なるキー同士は互いを待たない
    func testDifferentKeysDoNotBlockEachOther() throws {
        let a = SharedResource.iosSimulatorHost
        let b = SharedResource.androidEmulatorHost
        let aEntered = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        Thread {
            try? a.locked {
                aEntered.signal()
                Thread.sleep(forTimeInterval: 0.5)
            }
            group.leave()
        }.start()
        XCTAssertEqual(aEntered.wait(timeout: .now() + 5), .success, "キー a に入れない")
        let start = Date()
        try b.locked { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3,
                          "別キーなのに待たされた(a が保持中に b が入れないのは異常)")
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success, "スレッド a が時間内に終わらない")
    }

    /// 同一スレッドでの再入は即座に失敗する(120 秒待たない)。
    /// flock は fd が別なので自分自身とデッドロックする —— ここで先回りして落とす
    func testReentrancyFailsFast() {
        let resource = SharedResource.hostCaches
        let start = Date()
        XCTAssertThrowsError(try resource.locked {
            try resource.locked { }
        })
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "再入検出が遅い(タイムアウト待ちしている疑い)")
    }

    /// async オーバーロードも同じ契約(取得・解放・throw 伝播)を満たす
    func testAsyncOverloadExecutesAndReleases() async throws {
        let value = try await SharedResource.hostCaches.locked { () async throws -> Int in
            try await Task.sleep(nanoseconds: 1_000_000)
            return 7
        }
        XCTAssertEqual(value, 7)
        // 直後に再取得できる = 解放されている
        let start = Date()
        _ = try await SharedResource.hostCaches.locked { () async -> Int in 0 }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "async 側が解放されていない疑い")
    }
}

import XCTest

@testable import FTDSL

/// DSL スレッドと async 側の橋渡し(FTSync)。**タイムアウトで諦めた op を放置しないこと**が要点で、
/// 放置すると諦めたはずの tap/snapshot が後続ステップの最中にブリッジへ着弾する
/// (記録に残らないので「原因不明の一発ずれ」になる)。
final class FTSyncTests: XCTestCase {

    private final class Flag: @unchecked Sendable {
        var wasCancelled = false
    }

    /// タイムアウトしたら op を cancel する。cancel されなければ op は 5 秒走り切るので、
    /// 「2 秒以内に op が終わり、かつ終了時点で isCancelled」で検出できる
    func testTimeoutCancelsTheOrphanedOperation() {
        let flag = Flag()
        let opFinished = DispatchSemaphore(value: 0)

        let result: Int? = FTSync.run(timeout: 0.2) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            flag.wasCancelled = Task.isCancelled
            opFinished.signal()
            return 1
        }

        XCTAssertNil(result, "タイムアウトしたのに値を返している")
        XCTAssertEqual(opFinished.wait(timeout: .now() + 2.0), .success,
                       "タイムアウト後も op が走り続けている(cancel していない)")
        XCTAssertTrue(flag.wasCancelled, "op に cancel が届いていない")
    }

    /// 期限内に終わる通常経路は値をそのまま返し、cancel しない(正常系を巻き添えにしない)
    func testCompletedOperationReturnsValueAndIsNotCancelled() {
        let flag = Flag()
        let result: Int? = FTSync.run(timeout: 5) {
            flag.wasCancelled = Task.isCancelled
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertFalse(flag.wasCancelled, "期限内に終わった op を cancel している")
    }

    /// throwing 版は run に委譲するので同じ扱い(タイムアウトで nil・op は cancel)
    func testRunThrowingTimesOutAndCancels() {
        let flag = Flag()
        let opFinished = DispatchSemaphore(value: 0)

        let result: Result<Int, Error>? = FTSync.runThrowing(timeout: 0.2) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            flag.wasCancelled = Task.isCancelled
            opFinished.signal()
            return 1
        }

        XCTAssertNil(result)
        XCTAssertEqual(opFinished.wait(timeout: .now() + 2.0), .success,
                       "タイムアウト後も op が走り続けている(cancel していない)")
        XCTAssertTrue(flag.wasCancelled, "op に cancel が届いていない")
    }

    /// throw する op は Result.failure として返る(cancel の追加でこの経路を壊さない)
    func testRunThrowingSurfacesThrownError() {
        struct Boom: Error {}
        let result: Result<Int, Error>? = FTSync.runThrowing(timeout: 5) { throw Boom() }
        guard case .failure(let error)? = result else {
            return XCTFail("throw が failure として返っていない: \(String(describing: result))")
        }
        XCTAssertTrue(error is Boom)
    }
}

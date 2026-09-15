import FTCore
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

/// `DeadlineExclusion` に積まれた時間(OCR 暖機待ち等)を締め切りから差し引く。
/// **延長できるのは実際に差し引かれた分だけ**(打ち切りの意味は変えない)
final class FTSyncDeadlineExclusionTests: XCTestCase {

    /// timeout(0.2s)より長い差し引き区間(0.6s)を op が持てば、打ち切られずに区間の終わりまで待つ
    func testExtendsTheWaitByWhatWasExcluded() {
        let clock = ContinuousClock()
        let start = clock.now
        let result: Int? = FTSync.run(timeout: 0.2) {
            let token = DeadlineExclusion.begin(cap: .seconds(2))
            try? await Task.sleep(for: .milliseconds(600))
            DeadlineExclusion.end(token)
            return 1
        }
        let elapsed = clock.now - start
        XCTAssertEqual(result, 1, "差し引き区間があるのに打ち切られている")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(550), "差し引き区間の終わりを待たずに返っている(所要 \(elapsed))")
        XCTAssertLessThan(elapsed, .seconds(2), "差し引き分を超えて延ばしている(所要 \(elapsed))")
    }

    /// 差し引きが無ければ、同じ 0.6 秒の op でも既定どおり timeout(0.2s)で打ち切る
    func testWithoutExclusionTheOriginalTimeoutStillCutsOff() {
        let clock = ContinuousClock()
        let start = clock.now
        let opFinished = DispatchSemaphore(value: 0)
        let result: Int? = FTSync.run(timeout: 0.2) {
            try? await Task.sleep(for: .milliseconds(600))
            opFinished.signal()
            return 1
        }
        let elapsed = clock.now - start
        XCTAssertNil(result, "差し引きが無いのに打ち切られていない")
        XCTAssertLessThan(elapsed, .milliseconds(500), "0.2 秒の timeout なのに待ちすぎている(所要 \(elapsed))")
        _ = opFinished.wait(timeout: .now() + 2.0)  // 後始末(諦めた op を回収してから次のテストへ)
    }
}

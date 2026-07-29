import XCTest

@testable import FTCore

/// RunOrchestrator.withDeadline の満期スリーパー参照(DeadlineTaskBox)。
/// **代入前に cancel が来る順序**が本番で実在する(op が即座に勝つと opTask 側の cancel が
/// 生成側の代入を追い越す。ThreadSanitizer で実測)。取りこぼすとスリーパーが seconds 秒
/// 居座り、この箱を置いた目的が消えるので、両方の順序を固定する。
final class DeadlineTaskBoxTests: XCTestCase {

    private func makeSleeper() -> Task<Void, Never> {
        Task { try? await Task.sleep(nanoseconds: 30_000_000_000) }
    }

    /// hold → cancel(素直な順序)
    func testCancelAfterHoldCancelsTheTask() {
        let box = DeadlineTaskBox()
        let sleeper = makeSleeper()
        box.hold(sleeper)
        box.cancel()
        XCTAssertTrue(sleeper.isCancelled)
    }

    /// cancel → hold(op が代入を追い越した順序)。**旧実装が取りこぼしていたのはこちら**
    func testCancelBeforeHoldStillCancelsTheTask() {
        let box = DeadlineTaskBox()
        box.cancel()
        let sleeper = makeSleeper()
        box.hold(sleeper)
        XCTAssertTrue(sleeper.isCancelled,
                      "代入前に来た cancel を取りこぼしている(満期スリーパーが居座る)")
    }

    /// cancel が来ていなければ hold しただけで cancel してはいけない
    /// (満期を待つ通常経路を潰さないことの固定)
    func testHoldAloneDoesNotCancel() {
        let box = DeadlineTaskBox()
        let sleeper = makeSleeper()
        box.hold(sleeper)
        XCTAssertFalse(sleeper.isCancelled)
        sleeper.cancel()
    }

    /// hold と cancel が**別スレッドで同時**に走っても、両方完了後は必ず cancel されている。
    /// 排他が壊れていれば取りこぼし・クラッシュとして出る(ThreadSanitizer 下でも回す)
    func testConcurrentHoldAndCancelAlwaysCancels() {
        for iteration in 0..<200 {
            let box = DeadlineTaskBox()
            let sleeper = makeSleeper()
            let cancelDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                box.cancel()
                cancelDone.signal()
            }
            box.hold(sleeper)
            XCTAssertEqual(cancelDone.wait(timeout: .now() + 5), .success,
                           "cancel が返らない(デッドロック): iteration \(iteration)")
            XCTAssertTrue(sleeper.isCancelled, "同時実行で cancel を取りこぼした: iteration \(iteration)")
        }
    }
}

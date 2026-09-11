// 中断が来たら、取り消す口の無い仕事(iOS の遅延参加 = シミュレータの起動・ブリッジのビルド)を
// 待たずに抜ける(RunOrchestrator の awaitUnlessInterrupted)。待つと Ctrl-C が数分効かず、
// 2回目の Ctrl-C が後始末を飛ばして即終了する。

import XCTest
@testable import FTCore

final class AwaitUnlessInterruptedTests: XCTestCase {

    func testReturnsTheFallbackAsSoonAsAnInterruptArrives() async {
        let flag = RunInterruptFlag()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await flag.request()
        }
        let start = Date()
        let value = await awaitUnlessInterrupted({
            try? await Task.sleep(for: .seconds(30))
            return 1
        }, interrupted: flag, fallback: 0)
        XCTAssertEqual(value, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "must not wait for the work")
    }

    func testReturnsTheWorkWhenItFinishesFirst() async {
        let flag = RunInterruptFlag()
        let value = await awaitUnlessInterrupted({ 7 }, interrupted: flag, fallback: 0)
        XCTAssertEqual(value, 7)
        // 待ち手を片付けている(後から来た中断で二度 resume しない = クラッシュしない)
        await flag.request()
    }

    /// 既に中断済みなら仕事の結果を待たない
    func testAlreadyInterruptedReturnsTheFallback() async {
        let flag = RunInterruptFlag()
        await flag.request()
        let value = await awaitUnlessInterrupted({
            try? await Task.sleep(for: .seconds(30))
            return 1
        }, interrupted: flag, fallback: 0)
        XCTAssertEqual(value, 0)
    }
}

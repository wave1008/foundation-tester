// FMBreaker(FM が死んだら呼ぶのをやめるサーキットブレーカ)の検証。
// FM は累積 20〜30 回で死に、以後は再起動まで回復しない(docs/verification.md)。
// ここが壊れると、死んだ FM を呼び続けて 1 回あたり 0.2〜4 秒を捨て続ける。

import XCTest
@testable import FTCore

final class FMBreakerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FMBreaker.reset()
    }

    override func tearDown() {
        FMBreaker.reset()
        super.tearDown()
    }

    /// 単発の失敗では落ちない(一過性の失敗でガードを殺さない)
    func testSingleFailureDoesNotTrip() {
        FMBreaker.recordFailure()
        XCTAssertFalse(FMBreaker.isOpen)
    }

    /// threshold 回の連続失敗で落ちる
    func testTripsAfterConsecutiveFailures() {
        for _ in 0..<FMBreaker.threshold { FMBreaker.recordFailure() }
        XCTAssertTrue(FMBreaker.isOpen, "連続 \(FMBreaker.threshold) 回で落ちるはず")
    }

    /// 途中で成功したら連続カウンタは戻る(散発的な失敗の積み上げで落とさない)
    func testSuccessResetsConsecutiveCount() {
        FMBreaker.recordFailure()
        FMBreaker.recordFailure()
        FMBreaker.recordSuccess()
        FMBreaker.recordFailure()
        FMBreaker.recordFailure()
        XCTAssertFalse(FMBreaker.isOpen, "間に成功が挟まれば連続ではない")
    }

    /// 落ちた後に成功したら復帰する(half-open で試した 1 回が通ったケース)
    func testSuccessClosesTrippedBreaker() {
        for _ in 0..<FMBreaker.threshold { FMBreaker.recordFailure() }
        XCTAssertTrue(FMBreaker.isOpen)
        FMBreaker.recordSuccess()
        XCTAssertFalse(FMBreaker.isOpen, "成功したら復帰するはず")
    }

    /// **ホスト単位**であること(状態がファイルに載る)。ワーカーはプロセスが別なので、
    /// プロセス内カウンタだけだと 14 ワーカー分の無駄打ちが残る
    func testTrippedStateIsHostWide() {
        for _ in 0..<FMBreaker.threshold { FMBreaker.recordFailure() }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let state = base.appendingPathComponent("ftester/fm-breaker.state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path),
                      "別プロセスから見えるようファイルに落とす")
    }

    /// ゲートはブレーカが落ちていれば FM を呼ばせない
    func testGateRefusesWhileOpen() async {
        for _ in 0..<FMBreaker.threshold { FMBreaker.recordFailure() }
        let entered = await FMGate.enter()
        XCTAssertFalse(entered, "落ちている間は入場させない")
        if entered { FMGate.leave() }
    }

    /// 落ちていなければゲートは通る(ロックも取れる)
    func testGateAllowsWhileClosed() async {
        let entered = await FMGate.enter()
        XCTAssertTrue(entered)
        FMGate.leave()
    }
}

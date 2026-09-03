// FMBreaker(FM が死んだら呼ぶのをやめるサーキットブレーカ)の検証。
// FM は累積 20〜30 回で死に、以後は再起動まで回復しない(docs/verification.md)。
// ここが壊れると、死んだ FM を呼び続けて 1 回あたり 0.2〜4 秒を捨て続ける。

import XCTest
@testable import FTCore

final class FMBreakerTests: XCTestCase {

    /// **状態ファイルをプロセスごとに隔離する**。既定のパスはホスト単位の共有ファイルで、
    /// production ではそれが正しい(ワーカーのプロセスを跨いで落ちた事実を伝える)。
    /// ここを差し替えないと `swift test --parallel` で他プロセスの `reset()` に消され、
    /// トリップの判定が競合して落ちる(2026-08-10 実測。直列では通るので気づけなかった)
    private var stateDir: URL!

    override func setUp() {
        super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-breaker-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        FMBreaker.stateURLForTesting = stateDir.appendingPathComponent("fm-breaker.state")
        FMBreaker.reset()
    }

    override func tearDown() {
        FMBreaker.reset()
        FMBreaker.stateURLForTesting = nil
        FMBreaker.bootTimeForTesting = nil
        try? FileManager.default.removeItem(at: stateDir)
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
    /// 落ちた事実は**メモリでなくファイル**に落ちる(別プロセスから見えることが要件)。
    /// 実在を見るのは差し替え済みのパス —— 既定のパスを直接見ると、並列実行で他プロセスの
    /// `reset()` と競合する。「どこに置くか」は下の I/O 抜きのテストが受け持つ
    func testTrippedStateIsWrittenToAFile() {
        for _ in 0..<FMBreaker.threshold { FMBreaker.recordFailure() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: FMBreaker.stateURLForTesting!.path),
                      "別プロセスから見えるようファイルに落とす")
    }

    /// 既定の置き場はホスト単位で1つ(ワーカーのプロセスを跨いで共有する要件)。
    /// **書かずに形だけ**確かめる = 並列実行でも競合しない
    func testDefaultStateURLIsHostWide() {
        let url = FMBreaker.defaultStateURL
        XCTAssertEqual(url.lastPathComponent, "fm-breaker.state")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "fleetest")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        XCTAssertTrue(url.path.hasPrefix(caches.path), url.path)
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

    /// トリップの後にマシンが再起動していたら、そのトリップは前回起動セッションの記録なので無効
    /// (状態ファイルは .cachesDirectory で再起動を生き延びるため)。状態ファイルも消える
    func testTripDoesNotSurviveReboot() {
        for _ in 0..<FMBreaker.threshold { FMBreaker.recordFailure() }
        XCTAssertTrue(FMBreaker.isOpen)
        let past = Date().addingTimeInterval(-3600)
        try? FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: FMBreaker.stateURLForTesting!.path)
        FMBreaker.bootTimeForTesting = past.addingTimeInterval(600)
        XCTAssertFalse(FMBreaker.isOpen, "トリップより後に再起動していれば無効")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FMBreaker.stateURLForTesting!.path),
                       "前回起動セッションの状態ファイルは消す")
    }

    /// 再起動していなければ通常の cooldown 判定のまま(対照)
    func testTripSurvivesWithoutReboot() {
        for _ in 0..<FMBreaker.threshold { FMBreaker.recordFailure() }
        FMBreaker.bootTimeForTesting = Date().addingTimeInterval(-3600)
        XCTAssertTrue(FMBreaker.isOpen, "再起動していなければトリップは有効なまま")
    }
}

// FMLivenessProbe が台帳(FMLiveness)へ書く判定: **単発の失敗で死と書かない**(FMLiveness ④)。
// 実呼び出しを伴う probeOnce は単体では回せないので、台帳へ書く状態を決める `ledgerState`
// (経路ごとのプロセス内カウンタ)を直接叩く。閾値は引数のリテラルで与える(production の定数を
// 期待値に使うと、定数を変える変異が素通りする)。既定が FMBreaker.threshold であることだけは
// 共有の事実として別に見る。
//
// この test target は FTTestSupport に依存しないので台帳(ファイル)は触らない ——
// 台帳への実書き込みは FTCoreTests/FMLivenessTests(FMHealth 経由の同型)が守る。

import XCTest
import FTCore
@testable import FTFoundationModels

final class FMLivenessProbeThresholdTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FMLivenessProbe.resetConsecutiveFailuresForTesting()
    }

    override func tearDown() {
        FMLivenessProbe.resetConsecutiveFailuresForTesting()
        super.tearDown()
    }

    /// 1回・2回の失敗では書かない(nil)。3回目で死
    func testDeadOnlyAfterConsecutiveFailuresReachTheThreshold() {
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3),
                     "単発の失敗で台帳に書かない")
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3))
        XCTAssertEqual(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3), .dead)
        XCTAssertEqual(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3), .dead,
                       "閾値を超えた後も失敗が続く限り死のまま")
    }

    /// 成功は数え直す。**最後を失敗で終える**(成功で終えると数え直しを消す変異が素通りする)
    func testSuccessResetsTheStreak() {
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3))
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3))
        XCTAssertEqual(FMLivenessProbe.ledgerState(afterProbe: .text, failed: false, threshold: 3), .alive,
                       "成功は常に書く(生)")
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3),
                     "失敗の総数は3だが連続していない")
    }

    /// 経路は独立に数える(text の死が vision へ、vision の成功が text へ漏れない)
    func testPathsAreCountedSeparately() {
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3))
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .vision, failed: true, threshold: 3))
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3))
        XCTAssertEqual(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3), .dead)
        XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .vision, failed: true, threshold: 3),
                     "text が死んでも vision の連続失敗は 2 → まだ書かない")
        XCTAssertEqual(FMLivenessProbe.ledgerState(afterProbe: .vision, failed: false, threshold: 3), .alive)
        XCTAssertEqual(FMLivenessProbe.ledgerState(afterProbe: .text, failed: true, threshold: 3), .dead,
                       "vision の成功は text の連続失敗を戻さない")
    }

    /// 既定の閾値は FMBreaker.threshold を共有する(「連続何回で死か」を2つ持たない)
    func testDefaultThresholdIsSharedWithTheBreaker() {
        for _ in 1..<FMBreaker.threshold {
            XCTAssertNil(FMLivenessProbe.ledgerState(afterProbe: .vision, failed: true))
        }
        XCTAssertEqual(FMLivenessProbe.ledgerState(afterProbe: .vision, failed: true), .dead)
    }

    /// settle の返り値は**この回の観測**(台帳に書かない回でも dead を返す = doctor の exit 1 を保つ)
    func testSettleReturnsThisCallsObservationEvenWhenNothingIsWritten() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let verdict = FMLivenessProbe.settle(path: .text, error: "boom", ms: 12, now: now)
        XCTAssertEqual(verdict, FMLiveness.Verdict(state: .dead, checkedAt: 1_000_000, source: .probe,
                                                   error: "boom", ms: 12))
        let ok = FMLivenessProbe.settle(path: .text, error: nil, ms: 7, now: now)
        XCTAssertEqual(ok, FMLiveness.Verdict(state: .alive, checkedAt: 1_000_000, source: .probe, ms: 7))
    }

    /// probeOnce が台帳へ直接 dead を書く形へ戻っていない(ソース走査。実呼び出しは単体で回せない)
    func testProbeOnceWritesTheLedgerOnlyThroughSettle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTFoundationModels/FMLivenessProbe.swift"), encoding: .utf8)
        XCTAssertFalse(code.contains("state: .dead, source: .probe"),
                       "probeOnce が閾値を通さず dead を書いている")
        XCTAssertEqual(code.components(separatedBy: "FMLiveness.record(path: path, state: state, source: .probe").count - 1, 1,
                       "台帳への書き込みは settle の1箇所だけ")
        XCTAssertEqual(code.components(separatedBy: "return settle(path: path").count - 1, 2,
                       "成功・失敗の両方が settle を通る")
    }
}

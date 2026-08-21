// 「FM の実呼び出しが全滅したまま走った」の判定を固定する(2026-08-20)。
//
// FM が死んでいると occlusion-guard(`exist` の既定 requireVisible)・自己修復・`screenLooksLike` は
// **黙って素通り**する契約なので、**結果には現れない**。run のまとめに出さないと、赤を見るたびに
// 「自分の変更か FM か」を人が HEAD 対照で切り分ける羽目になる(2026-08-20 に何度も払った)。
//
// **合否は変えない**: FM と無関係な失敗を隠す方が危険なので、数えるだけ。

import XCTest
@testable import FTCore

final class FMUnavailableSummaryTests: XCTestCase {

    private func usage(calls: Int, failures: Int) -> FMUsageRecord {
        FMUsageRecord(calls: calls, failures: failures, totalMs: 0, p50Ms: 0, maxMs: 0, byKind: [:])
    }

    /// 全滅(呼んだ回数 = 失敗した回数)だけを「利用不可」と数える
    func testCountsOnlyWhenEveryCallFailed() {
        XCTAssertTrue(RunSummary.fmUnavailable(usage(calls: 2, failures: 2)))
        XCTAssertFalse(RunSummary.fmUnavailable(usage(calls: 3, failures: 1)),
                       "一部失敗は『利用不可』ではない(守りは効いている呼び出しがある)")
    }

    /// **呼んでいないだけの run を巻き込まない**。FM を使わないシナリオは山ほどあり、
    /// そこで警告を出すと「FM 障害」の意味が薄れて誰も読まなくなる
    func testStaysSilentWhenFMWasNeverCalled() {
        XCTAssertFalse(RunSummary.fmUnavailable(usage(calls: 0, failures: 0)))
        XCTAssertFalse(RunSummary.fmUnavailable(nil))
    }

    /// summary は既定 0(FM の話が無い run のまとめに余計な行を出さない)
    func testSummaryDefaultsToZero() {
        XCTAssertEqual(RunSummary(total: 3, failed: 0).fmUnavailableScenarios, 0)
        XCTAssertEqual(RunSummary(total: 3, failed: 1, fmUnavailableScenarios: 2)
            .fmUnavailableScenarios, 2)
    }
}

// **デバイス基盤の一過性エラーを「テストの失敗」と数えない**判定を固定する。
//
// `kAXErrorAPIDisabled` は XCUITest の a11y 基盤が一時的に応答しない状態で、
// ブリッジ供給直後・アプリ入れ替え直後に**同時刻クラスタ**で出て再実行で必ず消える
// (2026-08-05/06 に 8 件・6 件を手で「環境」と判定していた)。
//
// **判定を広げると本物の失敗を skipped に隠す**ので、印は「ドライバが返した基盤側のエラー」
// だけに限る。アサーション失敗の文言(element not found 等)を足してはいけない。

import XCTest
@testable import FTCore

final class EnvironmentFaultTests: XCTestCase {

    /// 実際に観測した失敗文言(ドライバの 500)で当たること
    func testMatchesTheObservedAccessibilityFault() {
        let observed = "The driver returned an error (500): Error Domain="
            + "com.apple.dt.xctest.automation-support.error Code=8"
            + " \"Error getting main window kAXErrorAPIDisabled\""
        XCTAssertTrue(EnvironmentFault.matches(observed))
    }

    /// **アサーション失敗は環境ではない**。ここが true になると、本物の失敗が
    /// 振り直され最終的に skipped として記録される(赤が消える = 最悪の壊れ方)
    func testDoesNotMatchOrdinaryTestFailures() {
        for detail in ["element not found after 8 scroll(s): id=row_40",
                       "text does not equal: expected \"a\", actual \"b\"",
                       "cannot resolve the locator: #missing",
                       "The driver returned an error (500): something else entirely"] {
            XCTAssertFalse(EnvironmentFault.matches(detail), "環境と誤判定した: \(detail)")
        }
        XCTAssertFalse(EnvironmentFault.matches(nil))
    }

    /// **優先順位**: 凍結 > 環境 > 合否。凍結はワーカーごと使えないので先に決まる
    func testFrozenWinsOverEverything() {
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: true, environmentFault: true),
                       .frozen)
        XCTAssertEqual(ScenarioRunner.outcome(passed: true, frozen: true, environmentFault: false),
                       .frozen)
    }

    /// **合格は環境エラーで上書きしない**。途中のステップが環境エラーでも、
    /// 最終的に通ったならテストとしては合格(振り直す理由がない)
    func testPassedIsNotDowngradedByATransientFault() {
        XCTAssertEqual(ScenarioRunner.outcome(passed: true, frozen: false, environmentFault: true),
                       .passed)
    }

    /// 失敗かつ環境エラーのときだけ振り直しの対象になる
    func testFailureWithTheMarkerBecomesAnEnvironmentFault() {
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: false, environmentFault: true),
                       .environmentFault)
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: false, environmentFault: false),
                       .failed)
    }
}

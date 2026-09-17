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
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: true, environmentFault: true,
                                              driverUnreachable: true),
                       .frozen)
        XCTAssertEqual(ScenarioRunner.outcome(passed: true, frozen: true, environmentFault: false,
                                              driverUnreachable: false),
                       .frozen)
    }

    /// **合格は環境エラー/ドライバ不達で上書きしない**。途中のステップがそれらでも、
    /// 最終的に通ったならテストとしては合格(振り直す理由がない)
    func testPassedIsNotDowngradedByATransientFault() {
        XCTAssertEqual(ScenarioRunner.outcome(passed: true, frozen: false, environmentFault: true,
                                              driverUnreachable: false),
                       .passed)
        XCTAssertEqual(ScenarioRunner.outcome(passed: true, frozen: false, environmentFault: false,
                                              driverUnreachable: true),
                       .passed)
    }

    /// 失敗かつ環境エラーのときだけ振り直しの対象になる
    func testFailureWithTheMarkerBecomesAnEnvironmentFault() {
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: false, environmentFault: true,
                                              driverUnreachable: false),
                       .environmentFault)
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: false, environmentFault: false,
                                              driverUnreachable: false),
                       .failed)
    }

    /// **driverUnreachable は environmentFault より下位の優先度**(両方 true でも environmentFault
    /// が勝つ)が、単独では .driverUnreachable になる(CLAUDE.md: failureKind は DriverError の
    /// case で仕分ける。ここは失敗ステップの failureKind から立てたフラグを写すだけの純粋関数)
    func testDriverUnreachableMarkerBecomesItsOwnOutcome() {
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: false, environmentFault: false,
                                              driverUnreachable: true),
                       .driverUnreachable)
        XCTAssertEqual(ScenarioRunner.outcome(passed: false, frozen: false, environmentFault: true,
                                              driverUnreachable: true),
                       .environmentFault)
    }

    /// **ドライバ不達は OS を問わず振り直す**(2026-09-18 に揃えた)。iOS がここへ来るのは
    /// 事後プローブ(bridgeUnreachable)がブリッジの生存を確かめた後だけなので、
    /// 「台は生きている」という前提は両 OS で同じ。死んでいれば呼び出し側が離脱経路へ回す
    func testDriverUnreachableRequeuesWithoutRetiring() {
        XCTAssertTrue(ScenarioRunner.requeuesWithoutRetiring(outcome: .driverUnreachable))
    }

    /// refused で即「死亡」と言ってよいのはループバックの宛先だけ
    func testRefusalIsConclusiveOnlyForLoopback() {
        for host in [nil, "127.0.0.1", "localhost", "::1"] {
            XCTAssertTrue(BridgeProbeOutcome.refusalIsConclusive(host: host), "\(String(describing: host))")
        }
        for host in ["192.168.20.7", "10.0.0.5", "fe80::1", "iphone.local"] {
            XCTAssertFalse(BridgeProbeOutcome.refusalIsConclusive(host: host), host)
        }
    }

    /// environmentFault は既存どおり振り直し対象(この規律を壊していないことの固定)
    func testEnvironmentFaultRequeuesWithoutRetiring() {
        XCTAssertTrue(ScenarioRunner.requeuesWithoutRetiring(outcome: .environmentFault))
    }

    /// passed/failed/frozen は振り直し対象にならない(この関数が触ってよいのは
    /// environmentFault と driverUnreachable の2ケースだけ)
    func testOtherOutcomesNeverRequeueWithoutRetiring() {
        for outcome in [ScenarioOutcome.passed, .failed, .frozen] {
            XCTAssertFalse(ScenarioRunner.requeuesWithoutRetiring(outcome: outcome))
        }
    }
}

/// ブリッジ不達で振り直す台の扱い(`ScenarioRunner.unreachableLaneAction`)。
/// **振り直しはブレーカの数え上げを飛ばさない** —— 飛ばすと、張り直せない台が離脱せずに残り、
/// 後続シナリオの再キュー枠を焼き潰す(2026-09-16 のレビュー指摘)
final class UnreachableLaneActionTests: XCTestCase {

    func testKeepRequeues() {
        XCTAssertEqual(ScenarioRunner.unreachableLaneAction(verdict: .keep), .requeue)
    }

    func testHeldRequeues() {
        // 他のレーンが1本も通っていない streak = 台ではなく run の問題なので離脱させない
        XCTAssertEqual(ScenarioRunner.unreachableLaneAction(verdict: .held(consecutive: 3, announce: true)),
                       .requeue)
    }

    func testTripRetiresInsteadOfRequeueing() {
        XCTAssertEqual(ScenarioRunner.unreachableLaneAction(verdict: .trip(consecutive: 4)),
                       .retire(reason: "4 consecutive worker failures"))
    }
}

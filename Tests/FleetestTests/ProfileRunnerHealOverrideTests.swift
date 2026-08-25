// CLI の --heal / --no-heal → ProfileRunner.run(healOverride:) の写像。
// **nil と false は別物**(nil = プロファイルの値をそのまま使う / false = 明示 OFF)で、
// ここを潰すと「プロファイルが heal: true のとき CLI から切れない」に戻る
// (2026-08-12 まで --no-heal が無く、`healOverride == false` の分岐は到達不能だった)。

import XCTest
@testable import fleetest

final class ProfileRunnerHealOverrideTests: XCTestCase {

    func testNoFlagsLeavesTheProfileValueUntouched() {
        XCTAssertNil(ProfileRunner.healOverride(heal: false, noHeal: false),
                     "指定なしは nil = プロファイルの heal をそのまま使う")
    }

    func testHealForcesOn() {
        XCTAssertEqual(ProfileRunner.healOverride(heal: true, noHeal: false), true)
    }

    /// **これが 2026-08-12 まで作れなかった値**(--no-heal が無く、false は到達不能だった)
    func testNoHealForcesOff() {
        XCTAssertEqual(ProfileRunner.healOverride(heal: false, noHeal: true), false)
    }

    /// 両立指定は RunScenarios.validate() が弾くのでここには来ないが、
    /// 万一通っても「有効化が勝つ」= 黙って heal を切らない側に倒す
    func testBothFlagsPrefersOn() {
        XCTAssertEqual(ProfileRunner.healOverride(heal: true, noHeal: true), true)
    }
}

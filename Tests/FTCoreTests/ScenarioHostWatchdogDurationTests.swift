// `ScenarioHost.watchdogDuration`: scenarioTimeout の負値・巨大値でも
// UInt64(negative) / 乗算 overflow の trap を起こさないことを保証する純粋関数。
// 入口検証(RunProfileSetOverride/api validate-profile/ApiRunCommand.validate)を回避しても、
// この関数自体が安全側に倒れることを確認する。

import XCTest
@testable import FTCore

final class ScenarioHostWatchdogDurationTests: XCTestCase {

    func testPositiveValuePassesThrough() {
        XCTAssertEqual(ScenarioHost.watchdogDuration(seconds: 90), .seconds(90))
    }

    func testZeroStaysZero() {
        XCTAssertEqual(ScenarioHost.watchdogDuration(seconds: 0), .seconds(0))
    }

    /// 旧実装は `UInt64(watchdogSeconds)` で trap していた(scenarioTimeout=-5 相当)
    func testNegativeValueClampsToZeroInsteadOfTrapping() {
        XCTAssertEqual(ScenarioHost.watchdogDuration(seconds: -5), .seconds(0))
        XCTAssertEqual(ScenarioHost.watchdogDuration(seconds: Int.min), .seconds(0))
    }

    /// 旧実装は `UInt64(watchdogSeconds) * 1_000_000_000` で桁あふれ trap していた
    /// (Int.max 秒 相当の巨大値)。Duration.seconds は乗算しないのでここでは起きない
    func testHugeValueDoesNotOverflow() {
        XCTAssertEqual(ScenarioHost.watchdogDuration(seconds: Int.max), .seconds(Int.max))
    }
}

// 保持容量の既定値を**リテラルで固定する**。差し替え口(RetentionPolicy(…) に値を渡す形)
// だけで検証していると production の既定を1度も通らず、既定を変える変更が緑のまま通る
// (FMLockTests.testDefaultConcurrencyIsPinned と同じ砦)。

import XCTest
@testable import FTCore

final class RetentionPolicyTests: XCTestCase {

    func testDefaultsArePinned() {
        XCTAssertEqual(RetentionPolicy.defaultDeviceCapturesMaxBytes, 21_474_836_480)  // 20 GiB
        XCTAssertEqual(RetentionPolicy.defaultRecordingsMaxBytes, 107_374_182_400)     // 100 GiB
        XCTAssertEqual(RetentionPolicy.defaultReportsMaxBytes, 1_048_576_000)          // 1000 MiB
        XCTAssertEqual(RetentionPolicy.defaultLogsMaxBytes, 524_288_000)               // 500 MiB
        XCTAssertTrue(RetentionPolicy.defaultSweepAfterRun)
    }

    /// 未設定(全欄 nil)のとき、実効値が既定と1バイトも違わない
    func testUnsetPolicyFallsBackToTheDefaults() {
        let policy = RetentionPolicy()
        XCTAssertEqual(policy.effectiveDeviceCapturesMaxBytes, 21_474_836_480)
        XCTAssertEqual(policy.effectiveRecordingsMaxBytes, 107_374_182_400)
        XCTAssertEqual(policy.effectiveReportsMaxBytes, 1_048_576_000)
        XCTAssertEqual(policy.effectiveLogsMaxBytes, 524_288_000)
        XCTAssertTrue(policy.effectiveSweepAfterRun)
        XCTAssertEqual(RetentionPolicy.defaults, policy.resolved)
    }

    /// **0 は「保持しない」という有効な指定**。既定へ倒してはいけない
    func testZeroMeansKeepNothingAndIsNotReplacedByTheDefault() {
        let policy = RetentionPolicy(deviceCapturesMaxBytes: 0, recordingsMaxBytes: 0,
                                     reportsMaxBytes: 0, logsMaxBytes: 0, sweepAfterRun: false)
        XCTAssertEqual(policy.effectiveDeviceCapturesMaxBytes, 0)
        XCTAssertEqual(policy.effectiveRecordingsMaxBytes, 0)
        XCTAssertEqual(policy.effectiveReportsMaxBytes, 0)
        XCTAssertEqual(policy.effectiveLogsMaxBytes, 0)
        XCTAssertFalse(policy.effectiveSweepAfterRun)
    }

    /// 負だけが無効(既定へ倒す)
    func testNegativeValuesFallBackToTheDefaults() {
        let policy = RetentionPolicy(deviceCapturesMaxBytes: -1, recordingsMaxBytes: -1024,
                                     reportsMaxBytes: -1, logsMaxBytes: -1)
        XCTAssertEqual(policy.effectiveDeviceCapturesMaxBytes, 21_474_836_480)
        XCTAssertEqual(policy.effectiveRecordingsMaxBytes, 107_374_182_400)
        XCTAssertEqual(policy.effectiveReportsMaxBytes, 1_048_576_000)
        XCTAssertEqual(policy.effectiveLogsMaxBytes, 524_288_000)
    }

    func testIsEmptyOnlyWhenEveryFieldIsUnset() {
        XCTAssertTrue(RetentionPolicy().isEmpty)
        XCTAssertFalse(RetentionPolicy(logsMaxBytes: 0).isEmpty)
        XCTAssertFalse(RetentionPolicy(sweepAfterRun: true).isEmpty)
    }

    /// LocalConfig の欄として往復する(既存の設定ファイルを壊さない = 欄が無くても読める)
    func testLocalConfigRoundTripAndBackwardCompatibility() throws {
        let config = LocalConfig(retention: RetentionPolicy(logsMaxBytes: 123, sweepAfterRun: false))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LocalConfig.self, from: data)
        XCTAssertEqual(decoded.retention?.logsMaxBytes, 123)
        XCTAssertEqual(decoded.retention?.sweepAfterRun, false)
        XCTAssertNil(decoded.retention?.recordingsMaxBytes)

        let old = try JSONDecoder().decode(
            LocalConfig.self, from: Data(#"{"defaultProject":"E2E-iOS"}"#.utf8))
        XCTAssertNil(old.retention)
    }
}

/// 発動の線(上限の 90%)。**期待値はリテラル**(production の定数から導くと、90 を別の値へ
/// 変えても緑のまま通る)
final class RetentionSweepLineTests: XCTestCase {

    func testTheLineIsNinetyPercentOfTheLimit() {
        XCTAssertEqual(RetentionPolicy.sweepTriggerPercent, 90)
        XCTAssertEqual(RetentionPolicy.sweepLine(forCap: 100), 90)
        XCTAssertEqual(RetentionPolicy.sweepLine(forCap: 21_474_836_480), 19_327_352_832) // 20 GiB → 18 GiB
        XCTAssertEqual(RetentionPolicy.sweepLine(forCap: 1_048_576_000), 943_718_400)     // 1000 MiB → 900 MiB
    }

    /// 端数は切り捨て(線の手前で止まる側 = 上限を越えない側へ倒す)
    func testTheLineRoundsDown() {
        XCTAssertEqual(RetentionPolicy.sweepLine(forCap: 15), 13)   // 13.5
        XCTAssertEqual(RetentionPolicy.sweepLine(forCap: 199), 179) // 179.1
    }

    /// 0(保持しない)と負は線 0。巨大な上限でも桁あふれしない
    func testZeroNegativeAndHugeLimits() {
        XCTAssertEqual(RetentionPolicy.sweepLine(forCap: 0), 0)
        XCTAssertEqual(RetentionPolicy.sweepLine(forCap: -5), 0)
        XCTAssertEqual(RetentionPolicy.sweepLine(forCap: Int64.max), 8_301_034_833_169_298_226)
    }
}

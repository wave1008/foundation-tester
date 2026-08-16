// ブリッジ供給の**部分失敗**をどう扱うかの規則。
//
// 2026-08-11 のフル E2E の実害: 10台中8台のブリッジが ready だったのに、残り2台が期限切れに
// なった時点で iOS ワーカーが丸ごと throw で失われ、**Flutter/RN の 51 本が1本も走らなかった**。
// 健全な8台は待機したままだった。凍結機を外して残りで走る(BlankWorkerTriage)のと同じ思想へ
// 揃え、**1台でも供給できたら続行**・**全滅のときだけ throw** にした。

import XCTest
@testable import FTBridgeClient

private struct ProbeError: Error, LocalizedError {
    let label: String
    var errorDescription: String? { label }
}

final class ProvisionOutcomeTests: XCTestCase {

    private func outcome(_ name: String, _ value: String?) -> (name: String, result: Result<String, Error>) {
        (name, value.map { Result<String, Error>.success($0) } ?? .failure(ProbeError(label: "\(name) failed"))
        )
    }

    func testAllSucceededReturnsEveryDevice() throws {
        let resolved = try BridgeProvisioner.resolveOutcomes(
            [outcome("d1", "a"), outcome("d2", "b")])
        XCTAssertEqual(resolved.devices, ["a", "b"])
        XCTAssertTrue(resolved.failures.isEmpty)
    }

    /// **本丸**: 一部が落ちても、残った機で走れること
    func testPartialFailureKeepsTheHealthyDevices() throws {
        let resolved = try BridgeProvisioner.resolveOutcomes(
            [outcome("d1", "a"), outcome("d2", nil), outcome("d3", "c")])
        XCTAssertEqual(resolved.devices, ["a", "c"], "健全な機を道連れにしてはいけない")
        XCTAssertEqual(resolved.failures.map(\.name), ["d2"])
    }

    /// 実害と同じ比率(10台中2台失敗)で、8台が残ること
    func testEightOfTenSurviveTwoFailures() throws {
        let outcomes = (1...10).map { index -> (name: String, result: Result<String, Error>) in
            outcome("d\(index)", index == 6 || index == 7 ? nil : "v\(index)")
        }
        let resolved = try BridgeProvisioner.resolveOutcomes(outcomes)
        XCTAssertEqual(resolved.devices.count, 8)
        XCTAssertEqual(resolved.failures.count, 2)
    }

    /// 全滅のときは投げる(呼び出し側が run の失敗として扱えるように)
    func testAllFailedThrowsTheFirstError() {
        XCTAssertThrowsError(
            try BridgeProvisioner.resolveOutcomes([outcome("d1", nil), outcome("d2", nil)])
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.label, "d1 failed", "デバイス順で最初のエラーを投げる")
        }
    }

    /// 供給対象が無いのは失敗ではない(iOS を含まないプロファイル)
    func testEmptyInputIsNotAFailure() throws {
        let resolved = try BridgeProvisioner.resolveOutcomes([(name: String, result: Result<String, Error>)]())
        XCTAssertTrue(resolved.devices.isEmpty)
        XCTAssertTrue(resolved.failures.isEmpty)
    }

    /// 並び順は入力(デバイス指定順)を保つ。レーン割り当ての再現性がここに乗る
    func testOrderIsPreserved() throws {
        let resolved = try BridgeProvisioner.resolveOutcomes(
            [outcome("d3", "c"), outcome("d1", "a"), outcome("d2", "b")])
        XCTAssertEqual(resolved.devices, ["c", "a", "b"])
    }
}

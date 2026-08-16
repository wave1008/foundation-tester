// FleetOutcome.resolve の集約規則。BridgeProvisioner.resolveOutcomes / ProfileWorkerFactory.
// buildAndroidWorkers の両方がここへ転送するので、規則そのものはここ1箇所で固定する。

import XCTest
@testable import FTCore

private struct ProbeError: Error, LocalizedError {
    let label: String
    var errorDescription: String? { label }
}

final class FleetOutcomeTests: XCTestCase {

    private func outcome(_ name: String, _ value: String?) -> (name: String, result: Result<String, Error>) {
        (name, value.map { Result<String, Error>.success($0) } ?? .failure(ProbeError(label: "\(name) failed")))
    }

    func testAllSucceededReturnsEveryDevice() throws {
        let resolved = try FleetOutcome.resolve([outcome("d1", "a"), outcome("d2", "b")])
        XCTAssertEqual(resolved.devices, ["a", "b"])
        XCTAssertTrue(resolved.failures.isEmpty)
    }

    /// **本丸**: 一部が落ちても、残った機で走れること
    func testPartialFailureKeepsTheHealthyDevices() throws {
        let resolved = try FleetOutcome.resolve(
            [outcome("d1", "a"), outcome("d2", nil), outcome("d3", "c")])
        XCTAssertEqual(resolved.devices, ["a", "c"], "健全な機を道連れにしてはいけない")
        XCTAssertEqual(resolved.failures.map(\.name), ["d2"])
    }

    /// 実害と同じ比率(8台中2台失敗)で、6台が残ること(2026-08-16 の Android の実害と同じ形)
    func testSixOfEightSurviveTwoFailures() throws {
        let outcomes = (1...8).map { index -> (name: String, result: Result<String, Error>) in
            outcome("d\(index)", index == 2 || index == 8 ? nil : "v\(index)")
        }
        let resolved = try FleetOutcome.resolve(outcomes)
        XCTAssertEqual(resolved.devices.count, 6)
        XCTAssertEqual(resolved.failures.count, 2)
    }

    /// 全滅のときは投げる(呼び出し側が run の失敗として扱えるように)
    func testAllFailedThrowsTheFirstError() {
        XCTAssertThrowsError(
            try FleetOutcome.resolve([outcome("d1", nil), outcome("d2", nil)])
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.label, "d1 failed", "デバイス順で最初のエラーを投げる")
        }
    }

    /// 供給対象が無いのは失敗ではない
    func testEmptyInputIsNotAFailure() throws {
        let resolved = try FleetOutcome.resolve([(name: String, result: Result<String, Error>)]())
        XCTAssertTrue(resolved.devices.isEmpty)
        XCTAssertTrue(resolved.failures.isEmpty)
    }

    /// 並び順は入力順を保つ
    func testOrderIsPreserved() throws {
        let resolved = try FleetOutcome.resolve(
            [outcome("d3", "c"), outcome("d1", "a"), outcome("d2", "b")])
        XCTAssertEqual(resolved.devices, ["c", "a", "b"])
    }
}

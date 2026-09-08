import XCTest
@testable import FTCore

/// [SlowSnapshotBudget] 期限切れ後の追加 snapshot をゲートする純粋関数と、その陽性対照の注入口。
final class SlowSnapshotBudgetTests: XCTestCase {

    // MARK: - mayRetake

    /// 外枠を持たない呼び出し元(MCP 等)は極端な値でも常に許可 = 従来どおり
    func testNilCommandTimeoutAlwaysAllows() {
        XCTAssertTrue(SlowSnapshotBudget.mayRetake(stepElapsedMs: 999_999, lastSnapshotMs: 999_999,
                                                    commandTimeoutMs: nil))
    }

    /// 通常時(明らかに収まる)は許可 = 通る側の挙動は変わらないことの固定
    func testComfortablyWithinBudgetAllows() {
        XCTAssertTrue(SlowSnapshotBudget.mayRetake(stepElapsedMs: 5_000, lastSnapshotMs: 50,
                                                    commandTimeoutMs: 120_000))
    }

    /// 明らかに収まらない(90s 経過 + 45s の次の1枚 = 135s > 120s)ときは止める
    func testClearlyOverBudgetDenies() {
        XCTAssertFalse(SlowSnapshotBudget.mayRetake(stepElapsedMs: 90_000, lastSnapshotMs: 45_000,
                                                     commandTimeoutMs: 120_000))
    }

    /// 境界(ちょうど一致)は false —— `<` であって `<=` ではない契約を固定する
    func testExactBoundaryDenies() {
        XCTAssertFalse(SlowSnapshotBudget.mayRetake(stepElapsedMs: 100_000, lastSnapshotMs: 20_000,
                                                     commandTimeoutMs: 120_000))
    }

    // MARK: - SlowSnapshotInjection.delay

    func testDelayIsNilWhenUnset() {
        XCTAssertNil(SlowSnapshotInjection.delay(environment: [:]))
    }

    func testDelayParsesMilliseconds() {
        XCTAssertEqual(SlowSnapshotInjection.delay(environment: ["FT_FAKE_SNAPSHOT_DELAY_MS": "2000"]),
                       .milliseconds(2000))
    }

    func testDelayIsNilForZero() {
        XCTAssertNil(SlowSnapshotInjection.delay(environment: ["FT_FAKE_SNAPSHOT_DELAY_MS": "0"]))
    }

    func testDelayIsNilForNegative() {
        XCTAssertNil(SlowSnapshotInjection.delay(environment: ["FT_FAKE_SNAPSHOT_DELAY_MS": "-5"]))
    }

    func testDelayIsNilForNonNumeric() {
        XCTAssertNil(SlowSnapshotInjection.delay(environment: ["FT_FAKE_SNAPSHOT_DELAY_MS": "abc"]))
    }
}

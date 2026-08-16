// LaneGate.missing の集合差分規則(パフォーマンステストモードの判定はここへ転送するだけ)。

import XCTest
@testable import FTCore

final class LaneGateTests: XCTestCase {

    func testNoneMissingWhenEveryExpectedDeviceIsPresent() {
        let missing = LaneGate.missing(expected: ["a", "b"], actual: ["a", "b"])
        XCTAssertTrue(missing.isEmpty)
    }

    /// **本丸**: 一部欠けたら、欠けたものだけを名指しで返す(expected の順序を保つ)。
    /// 比較を反転する変異(`!actualSet.contains` → `actualSet.contains`)が入ると、
    /// このテストは missing=["b"] の代わりに missing=["a","c"] を返し落ちる
    func testPartiallyMissingReturnsOnlyTheMissingNamesInExpectedOrder() {
        let missing = LaneGate.missing(expected: ["a", "b", "c"], actual: ["c", "a"])
        XCTAssertEqual(missing, ["b"])
    }

    func testAllMissingWhenActualIsEmpty() {
        let missing = LaneGate.missing(expected: ["a", "b"], actual: [])
        XCTAssertEqual(missing, ["a", "b"])
    }

    func testEmptyExpectedIsNeverMissing() {
        let missing = LaneGate.missing(expected: [], actual: ["a", "b"])
        XCTAssertTrue(missing.isEmpty)
    }

    /// actual に expected 外の名前が混ざっていても影響しない(欠落だけを見る)
    func testExtraActualNamesDoNotAffectTheResult() {
        let missing = LaneGate.missing(expected: ["a"], actual: ["a", "z"])
        XCTAssertTrue(missing.isEmpty)
    }
}

// 型違いの対処文は来た値の種類で言い分ける(負荷テスト: 数値の 1.5 や範囲外の整数に「引用符を外せ」と言っていた)

import XCTest
@testable import FTCore

final class ArgumentTypeRemedyTests: XCTestCase {

    func testNumberExpected() {
        XCTAssertEqual(ArgumentBounds.typeMismatchRemedy(value: "5", expectsNumber: true),
                       "pass a JSON number, not a quoted string")
        XCTAssertEqual(ArgumentBounds.typeMismatchRemedy(value: NSNumber(value: 1.5), expectsNumber: true),
                       "pass a whole number within range")
        XCTAssertEqual(ArgumentBounds.typeMismatchRemedy(value: NSNumber(value: true), expectsNumber: true),
                       "pass a JSON number, not true/false")
        XCTAssertEqual(ArgumentBounds.typeMismatchRemedy(value: [Any](), expectsNumber: true),
                       "pass a JSON number")
    }

    func testStringExpected() {
        XCTAssertEqual(ArgumentBounds.typeMismatchRemedy(value: NSNumber(value: 5), expectsNumber: false),
                       "pass a JSON string, not a number")
        XCTAssertEqual(ArgumentBounds.typeMismatchRemedy(value: NSNumber(value: false), expectsNumber: false),
                       "pass a JSON string, not true/false")
        XCTAssertEqual(ArgumentBounds.typeMismatchRemedy(value: NSNull(), expectsNumber: false),
                       "pass a JSON string")
    }
}

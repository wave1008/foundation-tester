// AndroidDriver.checkedInt32(_:field:) — 座標を Int32 へ畳む最後の砦(drag/press(x:y:))。
// 呼び手側の座標は `.unbounded`(FTCore.ArgumentBounds)なので、桁外れの値(1e308 等)が
// 無検査でここまで届く。`Int32(value.rounded())` はその範囲では trap するので、
// checkedInt32 は必ず DriverError を投げる側で守る(maintainer-notes §51.1)。

import XCTest
import FTCore
@testable import FTAndroid

final class AndroidDriverCheckedInt32Tests: XCTestCase {

    private func status(_ error: Error) -> Int? {
        guard case DriverError.badResponse(let status, _) = error else { return nil }
        return status
    }

    func testInRangeValueRoundsAndConverts() throws {
        XCTAssertEqual(try AndroidDriver.checkedInt32(540.0, field: "x"), 540)
        XCTAssertEqual(try AndroidDriver.checkedInt32(540.4, field: "x"), 540)
        XCTAssertEqual(try AndroidDriver.checkedInt32(540.6, field: "x"), 541)
        XCTAssertEqual(try AndroidDriver.checkedInt32(-10.0, field: "y"), -10)
    }

    /// maintainer-notes §51.1 の実地値そのもの。**trap せず throw する**ことがこのテストの本体
    /// (直す前は `Int32(1e308.rounded())` がここでテストプロセスごと落ちていた)
    func testWildlyOutOfRangeFiniteValueThrowsInsteadOfTrapping() {
        XCTAssertThrowsError(try AndroidDriver.checkedInt32(1e308, field: "fromX")) {
            XCTAssertEqual(status($0), 422)
        }
    }

    func testJustBeyondInt32MaxThrows() {
        let beyond = Double(Int32.max) + 1
        XCTAssertThrowsError(try AndroidDriver.checkedInt32(beyond, field: "toX")) {
            XCTAssertEqual(status($0), 422)
        }
    }

    func testInt32MaxItselfConverts() throws {
        XCTAssertEqual(try AndroidDriver.checkedInt32(Double(Int32.max), field: "x"), Int32.max)
    }

    func testNonFiniteValuesThrow() {
        for value: Double in [.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try AndroidDriver.checkedInt32(value, field: "y")) {
                XCTAssertEqual(status($0), 422)
            }
        }
    }

    /// 断り文は座標欄の名前を含む(呼び手が fromX/fromY/toX/toY/x/y のどれで断られたか分かる)
    func testErrorBodyNamesTheField() {
        XCTAssertThrowsError(try AndroidDriver.checkedInt32(1e308, field: "fromY")) { error in
            guard case DriverError.badResponse(_, let body) = error else {
                return XCTFail("badResponse ではない: \(error)")
            }
            XCTAssertTrue(body.contains("fromY"), body)
        }
    }
}

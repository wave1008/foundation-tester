// doctor が出す FM の履歴の件数を固定する(既定値はリテラルで固定する規約)
import XCTest
@testable import fleetest

final class DoctorFMHistoryTests: XCTestCase {
    func testDoctorShowsTheLastEightHistoryEvents() {
        XCTAssertEqual(Doctor.fmHistoryLines, 8)
    }
}

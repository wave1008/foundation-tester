// `fleetest doctor` の macOS/Xcode SDK 版・ビルド表示(情報だけ・赤にも警告にもしない)。
// ベータ判定とフォーマットは純粋関数なので実機に依らず固定できる。

import XCTest
@testable import fleetest

final class DoctorOSToolchainTests: XCTestCase {

    func testBetaBuildEndsWithLowercaseLetter() {
        XCTAssertTrue(Doctor.isBetaBuild("26B5091g"))
        XCTAssertFalse(Doctor.isBetaBuild("26A425"))
    }

    func testLineReportsBothVersionsWithoutJudging() {
        let line = Doctor.osToolchainLine(
            macOSVersion: "27.2", macOSBuild: "26B5091g",
            sdkVersion: "27.0", sdkBuild: "26A425")
        XCTAssertEqual(line, "macOS 27.2 (26B5091g, beta) / Xcode macOS SDK 27.0 (26A425)")
    }

    func testUnreadableFieldsFallBackToUnknownIndependently() {
        let line = Doctor.osToolchainLine(
            macOSVersion: nil, macOSBuild: "26B5091g",
            sdkVersion: "27.0", sdkBuild: nil)
        XCTAssertEqual(line, "macOS unknown (26B5091g, beta) / Xcode macOS SDK 27.0 (unknown)")
    }

    /// "unknown" というフォールバック文字列自体を末尾の小文字判定に食わせて誤ってベータ扱いしない
    func testUnknownBuildIsNotMisreadAsBeta() {
        let line = Doctor.osToolchainLine(
            macOSVersion: "27.2", macOSBuild: nil,
            sdkVersion: "27.0", sdkBuild: nil)
        XCTAssertEqual(line, "macOS 27.2 (unknown) / Xcode macOS SDK 27.0 (unknown)")
    }
}

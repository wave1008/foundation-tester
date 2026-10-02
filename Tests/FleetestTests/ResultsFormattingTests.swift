// インストール済みデバイス一覧の OS 表記の正規化(`results` の表の整形は FTCoreTests/ResultsRenderingTests へ移した)。

import XCTest
@testable import fleetest

final class ResultsFormattingTests: XCTestCase {

    // MARK: - normalizeOS

    func testNormalizeOSStripsIOSPrefix() {
        XCTAssertEqual(ApiInstalledDevicesCommand.normalizeOS("iOS 27.0"), "27.0")
    }

    func testNormalizeOSLeavesOtherFormsUntouched() {
        XCTAssertEqual(ApiInstalledDevicesCommand.normalizeOS("27.0"), "27.0")
        XCTAssertEqual(ApiInstalledDevicesCommand.normalizeOS("iPadOS 26.0"), "iPadOS 26.0")
        XCTAssertEqual(ApiInstalledDevicesCommand.normalizeOS(""), "")
    }
}

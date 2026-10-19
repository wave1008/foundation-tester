import XCTest
@testable import fleetest

/// ライブ操作の hideKeyboard: Android はブリッジへ送り、iOS は送らずにライブ操作向けの文言で断る
/// (ブリッジの 501 の古い文言「Android 専用・pressEnter を使え」を出さない)
final class ApiLiveHideKeyboardTests: XCTestCase {

    func testAndroidIsSentToTheBridge() {
        XCTAssertNil(ApiLiveServe.hideKeyboardRefusal(platform: "android"))
    }

    func testIOSIsRefusedWithWhatThePersonCanDoInstead() throws {
        let message = try XCTUnwrap(ApiLiveServe.hideKeyboardRefusal(platform: "ios"))
        XCTAssertTrue(message.contains("not available in live control on iOS"), message)
        XCTAssertTrue(message.contains("Tap an empty spot outside the field"), message)
        XCTAssertTrue(message.contains("press Return"), message)
        XCTAssertFalse(message.contains("Android-only"), message)
    }

    /// 配線: 断る判定が hideKeyboard の分岐でブリッジへ送る前に呼ばれていること
    func testTheRefusalRunsBeforeTheBridgeCall() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift"),
                                encoding: .utf8)
        let branch = try XCTUnwrap(source.range(of: "case \"hideKeyboard\":"))
        let after = source[branch.upperBound...]
        let refusal = try XCTUnwrap(after.range(of: "hideKeyboardRefusal(platform:"))
        let bridge = try XCTUnwrap(after.range(of: "driver.hideKeyboard()"))
        XCTAssertLessThan(refusal.lowerBound, bridge.lowerBound)
    }
}

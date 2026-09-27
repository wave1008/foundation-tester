// `fleetest api restart-bridge`: 純粋に切り出せる部分だけを固定する(Android を断ること・
// 断りの文言)。デバイスを触る部分(UDID 解決・BridgeLauncher.stopMatching・BridgeProvisioner)は
// デバイスが要るため対象外。

import XCTest

@testable import fleetest

final class ApiRestartBridgeCommandTests: XCTestCase {

    func testAndroidIsRejected() {
        XCTAssertThrowsError(try ApiRestartBridgeCommand.requireIOS(platform: "android")) { error in
            XCTAssertEqual(error as? RestartBridgeError, .androidNotSupported)
        }
    }

    func testIOSPassesValidation() {
        XCTAssertNoThrow(try ApiRestartBridgeCommand.requireIOS(platform: "ios"))
    }

    func testAndroidNotSupportedMessageMentionsTheAlternative() {
        let message = RestartBridgeError.androidNotSupported.errorDescription ?? ""
        XCTAssertTrue(message.contains("iOS only"), message)
        XCTAssertTrue(message.contains("bridge down"), message)
    }

    func testInUseMessagePassesThroughVerbatim() {
        XCTAssertEqual(RestartBridgeError.inUse("refusing to stop: X is in use").errorDescription,
                       "refusing to stop: X is in use")
    }

    func testNoUDIDMessageNamesTheDevice() {
        XCTAssertEqual(RestartBridgeError.noUDID("iPhone 17").errorDescription,
                       "could not resolve a UDID for iPhone 17")
    }
}

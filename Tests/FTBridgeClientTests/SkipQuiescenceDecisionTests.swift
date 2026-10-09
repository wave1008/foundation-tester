// コマンドの `lightSettle:` 上書き × プロファイルの `iosLightSettle` から、リクエストの
// `skipQuiescence` 欄(false はキーごと省略 = nil)を決める表の固定。

import XCTest
@testable import FTBridgeClient

final class SkipQuiescenceDecisionTests: XCTestCase {
    func testOverrideNilFollowsTheProfile() {
        XCTAssertEqual(BridgeClient.skipQuiescence(profileLightSettle: true, override: nil), true)
        XCTAssertNil(BridgeClient.skipQuiescence(profileLightSettle: false, override: nil))
    }

    func testOverrideTrueWinsOverTheProfile() {
        XCTAssertEqual(BridgeClient.skipQuiescence(profileLightSettle: true, override: true), true)
        XCTAssertEqual(BridgeClient.skipQuiescence(profileLightSettle: false, override: true), true)
    }

    func testOverrideFalseWinsOverTheProfile() {
        XCTAssertNil(BridgeClient.skipQuiescence(profileLightSettle: true, override: false))
        XCTAssertNil(BridgeClient.skipQuiescence(profileLightSettle: false, override: false))
    }
}

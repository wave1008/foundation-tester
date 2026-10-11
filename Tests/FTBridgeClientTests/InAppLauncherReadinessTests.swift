// in-app の起動待ちは、答えた相手が注入した端末のブリッジかまで見る(InAppLauncher.waitUntilReady)。
// ポートが別の端末のブリッジに使われていると、その ready で起動できたと読み、以後の操作が別の端末へ届く

import XCTest
@testable import FTBridgeClient

final class InAppLauncherReadinessTests: XCTestCase {

    func testReadinessRequiresTheSameDevice() {
        XCTAssertTrue(InAppLauncher.isOwnBridge(reportedUDID: "abc", udid: "ABC"))
        XCTAssertFalse(InAppLauncher.isOwnBridge(reportedUDID: "OTHER", udid: "ABC"))
        XCTAssertTrue(InAppLauncher.isOwnBridge(reportedUDID: nil, udid: "ABC"), "udid を申告しない旧ブリッジは従来どおり")
    }
}

import XCTest
@testable import FTBridgeClient
import FTCore

/// in-app ブリッジがメインスレッドを待つ天井は、ホストの操作系 HTTP 上限より短くなければならない
/// (逆だとブリッジが 504 を返す前にホストが `bridgeUnreachable` と読み、意味の違う失敗になる)
final class BridgeMainThreadBudgetTests: XCTestCase {
    func testInAppMainThreadWaitIsBelowTheHostInteractionTimeout() {
        XCTAssertLessThan(Double(BridgeAPI.inAppMainThreadWaitMs) / 1000,
                          BridgeClient.Timeout.interaction)
        // 往復と応答の組み立てに 5 秒残す(定数の doc)
        XCTAssertLessThanOrEqual(Double(BridgeAPI.inAppMainThreadWaitMs) / 1000,
                                 BridgeClient.Timeout.interaction - 5)
        XCTAssertEqual(BridgeAPI.inAppMainThreadWaitMs, 15_000)
    }
}

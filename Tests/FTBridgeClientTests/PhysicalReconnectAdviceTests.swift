import XCTest
@testable import FTBridgeClient

/// 未接続の実機に返す助言は、**直前に見えていたトランスポートで選ぶ**。
/// 両方を並べていた頃は、USB に挿さっている端末に「同じネットワークか確かめろ」と言っていた
final class PhysicalReconnectAdviceTests: XCTestCase {

    func testWiredAdviceDoesNotTalkAboutTheNetwork() {
        let advice = IOSPhysicalDeviceCatalogError.reconnectAdvice(transport: "wired")
        XCTAssertTrue(advice.contains("USB"))
        XCTAssertTrue(advice.contains("unlock"))
        XCTAssertFalse(advice.contains("same network"))
    }

    func testLocalNetworkAdviceDoesNotTellThemToRepluggTheCableFirst() {
        let advice = IOSPhysicalDeviceCatalogError.reconnectAdvice(transport: "localNetwork")
        XCTAssertTrue(advice.contains("same"))
        XCTAssertTrue(advice.contains("network"))
        XCTAssertFalse(advice.contains("unlock"))
    }

    func testUnknownTransportKeepsBothHalves() {
        let advice = IOSPhysicalDeviceCatalogError.reconnectAdvice(transport: "unknown")
        XCTAssertTrue(advice.contains("USB"))
        XCTAssertTrue(advice.contains("network"))
    }

    /// 実際に投げられるエラー文にも助言が載ること(文言だけ直して配線を忘れる型を落とす)
    func testErrorMessageCarriesTheTransportSpecificAdvice() {
        let error = IOSPhysicalDeviceCatalogError.notConnected(
            udid: "00008110-000260242EEB801E", name: "iPhone SE3", transport: "wired")
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("iPhone SE3"))
        XCTAssertTrue(message.contains("unlock"))
        XCTAssertFalse(message.contains("same network"))
    }
}

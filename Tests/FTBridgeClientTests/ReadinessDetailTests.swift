// 起動待ちの失敗文(BridgeClient.readinessDetail)は一次情報だけを運ぶ。
// 2026-09-18: in-app の launch 失敗が `bridgeConnectionRefused(context: FTCore.DriverErrorContext(engine: …iosXCUITest …` と
// 列挙値のダンプを利用者へ出していた(しかも in-app なのに XCUITest と名乗る)

import XCTest
import FTCore
@testable import FTBridgeClient

final class ReadinessDetailTests: XCTestCase {
    private let context = DriverErrorContext(engine: .iosXCUITest, physicalDevice: false)

    func testRefusedCarriesOnlyThePrimaryDetail() {
        let text = BridgeClient.readinessDetail(
            DriverError.bridgeConnectionRefused(context: context, detail: "Could not connect to the server."))
        XCTAssertEqual(text, "connection refused (Could not connect to the server.)")
    }

    func testUnreachableCarriesOnlyThePrimaryDetail() {
        let text = BridgeClient.readinessDetail(
            DriverError.bridgeUnreachable(context: context, detail: "The request timed out."))
        XCTAssertEqual(text, "no answer (The request timed out.)")
    }

    /// ほかのエラーは完成文(LocalizedError)を使い、型名や列挙値を出さない
    func testOtherErrorsNeverDumpTheEnum() {
        let text = BridgeClient.readinessDetail(DriverError.badResponse(status: 500, body: "boom"))
        XCTAssertFalse(text.contains("badResponse"), text)
        XCTAssertFalse(text.contains("DriverError"), text)
    }
}

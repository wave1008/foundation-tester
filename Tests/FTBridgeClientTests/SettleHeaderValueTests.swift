// SettleOverride.skip → `X-FT-Settle` ヘッダ値の決定(true は "0"、false はヘッダ無し)の固定。
import XCTest
@testable import FTBridgeClient
import FTCore

final class SettleHeaderValueTests: XCTestCase {
    func testSkipSendsZero() {
        XCTAssertEqual(BridgeClient.settleHeaderValue(skip: true), "0")
    }

    func testNoSkipOmitsHeader() {
        XCTAssertNil(BridgeClient.settleHeaderValue(skip: false))
    }

    func testHeaderNameIsPinned() {
        XCTAssertEqual(BridgeAPI.settleHeader, "X-FT-Settle")
    }
}

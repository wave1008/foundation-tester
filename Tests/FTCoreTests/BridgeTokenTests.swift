// LAN bind(実機)の XCUITest ブリッジ認証(BridgeAPI のトークン判定)。
// 定数時間比較・トークン生成・要否判定の純粋関数を検証する。
// ブリッジ側(BridgeHTTPServer)は Runner ターゲットにあり swift test の対象外なので、
// 判定はここで固める(この規律自体が実装の設計方針)。

import XCTest
import FTCore

final class BridgeTokenTests: XCTestCase {

    // MARK: - bridgeTokenMatches

    func testMatchingTokensAreEqual() {
        XCTAssertTrue(BridgeAPI.bridgeTokenMatches(expected: "abc123", provided: "abc123"))
    }

    func testDifferentTokensDoNotMatch() {
        XCTAssertFalse(BridgeAPI.bridgeTokenMatches(expected: "abc123", provided: "abc124"))
    }

    func testNilProvidedNeverMatches() {
        XCTAssertFalse(BridgeAPI.bridgeTokenMatches(expected: "abc123", provided: nil))
    }

    /// 長さが違えば即 false(定数時間比較でも早期に不一致が確定してよい観測結果は false のみ)
    func testDifferentLengthsDoNotMatch() {
        XCTAssertFalse(BridgeAPI.bridgeTokenMatches(expected: "abc", provided: "abcd"))
        XCTAssertFalse(BridgeAPI.bridgeTokenMatches(expected: "abcd", provided: "abc"))
    }

    /// 空の expected は「未設定」であって「何にでも一致」ではない。危険な true を返さないこと
    func testEmptyExpectedNeverMatchesEvenWithEmptyProvided() {
        XCTAssertFalse(BridgeAPI.bridgeTokenMatches(expected: "", provided: ""))
        XCTAssertFalse(BridgeAPI.bridgeTokenMatches(expected: "", provided: nil))
    }

    // MARK: - makeBridgeToken

    func testMakeBridgeTokenProducesDistinctValues() {
        XCTAssertNotEqual(BridgeAPI.makeBridgeToken(), BridgeAPI.makeBridgeToken())
    }

    /// 32 バイトの16進表現 = 64 文字
    func testMakeBridgeTokenLengthIs64() {
        XCTAssertEqual(BridgeAPI.makeBridgeToken().count, 64)
    }

    func testMakeBridgeTokenIsLowercaseHex() {
        let token = BridgeAPI.makeBridgeToken()
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: - bridgeTokenRequired

    func testTokenRequiredMirrorsBindAll() {
        XCTAssertTrue(BridgeAPI.bridgeTokenRequired(bindAll: true))
        XCTAssertFalse(BridgeAPI.bridgeTokenRequired(bindAll: false))
    }
}

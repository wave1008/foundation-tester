// profile を渡さない探索(MCP の ft_*)は**iOS を常に XCUITest で動かす**ことを固定する(ユーザー決定)。
//
// 接続先が in-app ブリッジでも ハイブリッド構成は組まず、同じデバイスの XCUITest ブリッジへ振り替える。in-app の合成タッチは
// 注入される前提で作られていないアプリ(Apple マップの経路カード等)で効かないまま ok を返した。
// XCUITest を用意できなければ in-app へは落とさない(resolve が断る)。
//
// 決定だけを純粋関数に切ってあるので、デバイス無しで全分岐を試せる(IO 部分の resolve は
// ブリッジ走査を伴うため対象外)。

import XCTest
@testable import FTBridgeClient

final class ExploreDriverResolverTests: XCTestCase {

    private typealias Plan = ExploreDriverResolver.Plan

    private func plan(bridge: String?, xcuiPort: UInt16? = 8124) -> Plan {
        ExploreDriverResolver.plan(preferred: 8123, bridge: bridge, xcuiPort: xcuiPort)
    }

    /// in-app に繋いでも、同じデバイスの XCUITest へ振り替える(ハイブリッド構成を組まない)
    func testInAppBridgeIsReroutedToXCUITest() {
        XCTAssertEqual(plan(bridge: "inapp"), .rerouteToXCUI(port: 8124))
    }

    /// XCUITest ブリッジや無応答はそのまま(振る舞いを変えない)
    func testNonInAppPortsAreUsedAsIs() {
        XCTAssertEqual(plan(bridge: "xcuitest"), .direct(port: 8123))
        XCTAssertEqual(plan(bridge: nil), .direct(port: 8123), "無応答のポートを勝手に読み替えない")
    }

    /// **XCUITest を用意できなければ in-app へは落とさない**(以前は in-app 単独・in-app をそのまま使っていた)
    func testWithoutAnXCUITestBridgeItDoesNotFallBackToInApp() {
        XCTAssertEqual(plan(bridge: "inapp", xcuiPort: nil), .noXCUITest(inAppPort: 8123))
    }
}

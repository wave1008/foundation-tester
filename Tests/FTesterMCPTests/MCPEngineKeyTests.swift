// 宛先ごとの記憶が混ざらないこと。
//
// `driver(_:)` は udid を**解決したポート**でドライバを引くのに、`engineKey` は生の引数しか
// 見ていなかったため、udid で指した機はすべて `port=nil` の同じキーへ落ちていた。
// そのキーで引かれるのは lastSnapshots / launchedBundleIDs / uiFrameworkHints /
// connections / pendingWarnings / udids / engines の7つ。
//
// 実測した3症状(すべて同じ根):
//   - ft_status(udid) が `@ port …` を出さない(connections が引けない)
//   - allowVersionSkew の警告が出ない(pendingWarnings が引けない)
//   - 機A に Preferences・機B に Maps を launch した後、機A への ft_open_url が
//     com.apple.Maps へ配ると申告する(launchedBundleIDs が混ざる)
//
// 入口(`call`)で udid を port へ畳むことで揃えた。ここではその不変条件を固定する。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPEngineKeyTests: XCTestCase {

    // MARK: - 畳み込みそのもの

    func testPortIsInjectedSoDownstreamSeesTheSameDestination() {
        let folded = MCPServer.injectingPort(["platform": "ios", "udid": "AAA"], port: 8123)
        XCTAssertEqual(folded["port"] as? Int, 8123)
        // udid は消さない: ft_status などが「どの機か」を言うのに使う
        XCTAssertEqual(folded["udid"] as? String, "AAA")
    }

    /// 解決できなかったときは**触らない**(嘘のポートを載せない)
    func testNothingIsInjectedWhenThePortIsUnknown() {
        let args: [String: Any] = ["platform": "ios", "udid": "AAA"]
        XCTAssertNil(MCPServer.injectingPort(args, port: nil)["port"])
    }

    // MARK: - 混ざらないこと(これが壊れていた)

    func testTwoDevicesTargetedByUDIDGetDifferentKeys() {
        let a = MCPServer.engineKey(MCPServer.injectingPort(
            ["platform": "ios", "udid": "AAA"], port: 8123))
        let b = MCPServer.engineKey(MCPServer.injectingPort(
            ["platform": "ios", "udid": "BBB"], port: 8124))
        XCTAssertNotEqual(a, b, "udid で指した2台が同じキーに落ちている(記憶が混ざる)")
    }

    /// **同じ機なら port でも udid でも同じキー**。ここが割れると、port で撮った木を
    /// udid のタップが見失う(逆も同じ)
    func testSameDeviceIsOneKeyWhicheverWayItIsAddressed() {
        let byPort = MCPServer.engineKey(["platform": "ios", "port": 8123])
        let byUDID = MCPServer.engineKey(MCPServer.injectingPort(
            ["platform": "ios", "udid": "AAA"], port: 8123))
        XCTAssertEqual(byPort, byUDID)
    }

    /// Android は serial で分かれたまま(畳み込みが別プラットフォームを巻き込まないこと)
    func testAndroidSerialsStayDistinct() {
        let a = MCPServer.engineKey(["platform": "android", "serial": "emulator-5554"])
        let b = MCPServer.engineKey(["platform": "android", "serial": "emulator-5556"])
        XCTAssertNotEqual(a, b)
    }

    /// udid の無い引数は**素通し**(既定のポートを勝手に足さない)。
    /// なお「走査を1回も払わない」ことはここでは検証できない —— `foldingUDIDIntoPort` の
    /// 早期脱出は `portForIOS` 側の同じ guard と重複していて、外しても観測できる差が出ない
    /// (変異テストで確認)。速さの主張はテストでなくコードの読みに委ねる
    func testArgumentsWithoutAUDIDPassThroughUntouched() async throws {
        let args: [String: Any] = ["platform": "android", "serial": "emulator-5554"]
        let folded = try await MCPServer.foldingUDIDIntoPort(args)
        XCTAssertEqual(folded["serial"] as? String, "emulator-5554")
        XCTAssertNil(folded["port"])
    }
}

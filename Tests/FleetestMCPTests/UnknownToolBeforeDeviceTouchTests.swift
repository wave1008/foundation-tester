// call(tool:args:) は canonicalToolName の直後・foldingUDIDIntoPort(udid→port のブリッジ走査)より
// 前でツール名を toolDefinitions と照合する。**この門が無いと**、存在しない udid + 打ち間違えた
// ツール名の呼び出しが「unknown tool」ではなく「no running bridge is on udid …」を返す
// (foldingUDIDIntoPort がツール名を見ずに udid の解決を先に撃つため。実測)。
// エージェントはこれを「デバイスの問題」と誤診し、座標打ちや再起動へ迷い込む。
//
// **udid を伴う呼び出しでも実ブリッジ走査を待たずに判定できること自体がこの修正の効能**
// (ブリッジ走査は `BridgeDiscovery.scan` の実 IO で、この門がなければテストも数秒かかる)。

import XCTest
@testable import fleetest_mcp

final class UnknownToolBeforeDeviceTouchTests: XCTestCase {

    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                           recordSnapshot: { _, _, _ in })
    }

    /// 未知のツール名 + ブリッジの居ない udid → 「unknown tool」(「no running bridge」ではない)。
    /// この門で弾かれる = foldingUDIDIntoPort へ到達していない(到達していれば udid の走査で
    /// 数秒かかる/別の文言になる)
    func testUnknownToolNameFailsBeforeUDIDIsResolved() async {
        do {
            _ = try await server.call(
                tool: "ft_nope", args: ["udid": "no-such-simulator-udid-0000"])
            XCTFail("未知のツールが通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("unknown tool: ft_nope"), message)
            XCTAssertFalse(message.contains("no running bridge"), message)
            XCTAssertFalse(message.contains("bridge"), message)
        }
    }

    /// 既知のツール名(udid 無し)はこの門を素通りし、通常どおり dispatch される
    func testKnownToolNameIsNotBlockedByThisGate() async throws {
        _ = try await server.call(tool: "ft_status", args: [:])
    }
}

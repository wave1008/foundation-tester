// udid を添えた呼び出しの宛先解決: 走査(BridgeDiscovery.scan)の前に候補1本を狙い撃ち、一致のときだけ走査を省く。
// 実測: 20 本近いブリッジが動くフリートで udid 付きの呼び出しが毎回 3.5〜6 秒(入口と driver() で走査2回)。
// 狙い撃ちと走査は実ブリッジが要るので、ここで固めるのは判定(afterCandidateProbe)と候補の選び方(rememberedPort)

import XCTest
@testable import fleetest_mcp

final class UDIDPreScanProbeTests: XCTestCase {

    func testConfirmedMatchUsesTheCandidateWithoutScanning() {
        XCTAssertEqual(MCPServer.afterCandidateProbe(candidate: 8127, explicit: nil, identity: .confirmedMatch),
                       .use(8127))
        XCTAssertEqual(MCPServer.afterCandidateProbe(candidate: 8127, explicit: 8127, identity: .confirmedMatch),
                       .use(8127))
    }

    /// 明示 port の結果だけを持ち越す(走査の後で同じ probe を二度撃たない)。記憶の候補の結果は持ち越さない
    func testNonMatchFallsBackToTheScanCarryingOnlyTheExplicitPortsResult() {
        XCTAssertEqual(MCPServer.afterCandidateProbe(candidate: 8127, explicit: 8127, identity: .unknown),
                       .scan(knownExplicit: .unknown))
        XCTAssertEqual(MCPServer.afterCandidateProbe(candidate: 8127, explicit: 8127,
                                                     identity: .confirmedMismatch(actualUDID: "B")),
                       .scan(knownExplicit: .confirmedMismatch(actualUDID: "B")))
        XCTAssertEqual(MCPServer.afterCandidateProbe(candidate: 8127, explicit: nil, identity: .unknown),
                       .scan(knownExplicit: nil))
    }

    /// 記憶の候補は「その udid で繋いだポートが1本に決まる」ときだけ
    func testRememberedPortOnlyWhenOneDistinctPortIsRememberedForTheUDID() {
        let server = MCPServer()
        XCTAssertNil(server.rememberedPort(forUDID: "U1"))
        server.udids["direct:ios:8127:"] = "U1"
        server.connectedPorts["direct:ios:8127:"] = 8127
        server.udids["direct:ios:8131:"] = "U2"
        server.connectedPorts["direct:ios:8131:"] = 8131
        XCTAssertEqual(server.rememberedPort(forUDID: "U1"), 8127)
        XCTAssertNil(server.rememberedPort(forUDID: ""))
        XCTAssertNil(server.rememberedPort(forUDID: nil))
        server.udids["direct:ios:8150:"] = "U1"
        server.connectedPorts["direct:ios:8150:"] = 8150
        XCTAssertNil(server.rememberedPort(forUDID: "U1"))
    }
}

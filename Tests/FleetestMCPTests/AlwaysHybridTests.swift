// MCP の iOS シミュレータを常に hybrid にする経路(MCPServer+AlwaysHybrid.swift)の判定と巻き戻し。
// 注入・起動そのものは実ブリッジが要るのでデバイスで確かめる(差し替えドライバでは組み替えが走らない)

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class AlwaysHybridTests: XCTestCase {

    private func status(engine: String, bundle: String, udid: String?) -> StatusResponse {
        StatusResponse(ready: true, device: "iPhone", osVersion: "27.0", sessionBundleID: bundle,
                       engine: engine, udid: udid)
    }

    /// **台帳のポートは、使っているのが自分だと言えるときだけ使い回す**(台帳は古いまま残り、ポートは端末を
    /// またいで使い回される。別の端末のブリッジが答えるポートへ注入すると、以後の操作が別の端末へ届く)
    func testLedgerPortIsReusedOnlyWhenItIsVerifiablyOurs() {
        let reuse = MCPServer.ledgerPortIsReusable
        XCTAssertTrue(reuse(true, nil, "U1", "com.apple.Maps"), "誰も待ち受けていない")
        XCTAssertTrue(reuse(false, status(engine: "inapp", bundle: "com.apple.Maps", udid: "u1"), "U1", "com.apple.Maps"),
                      "同じ端末・同じアプリの in-app(udid の大文字小文字は問わない)")
        XCTAssertFalse(reuse(false, nil, "U1", "com.apple.Maps"), "答えない相手は区別できないので使わない")
        XCTAssertFalse(reuse(false, status(engine: "xcuitest", bundle: "com.apple.Maps", udid: "U1"), "U1", "com.apple.Maps"))
        XCTAssertFalse(reuse(false, status(engine: "inapp", bundle: "com.apple.Maps", udid: "U2"), "U1", "com.apple.Maps"),
                       "別の端末")
        XCTAssertFalse(reuse(false, status(engine: "inapp", bundle: "com.example", udid: "U1"), "U1", "com.apple.Maps"),
                       "別のアプリ")
        XCTAssertFalse(reuse(false, status(engine: "inapp", bundle: "com.apple.Maps", udid: nil), "U1", "com.apple.Maps"),
                       "udid を申告しない相手は自分だと言えない")
    }

    /// **起動に失敗したら組み替える前の記憶へ戻す**(壊れた hybrid のまま残さない)
    func testRollbackRestoresTheSessionAndTheNamedTargetMemory() throws {
        let server = MCPServer(write: { _ in }, makeDriver: nil, recordSnapshot: { _, _, _ in })
        var old = DeviceSession()
        old.engine = "xcuitest"
        server.sessions["old"] = old
        server.lastExplicitIOSTarget = (8137, "U1")
        server.seenExplicitIOSPorts = [8137]
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = MCPServer.HybridUpgradeRollback(
            key: "old", session: server.sessions["old"], newKey: "new", newKeySession: nil,
            lastExplicitIOSTarget: server.lastExplicitIOSTarget, seenExplicitIOSPorts: server.seenExplicitIOSPorts,
            inAppPort: 8123, udid: "U1", repoRoot: repo)
        // 組み替えた後の状態
        server.sessions["old"] = nil
        var upgraded = DeviceSession()
        upgraded.engine = "hybrid"
        server.sessions["new"] = upgraded
        server.lastExplicitIOSTarget = (8123, "U1")
        server.seenExplicitIOSPorts = [8123]

        server.rollBackHybridUpgrade(previous)
        XCTAssertEqual(server.sessions["old"]?.engine, "xcuitest")
        XCTAssertNil(server.sessions["new"])
        XCTAssertEqual(server.lastExplicitIOSTarget?.port, 8137)
        XCTAssertEqual(server.seenExplicitIOSPorts, [8137])
    }
}

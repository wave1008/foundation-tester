// ref の出自がアプリを跨いだときに断る(2026-08-13・軸②「アプリ切替」の監査で実機再現)。
//
// ref の世代は engineKey(= 機)ごとで、アプリでは区切っていない。同じ機で別アプリを起動すると
// 前のアプリで採った ref が次のアプリの木へ再照合され、#id が同じなら黙って当たる。
// E2E の 5 SUT は #id・ラベルが共通契約なので机上の話ではない —— 実測(iOS・同一機)で
// com.ftester.e2e の #nav_selector(ref 54)を採ってから com.ftester.e2e.ios を launch して
// 撃つと `tap [54] done` で別アプリの同名要素を叩き、注記は「1px 動いた・周囲のレイアウトが
// 変わった」と自信を持って誤説明した。

import XCTest
import FTCore
@testable import ftester_mcp

final class RefAppProvenanceTests: XCTestCase {

    private func snapshot(_ bundleID: String?) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: bundleID,
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: [], truncatedCount: 0)
    }

    /// **本命**: 採った木と今の木でアプリが違えば断る
    func testARefTakenInAnotherAppIsRefused() {
        let message = MCPServer.refFromAnotherAppMessage(
            ref: 54, takenFrom: snapshot("com.ftester.e2e"), fresh: snapshot("com.ftester.e2e.ios"))
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("com.ftester.e2e"), message!)
        XCTAssertTrue(message!.contains("com.ftester.e2e.ios"),
                      "今どのアプリが前面かを名指ししていない: \(message!)")
        XCTAssertTrue(message!.contains("ft_snapshot"), message!)
    }

    /// 同じアプリなら何もしない(通常の再照合を邪魔しない)
    func testTheSameAppIsNotRefused() {
        XCTAssertNil(MCPServer.refFromAnotherAppMessage(
            ref: 1, takenFrom: snapshot("com.example.app"), fresh: snapshot("com.example.app")))
    }

    /// **「分からない」を「変わった」と読まない**(旧ブリッジは sessionBundleID を返さない)。
    /// ここで断ると、その構成では ref がまったく使えなくなる
    func testUnknownBundleIDOnEitherSideIsNotRefused() {
        XCTAssertNil(MCPServer.refFromAnotherAppMessage(
            ref: 1, takenFrom: snapshot(nil), fresh: snapshot("com.example.app")))
        XCTAssertNil(MCPServer.refFromAnotherAppMessage(
            ref: 1, takenFrom: snapshot("com.example.app"), fresh: snapshot(nil)))
        XCTAssertNil(MCPServer.refFromAnotherAppMessage(
            ref: 1, takenFrom: nil, fresh: snapshot("com.example.app")))
    }

    // MARK: - 配線(純粋関数だけを固定すると、呼び出しを外す変異が生き残る)

    private func tree(_ bundleID: String, id: String) -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: bundleID,
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [ElementInfo(ref: 1, type: "button", identifier: id, label: "セレクタ",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 166, width: 370, height: 48), depth: 1)],
            truncatedCount: 0)
    }

    /// **ft_tap がガードを通ること**。兄弟アプリは同じ id を出すので、木の見た目では区別が付かない
    /// —— 前のアプリで採った ref がそのまま当たってしまう形を、実際の呼び出しで固定する
    func testTapRefusesARefTakenBeforeTheAppChanged() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = tree("com.ftester.e2e", id: "nav_selector")
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        // 同じ機で別アプリへ切り替える(id もラベルも同じ = 木では見分けが付かない)
        driver.snapshotResponse = tree("com.ftester.e2e.ios", id: "nav_selector")
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
            XCTFail("別アプリで採った ref がそのまま当たった")
        } catch {
            XCTAssertTrue("\(error)".contains("com.ftester.e2e.ios"), "\(error)")
            XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap") },
                           "拒否したはずなのに tap が発射されている: \(driver.calls)")
        }
    }

    /// 同じアプリのままなら従来どおり通る(ガードが常時拒否になっていないこと)
    func testTapStillWorksWhenTheAppDidNotChange() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = tree("com.ftester.e2e", id: "nav_selector")
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap") }, "\(driver.calls)")
    }
}

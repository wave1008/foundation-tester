// 座標タップは下書き(`ft_draft_scenario`)でも**実行できる行**になること(2026-08-16)。
//
// `// TODO: no stable selector` へ落とさない —— 実測では操作可能要素の 9.3% が書けるセレクタを
// 持たないので、そこを TODO のままにすると**その画面を通るシナリオが再生できない**。
//
// **ただし用途で重みが違う**(ユーザー方針 2026-08-16): 対話的な探索では座標のほうが速い
// ことがありそれでよいが、**シナリオに残す目的ではセレクタが最優先**。そこで行は出しつつ、
// 置き換えるべきであることを行末コメントに残す。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPCoordinateDraftTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func bodyText(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testCoordinateTapBecomesARunnableLineWithAReplaceMeNote() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_tap", args: ["x": 120.0, "y": 640.0])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("tap(x: 120, y: 640)"), text)
        XCTAssertFalse(text.contains("TODO: no stable selector"),
                       "座標は書けるようになったので TODO へ落とさない: \(text)")
        // **セレクタ最優先の方針を行に残す**(テストを書く目的ではここが判断材料になる)
        XCTAssertTrue(text.contains("replace with a selector"), text)
    }

    /// ref で叩いた手は従来どおりセレクタ行(座標の導入で退行していないこと)
    func testRefTapStillBecomesASelectorLine() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("tap(\"#login_btn\")"), text)
        XCTAssertFalse(text.contains("x:"), text)
    }
}

// `ft_type {replace:true}` は下書き(`ft_draft_scenario`)にも `replace: true` を記録すること
//。取りこぼすと、対話的に検証した replace 操作が下書きでは通常の追記
// (`type(sel, text)`)1行に化ける。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPTypeReplaceDraftTests: XCTestCase {

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

    /// **入力欄にする**: FakeDriver の既定(Button)へ ft_type すると
    /// 「入力欄でない」ため撃つ前に拒否されるようになったので、id はそのままに type だけ変える
    private func useTextFieldAsTheDefaultElement() {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "textField", identifier: "login_btn",
                                   label: "ログイン", value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 10, y: 20, width: 100, height: 40), depth: 1)],
            truncatedCount: 0)
    }

    func testDraftRecordsReplaceWhenFtTypeUsesIt() async throws {
        useTextFieldAsTheDefaultElement()
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc", "replace": true])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("type(\"#login_btn\", \"abc\", replace: true)"), text)
    }

    /// replace 未指定の通常呼び出しでは "replace: true" が出ないこと(退行防止)
    func testDraftDoesNotRecordReplaceForPlainType() async throws {
        useTextFieldAsTheDefaultElement()
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc"])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("type(\"#login_btn\", \"abc\")"), text)
        XCTAssertFalse(text.contains("replace:"), text)
    }
}

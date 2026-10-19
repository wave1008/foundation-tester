// `MCPServer.ignoredWaitSecondsNote` — `waitFor` / `waitForChange` を宣言するツールに `waitSeconds` だけを渡すと、
// 待ちの上限でしかないので黙って無視されていた。DSL の操作の `waitSeconds:` と同じ名前なので
// 「対象が出るまで待って撃つ」と読まれる。単独で使うツール(`ft_fold`)では言わない。

import XCTest
@testable import fleetest_mcp

final class IgnoredWaitSecondsNoteTests: XCTestCase {

    func testWaitSecondsAloneIsCalledOutOnToolsWhereItOnlyBoundsWaitFor() {
        let note = MCPServer.ignoredWaitSecondsNote(tool: "ft_tap", args: ["ref": 3, "waitSeconds": 10])
        XCTAssertTrue(note.contains("waitSeconds was ignored"), note)
        XCTAssertTrue(note.contains("ft_tap"), note)
        XCTAssertFalse(MCPServer.ignoredWaitSecondsNote(tool: "ft_batch", args: ["waitSeconds": 10]).isEmpty)
    }

    func testNoNoteWhenAWaitIsGivenOrTheToolUsesWaitSecondsOnItsOwn() {
        XCTAssertEqual(MCPServer.ignoredWaitSecondsNote(
            tool: "ft_tap", args: ["ref": 3, "waitSeconds": 10, "waitFor": "#ok", "snapshotAfter": true]), "")
        XCTAssertEqual(MCPServer.ignoredWaitSecondsNote(
            tool: "ft_tap", args: ["ref": 3, "waitSeconds": 10, "waitForChange": true, "snapshotAfter": true]), "")
        XCTAssertEqual(MCPServer.ignoredWaitSecondsNote(tool: "ft_tap", args: ["ref": 3]), "")
        XCTAssertEqual(MCPServer.ignoredWaitSecondsNote(tool: "ft_fold", args: ["state": "fold", "waitSeconds": 10]), "")
    }

    /// ft_open_url は snapshotAfter で待ちを省くと自分で waitForChange を立てて waitSeconds まで待つ = 無視していない。
    /// snapshotAfter が無ければ待ちは走らないので、従来どおり言う
    func testOpenURLsImplicitLandingWaitUsesWaitSeconds() {
        XCTAssertEqual(MCPServer.ignoredWaitSecondsNote(
            tool: "ft_open_url", args: ["url": "app://x", "snapshotAfter": true, "waitSeconds": 10]), "")
        XCTAssertFalse(MCPServer.ignoredWaitSecondsNote(
            tool: "ft_open_url", args: ["url": "app://x", "waitSeconds": 10]).isEmpty)
        XCTAssertFalse(MCPServer.ignoredWaitSecondsNote(
            tool: "ft_open_url", args: ["url": "app://x", "snapshotAfter": true, "waitForChange": false,
                                         "waitSeconds": 10]).isEmpty)
    }
}

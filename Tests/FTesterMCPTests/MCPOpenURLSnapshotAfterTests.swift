// ft_open_url に他の操作系ツールと同じ snapshotAfter 系キーを足した分の回帰(2026-08-12)。
// 木を返す(snapshotAfter: true)のに「もう一度 ft_snapshot を撃て」と言うのは矛盾するので、
// 1行目の文面を出し分ける。組み立ては純関数(MCPServer.openURLSummary)に切り出してあるので
// デバイス無しで固定できる

import XCTest
@testable import ftester_mcp

final class MCPOpenURLSummaryTests: XCTestCase {
    func testWithoutSnapshotAfterMentionsAsynchronousDeliveryAndSnapshotAdvice() {
        let summary = MCPServer.openURLSummary(url: "myapp://item/1", bundleID: "com.example.app",
                                               bundleIDWasRemembered: false,
                                               snapshotAfter: false)
        XCTAssertTrue(summary.hasPrefix("Delivered myapp://item/1 to com.example.app."), summary)
        XCTAssertTrue(summary.contains("asynchronous"), summary)
        XCTAssertTrue(summary.contains("ft_snapshot"), summary)
    }

    /// **本丸**: snapshotAfter: true で木を返すのに「ft_snapshot を撃ち直せ」とは言わない
    /// (矛盾を作らない)。ただし**配送が非同期であることは黙らない** —— settle-lite は
    /// 操作前の木を覚えているときしか走らないので、ft_launch 直後の snapshotAfter は
    /// 遷移前の画面を返し得る。撮り直しの代わりに waitFor を案内する(2026-08-12 のレビュー)
    func testWithSnapshotAfterSwapsTheAdviceForWaitForButKeepsTheAsyncCaveat() {
        let summary = MCPServer.openURLSummary(url: "myapp://item/1", bundleID: "com.example.app",
                                               bundleIDWasRemembered: false,
                                               snapshotAfter: true)
        XCTAssertTrue(summary.hasPrefix("Delivered myapp://item/1 to com.example.app."), summary)
        XCTAssertFalse(summary.contains("ft_snapshot"), summary)
        XCTAssertTrue(summary.contains("asynchronous"), summary)
        XCTAssertTrue(summary.contains("waitFor"), summary)
    }

    func testBundleIDIsOptionalInBothForms() {
        for snapshotAfter in [true, false] {
            let summary = MCPServer.openURLSummary(url: "myapp://x", bundleID: nil,
                                                   bundleIDWasRemembered: false,
                                                   snapshotAfter: snapshotAfter)
            // bundleID があれば "Delivered <url> to <bundle>." になるので、接頭辞だけで足りる
            XCTAssertTrue(summary.hasPrefix("Delivered myapp://x. "), summary)
        }
    }
}

/// スキーマの過不足(2026-08-12): ft_open_url も他の操作系ツールと同じ畳み方・待ち方の
/// 引数一式を持つ。MCPServerToolDefinitionsTests.testSnapshotAfterToolsDeclareTheSameFoldingPropertiesAsSnapshot
/// は既存ツールの固定集合を検査するので、ft_open_url はここで独立に確認する
final class MCPOpenURLToolDefinitionTests: XCTestCase {
    private var properties: [String: Any] {
        let definition = MCPServer.toolDefinitions.first { $0["name"] as? String == "ft_open_url" }
        let schema = definition?["inputSchema"] as? [String: Any]
        return schema?["properties"] as? [String: Any] ?? [:]
    }

    func testDeclaresTheSameOperationKeysAsOtherActionTools() {
        for key in ["snapshotAfter", "waitForChange", "waitFor", "timeout",
                    "expandBulk", "interactiveOnly"] {
            XCTAssertNotNil(properties[key], "ft_open_url に \(key) が無い")
        }
    }

    /// **2つ目の定義を作らない**: ft_tap 等が使う共有プロパティ定数と説明文が同じであること
    /// (別々に書くと片方だけ更新されて食い違う)
    func testSnapshotAfterPropertyIsTheSharedConstant() {
        let tap = MCPServer.toolDefinitions.first { $0["name"] as? String == "ft_tap" }
        let tapProps = (tap?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        let openURLDescription = (properties["snapshotAfter"] as? [String: Any])?["description"] as? String
        let tapDescription = (tapProps?["snapshotAfter"] as? [String: Any])?["description"] as? String
        XCTAssertNotNil(openURLDescription)
        XCTAssertEqual(openURLDescription, tapDescription)
    }
}

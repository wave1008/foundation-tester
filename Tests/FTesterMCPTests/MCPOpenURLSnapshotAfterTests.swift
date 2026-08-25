// ft_open_url に他の操作系ツールと同じ snapshotAfter 系キーを足した分の回帰。
// 木を返す(snapshotAfter: true)のに「もう一度 ft_snapshot を撃て」と言うのは矛盾するので、
// 1行目の文面を出し分ける。組み立ては純関数(MCPServer.openURLSummary)に切り出してあるので
// デバイス無しで固定できる

import XCTest
import FTCore
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

    // MARK: - 着地を待つのが既定

    /// **配送直後に読まない**。URL の配送は非同期なので、`snapshotAfter` だけを渡すと
    /// 前の画面が黙って返っていた。読み手は「開いた先の画面が欲しい」から付けているので、
    /// 既定が誤りの側に倒れていた
    func testSnapshotAfterWaitsForTheScreenToChangeByDefault() async throws {
        let driver = FakeDriver()
        // 配送前の基準 → 配送直後(まだ前の画面)→ 着地後
        driver.scriptedSnapshots = [Self.screen("before"), Self.screen("before"),
                                    Self.screen("after")]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0.01

        let text = (try await server.call(tool: "ft_open_url",
                                          args: ["url": "myapp://x", "snapshotAfter": true]))
            .compactMap { $0["text"] as? String }.joined(separator: "\n")

        XCTAssertTrue(text.contains("\"after\""), "着地前の木を返している: \(text)")
        XCTAssertTrue(text.contains("waitForChange: the tree differs"), text)
    }

    /// **基準が無いときは配送前に1枚読む**(ft_launch → ft_open_url が典型)。
    /// これが無いと `waitForChange` は比べる相手が無くて素通りし、既定が効かない
    func testTakesABaselineWhenNothingWasReadOnThisDeviceYet() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [Self.screen("before"), Self.screen("before"),
                                    Self.screen("after")]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0.01

        _ = try await server.call(tool: "ft_open_url",
                                  args: ["url": "myapp://x", "snapshotAfter": true])

        let order = driver.calls.filter { $0.hasPrefix("snapshot") || $0.hasPrefix("openURL") }
        XCTAssertEqual(order.first?.hasPrefix("snapshot"), true,
                       "配送前に基準を取っていない: \(order)")
    }

    /// **明示された waitForChange: false は尊重する**(既定を押し付けない)。
    /// **台本は「待てば変わる」形にする** —— 待たない版と待つ版で**返る木そのものが違う**
    /// ようにしないと、注記の有無だけを見るテストは「待ったが変化しなかった」と区別できず、
    /// 既定を押し付ける変異を素通しする(2026-08-16 の変異テストで実際に生き残った)
    func testExplicitWaitForChangeFalseIsRespected() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [Self.screen("before"), Self.screen("before"),
                                    Self.screen("after")]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0.01

        let text = (try await server.call(
            tool: "ft_open_url",
            args: ["url": "myapp://x", "snapshotAfter": true, "waitForChange": false]))
            .compactMap { $0["text"] as? String }.joined(separator: "\n")

        // **木の行で見る**(散文には "after" も "waitForChange" も出るので部分文字列では割れない)
        XCTAssertTrue(text.contains("\"before\""), "配送直後の木を返していない: \(text)")
        XCTAssertFalse(text.contains("\"after\""), "待たない指定なのに待っている: \(text)")
        XCTAssertTrue(text.contains("read right after delivery"),
                      "要約が実際にやったことを言っていない: \(text)")
    }

    private static func screen(_ label: String) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [ElementInfo(ref: 1, type: "staticText", identifier: "row",
                                                label: label, value: nil, placeholder: nil,
                                                enabled: true,
                                                frame: FTRect(x: 0, y: 0, width: 100, height: 40),
                                                depth: 1)],
                         truncatedCount: 0)
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

/// スキーマの過不足: ft_open_url も他の操作系ツールと同じ畳み方・待ち方の
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

// 詰まったときに MCP が返す「次の一手」。
//
// 2026-08-06 の外部フィードバックは、機能ではなく**案内の欠落**で詰まっていた:
// ホーム画面は springboard 参照セッションで読めるのに 409 の本文からは辿れず(#6)、
// ブリッジ再起動でセッションが消えたことは "session: none" からは読み取れない(#8)。
// 文言が痩せると同じ迷子が再発するので、要点の語だけ固定する。

import XCTest
import FTBridgeClient
import FTCore
@testable import ftester_mcp

final class MCPGuidanceTests: XCTestCase {

    // MARK: - ホーム画面(#6)

    /// セッション不在の 409 は「まだ launch していない」で出る。ホーム画面を見たい場合の
    /// 読み方(springboard)まで返す
    func testSessionMissingSuggestsSpringboard() {
        let hint = MCPServer.springboardHint(
            DriverError.badResponse(status: 409, body: "no session"), engine: "xcuitest")
        XCTAssertTrue(hint.contains("com.apple.springboard"), hint)
    }

    /// home 後の背面アプリ照会(kAXErrorServerNotFound)も同じ行き止まり
    func testAccessibilityServerNotFoundSuggestsSpringboard() {
        let hint = MCPServer.springboardHint(
            DriverError.badResponse(status: 500, body: "Error kAXErrorServerNotFound"),
            engine: "xcuitest")
        XCTAssertTrue(hint.contains("com.apple.springboard"), hint)
    }

    /// **in-app/hybrid には出さない**: in-app ブリッジは注入先アプリ専用で springboard を掴めず、
    /// 案内どおりにやると 409 が増えるだけになる
    func testInAppEngineGetsNoSpringboardHint() {
        for engine in ["inapp", "hybrid", "android"] {
            XCTAssertEqual(MCPServer.springboardHint(
                DriverError.badResponse(status: 409, body: "no session"), engine: engine), "",
                "engine=\(engine) に springboard を案内してはいけない")
        }
    }

    /// 関係ない失敗(404・ネットワーク)に足さない = 誤誘導しない
    func testUnrelatedFailuresGetNoHint() {
        XCTAssertEqual(MCPServer.springboardHint(
            DriverError.badResponse(status: 404, body: "unknown ref"), engine: "xcuitest"), "")
        XCTAssertEqual(MCPServer.springboardHint(
            DriverError.bridgeUnreachable("refused"), engine: "xcuitest"), "")
        XCTAssertEqual(MCPServer.springboardHint(
            DriverError.badResponse(status: 500, body: "something else"), engine: "xcuitest"), "")
    }

    /// home した直後に「この後 snapshot は読めない」と先に言う(踏んでから調べさせない)
    func testNavigateHomeAnnouncesTheReadPath() {
        let note = MCPServer.homeScreenReadNote(target: "home", engine: "xcuitest")
        XCTAssertTrue(note.contains("com.apple.springboard"), note)
        XCTAssertEqual(MCPServer.homeScreenReadNote(target: "back", engine: "xcuitest"), "")
        XCTAssertEqual(MCPServer.homeScreenReadNote(target: "home", engine: "inapp"), "")
    }

    // MARK: - 未インストール(#3)

    func testNotInstalledMessageNamesTheFix() {
        let message = MCPServer.notInstalledMessage(bundleID: "com.example.myapp")
        XCTAssertTrue(message.contains("com.example.myapp"), message)
        XCTAssertTrue(message.contains("ft_install"), message)
    }

    // MARK: - 接続が消えた(#7)

    /// 「Could not connect」だけでは何が起きたか分からない。**今どこに何が居るか**と
    /// 復帰手順まで返す(ランナー死の筆頭原因は同一シミュレータの2本目)
    func testConnectionLostNamesTheCauseAndTheSurvivors() {
        let message = MCPServer.connectionLostMessage(
            connection: "port 8124",
            running: [BridgeDiscovery.Found(port: 8130, device: "iPhone 17 Pro", engine: "xcuitest")])
        XCTAssertTrue(message.contains("port 8124"), message)
        XCTAssertTrue(message.contains("8130"), message)
        XCTAssertTrue(message.contains("bridge up"), message)
        XCTAssertTrue(message.contains("ft_launch"), message)
    }

    func testConnectionLostWithNothingRunning() {
        let message = MCPServer.connectionLostMessage(connection: "port 8123", running: [])
        XCTAssertTrue(message.contains("no iOS bridge is running now"), message)
    }

    // MARK: - セッション消失(#8)

    /// ブリッジを立て直すとセッションは引き継がれない。"none" だけだと気付けない
    func testStatusExplainsAnEmptySession() async throws {
        let driver = FakeDriver()
        driver.statusResponse = StatusResponse(ready: true, device: "iPhone 17", osVersion: "26.0",
                                               sessionBundleID: nil)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_status", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("ft_launch"), text)
        XCTAssertTrue(text.contains("bridge restart"), text)
    }
}

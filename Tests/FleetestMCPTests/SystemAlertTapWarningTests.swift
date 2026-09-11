// ft_tap の撃つ前の探針とアラートの文言:
// ①SpringBoard の許可アラートはアプリの木を変えずに湧くので、覆いの探針を木の指紋で使い回しても
//   アラートだけは毎回聞く(使い回すと、権限を要求するボタンを叩いた後のタップで黙る)
// ②タップ経路の文言は「何も届かない」と言わない —— in-app は背面へ届き、XCUITest は XCTest が
//   アラートのボタンを押しうる(どちらも実測)

import XCTest
import FTCore
@testable import fleetest_mcp

final class SystemAlertTapWarningTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "button", identifier: "btn_request_photos",
                                   label: "写真", value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 168, width: 370, height: 48), depth: 2)],
            truncatedCount: 0)
        driver.systemUICoveringResponse = SystemUICoveringResponse(covering: false)
    }

    private static let photosAlert = SystemAlertProbeResponse(
        present: true, title: "“E2E”が写真へのアクセスを求めています", buttons: ["許可しない", "許可"])

    private func tapText() async throws -> String {
        try await server.call(tool: "ft_tap", args: ["ref": 1])
            .compactMap { $0["text"] as? String }.joined()
    }

    /// **本命(I6)**: 木が1バイトも変わらないまま2回目のタップの前にアラートが湧いても名指しする
    func testAlertThatAppearsOnAnUnchangedTreeIsNamedOnTheNextTap() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let first = try await tapText()
        XCTAssertFalse(first.contains("system alert"), first)

        driver.scriptedSystemAlert = Self.photosAlert
        let second = try await tapText()
        XCTAssertTrue(second.contains("a system alert (「“E2E”が写真へのアクセスを求めています」"), second)
    }

    /// **in-app(hybrid)**: 背面の要素へ直接届くことを言う(「届かない」と言わない)
    func testInAppTapSaysItStillReachesTheAppBehindTheAlert() async throws {
        server.engines[MCPServer.engineKey([:])] = "hybrid"
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try await tapText()
        XCTAssertTrue(text.contains("it still reaches the app behind the alert"), text)
        XCTAssertFalse(text.contains("nothing in it is reachable"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap") }, "拒否ではなく警告して撃つこと")
    }

    /// **XCUITest**: XCTest がアラートのボタンを押しうることを言う
    func testXCUITestTapSaysXCTestCanPressAnAlertButton() async throws {
        server.engines[MCPServer.engineKey([:])] = "xcuitest"
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try await tapText()
        XCTAssertTrue(text.contains("can press one of its buttons"), text)
        XCTAssertFalse(text.contains("it still reaches the app behind the alert"), text)
    }
}

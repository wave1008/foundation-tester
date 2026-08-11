// ft_scroll_to の再確認は「木に居るか」(旧 `Self.matches`)だけでなく「中心が画面内か」も見る
// (2026-08-12)。FTCore 側のゲート(StepExecutor+ScrollSearch)を通り抜けた場合の独立した砦を固定する:
// executor が成功で返した直後に、MCP が撮り直す木で対象の中心が画面外へ動いていたら、
// "scrolled to" を名乗らない。判定は ⚠️offscreen と共有(TapTargetGeometry.offscreenAdvisory)。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPScrollToOffscreenGateTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func snapshot(frame: FTRect) -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [
                ElementInfo(ref: 1, type: "cell", identifier: "route2", label: "58分",
                            value: nil, placeholder: nil, enabled: true, frame: frame, depth: 1),
            ],
            truncatedCount: 0)
    }

    /// **陽性**: executor は視界内で見つけて成功を返す(settledSignature が読む最初の2枚は画面内)が、
    /// MCP が改めて撮り直す3枚目では対象が画面外へ動いている(実測: Apple マップの経路候補ページャで
    /// x=401・幅234・画面幅402 = 中心が画面外)。「木に居る」だけの再確認(旧 `Self.matches`)は
    /// これを通してしまうので、独立した砦が塞いでいることを確かめる
    func testMovedOffscreenBetweenExecutorAndMCPRefetchIsNotReportedAsSuccess() async {
        let visible = snapshot(frame: FTRect(x: 100, y: 300, width: 200, height: 56))
        let movedOffscreen = snapshot(frame: FTRect(x: 401, y: 300, width: 234, height: 56))
        driver.scriptedSnapshots = [visible, visible, movedOffscreen]

        do {
            _ = try await server.call(tool: "ft_scroll_to",
                                      args: ["selector": "#route2", "maxSwipes": 0])
            XCTFail("中心が画面外へ動いた対象を成功と言ってはいけない")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("off screen"), message)
            XCTAssertTrue(message.contains("scrollFrame"), message)
        }
    }

    /// **陰性対照**: 撮り直した3枚目でも画面内にとどまっていれば従来どおり成功を返す
    /// (「常に失敗させる」方向の変異を検出するための対)
    func testStaysOnscreenBetweenExecutorAndMCPRefetchStillSucceeds() async throws {
        let visible = snapshot(frame: FTRect(x: 100, y: 300, width: 200, height: 56))
        driver.scriptedSnapshots = [visible, visible, visible]

        let text = body(try await server.call(tool: "ft_scroll_to",
                                              args: ["selector": "#route2", "maxSwipes": 0]))
        XCTAssertTrue(text.contains("scrolled to"), text)
    }
}

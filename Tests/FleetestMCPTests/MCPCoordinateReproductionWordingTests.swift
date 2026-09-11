// ft_double_tap / ft_drag / ft_long_press を座標で撃ったときの「DSL でどう書けるか」の注記は
// tap 用の文言(`coordinateReproductionNote`)を流用しない。操作ごとに書き方が違う:
// - doubleTap の DSL コマンドはセレクタしか取らず、座標形が無い
// - drag は `swipePointToPoint(startX:startY:endX:endY:)`
// - long press は `tap(x:, y:, holdSeconds:)`。holdSeconds を省くとただの tap として再生される

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPCoordinateReproductionWordingTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined()
    }

    func testDoubleTapSaysItHasNoCoordinateFormInsteadOfClaimingTapSyntax() async throws {
        let result = try await server.call(tool: "ft_double_tap", args: ["x": 100.0, "y": 200.0])
        let body = text(result)
        XCTAssertTrue(body.contains("doubleTap only takes a selector"), body)
        XCTAssertFalse(body.contains("writable as tap(x:, y:)"), body)
    }

    func testDragNamesSwipePointToPointInsteadOfClaimingTapSyntax() async throws {
        let result = try await server.call(tool: "ft_drag",
                                           args: ["fromX": 10.0, "fromY": 10.0, "dx": 0.0, "dy": 50.0])
        let body = text(result)
        XCTAssertTrue(body.contains("swipePointToPoint("), body)
        XCTAssertFalse(body.contains("writable as tap(x:, y:)"), body)
    }

    /// **本命**: holdSeconds を落とすと長押しが tap に化けるので、書き方に holdSeconds を含める
    func testLongPressIncludesHoldSecondsInTheWritableForm() async throws {
        let result = try await server.call(tool: "ft_long_press",
                                           args: ["x": 10.0, "y": 10.0, "holdSeconds": 2.5])
        let body = text(result)
        XCTAssertTrue(body.contains("tap(x:, y:, holdSeconds: 2.5)"), body)
    }

    /// holdSeconds 省略時の既定(1.0秒)でも、既定値そのものを書き方に出す
    func testLongPressDefaultHoldSecondsStillAppearsInTheWritableForm() async throws {
        let result = try await server.call(tool: "ft_long_press", args: ["x": 10.0, "y": 10.0])
        let body = text(result)
        XCTAssertTrue(body.contains("tap(x:, y:, holdSeconds: 1)"), body)
    }
}

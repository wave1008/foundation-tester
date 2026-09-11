// 画面外の座標(負・画面サイズ超え)への ft_tap / ft_double_tap / ft_long_press / ft_drag は、
// 直近の ft_snapshot の screen に対して判定し**撃たずに拒否**する。in-app ブリッジは「その点を
// 含む最小の frame」を撃つだけで点が画面の中かを見ない(InAppBridge.swift)ので、撃つと画面外の
// 要素が押される。screen が分からない(まだ ft_snapshot を撮っていない)ときは「分からない」を
// 「外れている」と読まず撃つ。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPOffscreenCoordinateGuardTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    /// FakeDriver.snapshotResponse の screen は 390x844(0,0 起点)
    private func takeSnapshot() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
    }

    // MARK: - ft_tap

    func testRejectsOffscreenTapWhenScreenIsKnown() async throws {
        try await takeSnapshot()
        do {
            _ = try await server.call(tool: "ft_tap", args: ["x": 5000.0, "y": -20.0])
            XCTFail("画面外の座標を撃ってはいけない")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(x:") },
                       "拒否したはずなのに実際に撃ってしまった: \(driver.calls)")
    }

    /// **screen が分からないときは従来どおり撃つ**(ft_snapshot をまだ撮っていない呼び出し)
    func testStillFiresWhenScreenIsUnknown() async throws {
        let result = try await server.call(tool: "ft_tap", args: ["x": 5000.0, "y": -20.0])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("done"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap(x:") }, "\(driver.calls)")
    }

    /// 境界(画面の縁ちょうど)は画面内として撃てる(過剰な拒否をしない)
    func testAllowsACoordinateExactlyOnTheScreenEdge() async throws {
        try await takeSnapshot()
        let result = try await server.call(tool: "ft_tap", args: ["x": 390.0, "y": 844.0])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("done"), text)
    }

    // MARK: - ft_double_tap

    func testRejectsOffscreenDoubleTapWhenScreenIsKnown() async throws {
        try await takeSnapshot()
        do {
            _ = try await server.call(tool: "ft_double_tap", args: ["x": -1.0, "y": -1.0])
            XCTFail("画面外の座標を撃ってはいけない")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("doubleTap(x:") }, "\(driver.calls)")
    }

    // MARK: - ft_long_press

    func testRejectsOffscreenLongPressWhenScreenIsKnown() async throws {
        try await takeSnapshot()
        do {
            _ = try await server.call(tool: "ft_long_press", args: ["x": 201.0, "y": 900.0])
            XCTFail("画面外の座標を撃ってはいけない(実測: (201,900) が画面外の要素を押した)")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("press(ref:") || $0.contains("press") },
                       "\(driver.calls)")
    }

    // MARK: - ft_drag

    func testRejectsOffscreenDragStartWhenScreenIsKnown() async throws {
        try await takeSnapshot()
        do {
            _ = try await server.call(tool: "ft_drag",
                                      args: ["fromX": -50.0, "fromY": 100.0, "dx": 0.0, "dy": 200.0])
            XCTFail("画面外の起点から drag を撃ってはいけない")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("drag(") }, "\(driver.calls)")
    }

    /// 画面内の drag は screen が分かっていても従来どおり撃てる(過剰な拒否をしない)
    func testAllowsAnOnscreenDragWhenScreenIsKnown() async throws {
        try await takeSnapshot()
        let result = try await server.call(tool: "ft_drag",
                                           args: ["fromX": 50.0, "fromY": 100.0, "dx": 0.0, "dy": 200.0])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("sent"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("drag(") }, "\(driver.calls)")
    }
}

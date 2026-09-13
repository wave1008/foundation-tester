// 画面外の座標(負・画面サイズ超え)への ft_tap / ft_double_tap / ft_long_press / ft_drag は、
// 直近の ft_snapshot の screen に対して判定し**撃たずに拒否**する。in-app ブリッジは「その点を
// 含む最小の frame」を撃つだけで点が画面の中かを見ない(InAppBridge.swift)ので、撃つと画面外の
// 要素が押される。まだ ft_snapshot を撮っていないときは1枚読んでから判定する(§19 M4)。
// screen が 0(旧ブリッジ)のときだけ「分からない」を「外れている」と読まず撃つ。縁は外(`<`)。

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

    /// **ft_snapshot をまだ撮っていなければ1枚読んでから判定する**(§19 M4: snapshot 前の
    /// `tap (5000, -20)` が done になっていた)。読むのは直近の木が無いときだけ
    func testReadsOneSnapshotWhenNoneWasTakenAndThenRejects() async throws {
        do {
            _ = try await server.call(tool: "ft_tap", args: ["x": 5000.0, "y": -20.0])
            XCTFail("画面外の座標を撃ってはいけない")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("snapshot") }.count, 1, "\(driver.calls)")
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(x:") }, "\(driver.calls)")
        // 2回目は直近の木があるので読まない
        _ = try await server.call(tool: "ft_tap", args: ["x": 10.0, "y": 10.0])
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("snapshot") }.count, 1, "\(driver.calls)")
    }

    /// screen が 0(旧ブリッジ)のときだけ「分からない」= 撃つ
    func testStillFiresWhenTheScreenSizeIsZero() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 0, height: 0),
            elements: [], truncatedCount: 0)
        let result = try await server.call(tool: "ft_tap", args: ["x": 5000.0, "y": -20.0])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertTrue(text.contains("done"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap(x:") }, "\(driver.calls)")
    }

    /// **縁は外**(§19 M4): 390x844 の画面で (390, 844) は画素の外。原点 (0,0) と最後の画素は中
    func testTheFarEdgeIsOutsideAndTheOriginIsInside() async throws {
        try await takeSnapshot()
        do {
            _ = try await server.call(tool: "ft_tap", args: ["x": 390.0, "y": 844.0])
            XCTFail("縁ちょうどは画面外")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("outside the screen"), error.localizedDescription)
        }
        for point in [(0.0, 0.0), (389.0, 843.0)] {
            let result = try await server.call(tool: "ft_tap", args: ["x": point.0, "y": point.1])
            let text = try XCTUnwrap(result.first?["text"] as? String)
            XCTAssertTrue(text.contains("done"), text)
        }
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

    // MARK: - Android は iOS 専用の概念を名指ししない(§19.3 M5)

    /// in-app ブリッジの hit-test の仕組みは iOS(inapp/hybrid)だけの実態。Android の拒否に
    /// 混ざると、存在しない仕組みの説明になる
    func testAndroidOffscreenTapDoesNotMentionTheInAppEngine() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["platform": "android"])
        do {
            _ = try await server.call(tool: "ft_tap",
                                      args: ["platform": "android", "x": 5000.0, "y": -20.0])
            XCTFail("画面外の座標を撃ってはいけない")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                          error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("in-app engine"),
                           "Android の応答に iOS 専用の概念が混ざった: \(error.localizedDescription)")
        }
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

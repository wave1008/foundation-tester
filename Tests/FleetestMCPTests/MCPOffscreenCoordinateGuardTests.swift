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

    // MARK: - ft_pinch

    /// ft_pinch の座標形だけが門を通さず、画面外の中心で「pinch done」を返していた(負荷テスト:
    /// 実機 Pixel 4a で (-500,-800) が成功扱い。同じ座標の ft_tap は拒否)
    func testRejectsOffscreenPinchCentreEvenBeforeASnapshot() async throws {
        do {
            _ = try await server.call(tool: "ft_pinch", args: ["x": -500.0, "y": -800.0, "scale": 0.5])
            XCTFail("画面外の中心でピンチを撃ってはいけない")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("pinch") }, "\(driver.calls)")
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

    /// **終点も断る**(始点だけ門に通していた。ライブ操作の drag は両端を見る = 同じ座標が
    /// 一方でだけ断られていた)。絶対指定(toX/toY)と相対指定(dx/dy)の両方
    func testRejectsOffscreenDragEnd() async throws {
        try await takeSnapshot()
        for end in [["toX": 5000.0, "toY": 100.0], ["dx": 0.0, "dy": 2000.0]] {
            do {
                _ = try await server.call(tool: "ft_drag",
                                          args: ["fromX": 50.0, "fromY": 100.0].merging(end) { $1 })
                XCTFail("画面外の終点へ drag を撃ってはいけない: \(end)")
            } catch let error as MCPError {
                XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                              error.localizedDescription)
            }
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("drag(") }, "\(driver.calls)")
    }

    // MARK: - 座標の引数は1つ残らず門を通る(§56.6 の型: ツールは門を通すのに一部の引数が漏れる)

    /// スキーマの座標引数(点を表す数値)。**集合はスキーマから導出する**ので、座標を取る引数を
    /// 足すと下の表に行が無くて落ちる = 門を通し忘れた引数が黙って通らない
    private static let coordinateNames: Set<String> = ["x", "y", "fromX", "fromY", "toX", "toY", "dx", "dy"]

    /// (ツール, 引数) → その引数**だけ**を画面外(390x844 の外)にした呼び出し
    private static let offscreenCalls: [String: [String: Any]] = [
        "ft_tap.x": ["x": 5000.0, "y": 10.0],
        "ft_tap.y": ["x": 10.0, "y": 5000.0],
        "ft_double_tap.x": ["x": -1.0, "y": 10.0],
        "ft_double_tap.y": ["x": 10.0, "y": -1.0],
        "ft_long_press.x": ["x": 5000.0, "y": 10.0],
        "ft_long_press.y": ["x": 10.0, "y": 5000.0],
        "ft_pinch.x": ["x": -500.0, "y": 100.0, "scale": 0.5],
        "ft_pinch.y": ["x": 100.0, "y": -800.0, "scale": 0.5],
        "ft_drag.fromX": ["fromX": -50.0, "fromY": 100.0, "dx": 0.0, "dy": 10.0],
        "ft_drag.fromY": ["fromX": 50.0, "fromY": -100.0, "dx": 0.0, "dy": 10.0],
        "ft_drag.toX": ["fromX": 50.0, "fromY": 100.0, "toX": 5000.0, "toY": 100.0],
        "ft_drag.toY": ["fromX": 50.0, "fromY": 100.0, "toX": 50.0, "toY": 5000.0],
        "ft_drag.dx": ["fromX": 50.0, "fromY": 100.0, "dx": 5000.0],
        "ft_drag.dy": ["fromX": 50.0, "fromY": 100.0, "dy": 5000.0],
    ]

    func testEveryCoordinateArgumentInTheSchemaIsCovered() {
        var declared: Set<String> = []
        for tool in MCPServer.toolDefinitions {
            guard let name = tool["name"] as? String,
                  let schema = tool["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else { continue }
            for (key, value) in properties where Self.coordinateNames.contains(key) {
                guard (value as? [String: Any])?["type"] as? String == "number" else { continue }
                declared.insert("\(name).\(key)")
            }
        }
        XCTAssertGreaterThan(declared.count, 10, "座標引数をほとんど見つけていない — 走査が壊れている")
        XCTAssertEqual(declared, Set(Self.offscreenCalls.keys),
                       "座標を取る引数が増えた/減った。その引数を画面外にした呼び出しを offscreenCalls に足し、門を通すこと")
    }

    func testEveryCoordinateArgumentRejectsAnOffscreenValue() async throws {
        try await takeSnapshot()
        for (key, args) in Self.offscreenCalls.sorted(by: { $0.key < $1.key }) {
            let tool = String(key.prefix { $0 != "." })
            do {
                _ = try await server.call(tool: tool, args: args)
                XCTFail("\(key): 画面外の値で撃ってはいけない")
            } catch let error as MCPError {
                XCTAssertTrue(error.localizedDescription.contains("outside the screen"),
                              "\(key): \(error.localizedDescription)")
            }
        }
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

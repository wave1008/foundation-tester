// ft_* ツールの dispatch・引数検証・応答整形。
// ここが未検証だと、MCP から見て「引数を無視する」「別のドライバ操作を呼ぶ」「必須引数の欠落を
// 素通しする」といった退行が、スキーマ宣言のテスト(MCPServerToolDefinitionsTests)を緑のまま通る。

import XCTest
@testable import ftester_mcp

final class MCPToolCallTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake })
    }

    // MARK: - ドライバ操作へ正しく橋渡しされるか

    func testStatusRendersReadyDeviceAndSession() async throws {
        let content = try await server.call(tool: "ft_status", args: [:])
        XCTAssertEqual(driver.calls, ["status"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("iPhone 17"), text)
        XCTAssertTrue(text.contains("com.example.app"), text)
    }

    func testInstallPassesPackagePath() async throws {
        _ = try await server.call(tool: "ft_install", args: ["packagePath": "/tmp/A.app"])
        XCTAssertEqual(driver.calls, ["install(/tmp/A.app)"])
    }

    func testLaunchPassesBundleID() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.x"])
        XCTAssertEqual(driver.calls, ["launch(com.example.x)"])
    }

    /// snapshot は SnapshotRenderer の出力(ref・型・ラベル)をそのまま返す。
    /// ここが崩れるとエージェントは ref を読めず tap できない
    func testSnapshotReturnsRenderedElements() async throws {
        let content = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("[1]"), text)
        XCTAssertTrue(text.contains("ログイン"), text)
        XCTAssertTrue(text.contains("login_btn"), text)
    }

    func testTapByRef() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["ref": 3])
        XCTAssertEqual(driver.calls, ["tap(ref:3)"])
    }

    func testTapByCoordinates() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["x": 12.5, "y": 34.0])
        XCTAssertEqual(driver.calls, ["tap(x:12.5,y:34.0)"])
    }

    /// ref と x/y の両方が来たら ref を優先する(座標は snapshot 依存で古くなりうる)
    func testTapPrefersRefOverCoordinates() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["ref": 7, "x": 1.0, "y": 2.0])
        XCTAssertEqual(driver.calls, ["tap(ref:7)"])
    }

    func testTypeWithRef() async throws {
        _ = try await server.call(tool: "ft_type", args: ["text": "あいう", "ref": 2])
        XCTAssertEqual(driver.calls, ["type(ref:2,text:あいう)"])
    }

    /// ref 省略時は「フォーカス中の要素」= ref nil をドライバへ渡す
    func testTypeWithoutRefPassesNil() async throws {
        _ = try await server.call(tool: "ft_type", args: ["text": "hello"])
        XCTAssertEqual(driver.calls, ["type(ref:nil,text:hello)"])
    }

    func testSwipeParsesDirection() async throws {
        _ = try await server.call(tool: "ft_swipe", args: ["direction": "left"])
        XCTAssertEqual(driver.calls, ["swipe(left)"])
    }

    func testPressUsesDefaultDurationWhenOmitted() async throws {
        _ = try await server.call(tool: "ft_press", args: ["ref": 4])
        XCTAssertEqual(driver.calls, ["press(ref:4,duration:1.0)"])
    }

    func testPressPassesExplicitDuration() async throws {
        _ = try await server.call(tool: "ft_press", args: ["ref": 4, "duration": 2.5])
        XCTAssertEqual(driver.calls, ["press(ref:4,duration:2.5)"])
    }

    /// screenshot は text ではなく image コンテンツ(base64 + mimeType)で返す契約
    func testScreenshotReturnsBase64Image() async throws {
        let content = try await server.call(tool: "ft_screenshot", args: [:])
        let item = try XCTUnwrap(content.first)
        XCTAssertEqual(item["type"] as? String, "image")
        XCTAssertEqual(item["mimeType"] as? String, "image/png")
        XCTAssertEqual(item["data"] as? String, driver.screenshotData.base64EncodedString())
    }

    func testTerminate() async throws {
        _ = try await server.call(tool: "ft_terminate", args: [:])
        XCTAssertEqual(driver.calls, ["terminate"])
    }

    // MARK: - 必須引数の欠落・不正値

    /// **ドライバを呼ぶ前に**弾くこと(呼んでから失敗すると副作用が残る)
    func testMissingRequiredArgumentsThrowBeforeTouchingDriver() async {
        let cases: [(tool: String, args: [String: Any], expect: String)] = [
            ("ft_install", [:], "packagePath"),
            ("ft_launch", [:], "bundleId"),
            ("ft_type", [:], "text"),
            ("ft_press", [:], "ref"),
            ("ft_tap", [:], "ref か x/y"),
            ("ft_swipe", ["direction": "sideways"], "up/down/left/right"),
            ("ft_run_scenario", [:], "id"),
        ]
        for testCase in cases {
            do {
                _ = try await server.call(tool: testCase.tool, args: testCase.args)
                XCTFail("\(testCase.tool): 引数不足なのに成功した")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(testCase.expect),
                              "\(testCase.tool): 期待する語 \"\(testCase.expect)\" が"
                              + "エラー文に無い: \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(driver.calls, [], "引数不足でドライバに触れてはいけない")
    }

    /// x だけ / y だけの半端な座標は座標タップとして扱わない
    func testTapWithOnlyOneCoordinateIsRejected() async {
        for args in [["x": 1.0], ["y": 2.0]] as [[String: Any]] {
            do {
                _ = try await server.call(tool: "ft_tap", args: args)
                XCTFail("片方だけの座標が通った: \(args)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("ref か x/y"),
                              error.localizedDescription)
            }
        }
        XCTAssertEqual(driver.calls, [])
    }

    func testUnknownToolThrows() async {
        do {
            _ = try await server.call(tool: "ft_nope", args: [:])
            XCTFail("未知のツールが通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ft_nope"), error.localizedDescription)
        }
    }

    /// ドライバ側の失敗はそのまま投げ上げる(握り潰さない)。整形は handle 側の責務
    func testDriverFailurePropagates() async {
        driver.failing = ["tap"]
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
            XCTFail("ドライバの失敗が握り潰された")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tap"), error.localizedDescription)
        }
    }

    // MARK: - 宣言と実装の対応

    /// ドライバ操作系は空引数でも「未知のツール」にならない = dispatch が存在する。
    /// **プロジェクト系(下記 projectBackedTools)は呼ばない**: ft_list_scenarios は swift build を
    /// 起こし、ft_doctor は実 FM を叩くため(数秒〜分・環境依存)。そちらは名前の集合で担保する
    private static let driverBackedTools: Set<String> = [
        "ft_status", "ft_install", "ft_launch", "ft_snapshot", "ft_tap", "ft_type",
        "ft_swipe", "ft_press", "ft_screenshot", "ft_terminate",
    ]
    private static let projectBackedTools: Set<String> = [
        "ft_list_scenarios", "ft_run_scenario", "ft_list_projects", "ft_doctor",
    ]

    func testDriverBackedToolsAreAllDispatched() async {
        for name in Self.driverBackedTools {
            do {
                _ = try await server.call(tool: name, args: [:])
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("未知のツール"),
                               "\(name) は宣言されているが dispatch されていない")
            }
        }
    }

    /// **宣言と実装の対応表**。ツールを足したらここも更新することになり、そこで
    /// 「dispatch を書いたか」を意識する(宣言だけして `call` に case を書き忘れると、
    /// クライアントからは見えるのに呼ぶと必ず「未知のツール」で落ちる)
    func testDeclaredToolNamesMatchKnownSet() {
        let declared = Set(MCPServer.toolDefinitions.compactMap { $0["name"] as? String })
        XCTAssertEqual(declared, Self.driverBackedTools.union(Self.projectBackedTools),
                       "ツールの増減があります。dispatch(MCPServer.call)に case を足したうえで"
                       + "このテストの集合を更新すること")
    }
}

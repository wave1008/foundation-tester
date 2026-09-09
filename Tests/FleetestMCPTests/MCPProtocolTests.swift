// JSON-RPC 2.0 のエンベロープ(stdio 改行区切り)。クライアント(Claude Code)との唯一の接点で、
// ここが崩れると全ツールが使えなくなるが、ツール個別のテストでは一切カバーされない。

import XCTest
@testable import fleetest_mcp

final class MCPProtocolTests: XCTestCase {

    private var sent: [[String: Any]] = []
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        sent = []
        let capture: (Data) -> Void = { [weak self] data in
            // 応答は必ず1行1 JSON(改行終端)。ここを崩すとクライアントのパースが壊れる
            XCTAssertEqual(data.last, 0x0A, "応答が改行終端でない")
            let body = data.dropLast()
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                XCTFail("応答が JSON オブジェクトでない")
                return
            }
            self?.sent.append(object)
        }
        let fake = FakeDriver()
        server = MCPServer(write: capture, makeDriver: { _ in fake })
    }

    private func send(_ message: [String: Any]) async {
        await server.handle(message)
    }

    // MARK: - 行のパース(run のループが壊れた行で死なないこと)

    func testParseMessageRejectsUnusableLines() {
        XCTAssertNil(MCPServer.parseMessage(""))
        XCTAssertNil(MCPServer.parseMessage("これは JSON ではない"))
        XCTAssertNil(MCPServer.parseMessage("{\"unclosed\": "))
        XCTAssertNil(MCPServer.parseMessage("[1,2,3]"), "配列はメッセージではない")
        XCTAssertNil(MCPServer.parseMessage("42"))
    }

    func testParseMessageAcceptsObject() throws {
        let parsed = try XCTUnwrap(MCPServer.parseMessage(#"{"method":"ping","id":1}"#))
        XCTAssertEqual(parsed["method"] as? String, "ping")
    }

    // MARK: - メソッド

    func testInitializeAcceptsASupportedProtocolVersionAndAnnouncesTools() async throws {
        await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": ["protocolVersion": "2025-06-18"]])
        let result = try XCTUnwrap(sent.first?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18",
                       "対応している版を要求されたらその版を返すこと")
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"], "tools capability を名乗らないとツールが呼ばれない")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "fleetest")
    }

    /// 要求された版に対応していないときは**自分が対応する版**を返す(MCP の版交渉の規則)。
    /// 要求をそのまま echo すると、その版が必須にする挙動(2025-03-26 の JSON-RPC バッチ受信)を
    /// 名乗ったうえで parseMessage が配列を捨てる = バッチを送るクライアントが永久に待つ
    func testInitializeAnswersAnUnsupportedVersionWithItsOwnLatest() async throws {
        for requested in ["2025-03-26", "2099-01-01", "garbage"] {
            sent = []
            await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": ["protocolVersion": requested]])
            let result = try XCTUnwrap(sent.first?["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18",
                           "要求 \(requested) を echo してはいけない")
        }
    }

    func testInitializeWithoutAVersionAnswersTheLatestSupported() async throws {
        await send(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        let result = try XCTUnwrap(sent.first?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
    }

    /// 対応版の集合は**リテラルで固定**する(2025-03-26 を足すにはバッチ受信の実装が要る)
    func testSupportedProtocolVersionsArePinned() {
        XCTAssertEqual(MCPServer.supportedProtocolVersions, ["2024-11-05", "2025-06-18"])
    }

    func testPingRepliesEmptyResult() async throws {
        await send(["jsonrpc": "2.0", "id": 9, "method": "ping"])
        let reply = try XCTUnwrap(sent.first)
        XCTAssertEqual(reply["id"] as? Int, 9)
        XCTAssertNotNil(reply["result"])
    }

    func testToolsListReturnsAllDefinitions() async throws {
        await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let result = try XCTUnwrap(sent.first?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, MCPServer.toolDefinitions.count)
    }

    func testToolsCallWrapsContentAndMarksSuccess() async throws {
        await send(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": ["name": "ft_status", "arguments": [:]]])
        let result = try XCTUnwrap(sent.first?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertNotNil(result["content"] as? [[String: Any]])
    }

    /// **ツールの失敗は JSON-RPC の error ではなく isError:true の result** で返す契約
    /// (MCP 仕様。error にするとクライアントが接続異常として扱う)
    func testToolFailureIsReportedAsIsErrorResultNotRPCError() async throws {
        await send(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                    "params": ["name": "ft_launch", "arguments": [:]]])
        let reply = try XCTUnwrap(sent.first)
        XCTAssertNil(reply["error"], "ツールの失敗を RPC エラーにしてはいけない")
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("bundleId"), "原因が読めない: \(text)")
    }

    /// arguments 欠落は空辞書として扱う(クライアントによっては省略する)
    func testToolsCallWithoutArgumentsDoesNotCrash() async throws {
        await send(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                    "params": ["name": "ft_status"]])
        let result = try XCTUnwrap(sent.first?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func testUnknownMethodRepliesRPCError() async throws {
        await send(["jsonrpc": "2.0", "id": 6, "method": "resources/list"])
        let error = try XCTUnwrap(sent.first?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
        XCTAssertTrue((error["message"] as? String ?? "").contains("resources/list"))
    }

    /// **id なしは notification = 応答しない**。返すとクライアントが仕様違反として扱う
    func testNotificationsGetNoReply() async {
        await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        await send(["jsonrpc": "2.0", "method": "ping"])
        XCTAssertEqual(sent.count, 0)
    }

    /// id は数値以外(文字列)も来る。エコーバックできること
    func testStringIDIsEchoedBack() async throws {
        await send(["jsonrpc": "2.0", "id": "abc-1", "method": "ping"])
        XCTAssertEqual(sent.first?["id"] as? String, "abc-1")
    }

    func testEveryReplyCarriesJSONRPCVersion() async throws {
        await send(["jsonrpc": "2.0", "id": 1, "method": "ping"])
        await send(["jsonrpc": "2.0", "id": 2, "method": "nope"])
        XCTAssertEqual(sent.count, 2)
        for reply in sent {
            XCTAssertEqual(reply["jsonrpc"] as? String, "2.0")
        }
    }
}

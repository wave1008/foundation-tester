// JSON にできない応答を黙って捨てない(捨てるとクライアントは応答を永久に待つ。MCPServer.send 参照)。
// 名指しする場所が正しいことと、JSON にできる応答には何も言わないことを固定する

import XCTest
@testable import fleetest_mcp

final class MCPReplySerializationTests: XCTestCase {

    func testTheFirstNonJSONValueIsNamedByItsPath() {
        let reply: [String: Any] = ["id": 3, "result": ["content": [["type": "text", "text": "ok"],
                                                                    ["x": Double.nan]]]]
        XCTAssertEqual(MCPServer.firstNonJSONPath(reply, at: ""), ".result.content[1].x = nan")
        XCTAssertEqual(MCPServer.firstNonJSONPath(["id": 1, "result": ["when": Date(timeIntervalSince1970: 0)]], at: ""),
                       ".result.when (Date)")
        XCTAssertNil(MCPServer.firstNonJSONPath(["id": 1, "result": ["n": 1.5, "b": true, "s": "x", "z": NSNull()]], at: ""))
    }
}

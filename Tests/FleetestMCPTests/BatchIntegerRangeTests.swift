// エージェントの引数1つでサーバごと落ちない(trap しない)ことを守る。
// `UInt16.init` / `Int(Double)` は範囲外で実行時 trap = セッションの ft_* が全部消える。

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class BatchIntegerRangeTests: XCTestCase {

    func testPortArgumentRejectsOutOfRangeInsteadOfTrapping() {
        XCTAssertThrowsError(try MCPServer.portArgument(["port": 70000]))
        XCTAssertThrowsError(try MCPServer.portArgument(["port": -1]))
        XCTAssertThrowsError(try MCPServer.portArgument(["port": 0]))
        XCTAssertThrowsError(try MCPServer.portArgument(["port": "8123"]))
        XCTAssertEqual(try MCPServer.portArgument(["port": 8123]), 8123)
        XCTAssertEqual(try MCPServer.portArgument(["port": 65535]), 65535)
        XCTAssertNil(try MCPServer.portArgument([:]))
    }

    func testBatchIntegerKeysRejectValuesThatDoNotFitInInt() {
        for line in ["scrollDown repeat: 99999999999999999999",
                     "scrollDown repeat: 1e400",
                     "scrollDown repeat: 2.5"] {
            XCTAssertThrowsError(try resolve(command: "scrollDown", line: line), line) { error in
                let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
                XCTAssertTrue(message.contains("does not accept"), message)
            }
        }
        XCTAssertEqual(try resolve(command: "scrollDown", line: "scrollDown repeat: 3")["repeat"] as? Int, 3)
    }

    private func resolve(command: String, line: String) throws -> [String: Any] {
        let parsed = try BatchLineParser.parse(line)
        guard let info = DSLCommandIndex.all.first(where: { $0.name == command }),
              let builder = MCPServer.batchStepBuilders[command] else {
            throw BatchStepResolver.ResolveError(message: "test setup: unknown command \(command)")
        }
        return try BatchStepResolver.resolve(command: command, signature: info.signature,
                                             args: parsed.args, declaredKeys: builder.keys)
    }
}

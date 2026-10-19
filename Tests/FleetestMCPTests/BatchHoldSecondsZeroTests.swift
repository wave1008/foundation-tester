// `ft_batch` の `holdSeconds: 0` — DSL の既定(通常のタップ)を明示した正当な行が、ft_tap / ft_long_press と共有の
// 値域(0 を含まない)で断られていた。シナリオから写した行がバッチで通らない = 「通ったバッチは 1:1 で写せる」の逆向きの穴。

import XCTest
@testable import fleetest_mcp

final class BatchHoldSecondsZeroTests: XCTestCase {

    func testHoldSecondsZeroIsTheDSLDefaultAndPasses() {
        XCTAssertNoThrow(try MCPServer.checkBatchArgumentBounds(["selector": "#ok", "holdSeconds": 0.0], command: "tap"))
        XCTAssertNoThrow(try MCPServer.checkBatchArgumentBounds(["selector": "#ok", "holdSeconds": 0], command: "tap"))
    }

    func testOtherOutOfRangeValuesAreStillRefused() {
        XCTAssertThrowsError(try MCPServer.checkBatchArgumentBounds(["holdSeconds": -1.0], command: "tap"))
        XCTAssertThrowsError(try MCPServer.checkBatchArgumentBounds(["durationSeconds": 0.0], command: "swipeBy"))
    }
}

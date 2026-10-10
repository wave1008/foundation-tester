// ft_batch の waitForSettle: operation として受理され(DSLCommandIndex 由来の絞り込みを通る)、
// 値域の違反はデバイスに触れる前に断り、画面全体を撮れないエンジンでは executor の文言で失敗する。
// 引数の写像・書き戻しは BatchLineParserTests が持つ。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPBatchWaitForSettleTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    func testOutOfRangeQuietSecondsIsRejectedBeforeAnyDriverCall() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "waitForSettle quietSeconds: 0.05"])
            XCTFail("範囲外の quietSeconds が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("quietSeconds must be"), error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [], "弾いた手はドライバへ触れないこと")
    }

    /// 受理された(assertion / 未対応として断られていない)うえで、画面全体を撮れないドライバ(既定の 501)では
    /// executor の案内で失敗する
    func testAnEngineThatCannotCaptureTheWholeScreenFailsWithTheSwitchEngineAdvice() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "waitForSettle"])
            XCTFail("501 のドライバで waitForSettle が成功した")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("1. waitForSettle — FAILED"), message)
            XCTAssertTrue(message.contains("hybrid or xcuitest"), message)
        }
    }
}

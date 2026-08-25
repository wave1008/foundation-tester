// scrollTo の成功判定は StepExecutor.isSuccess の3形(passed/passedViaFallback/healed)を
// 使う。以前は `guard case .passed` だけを見ており、fallback 一致
// (primary が空振りして `||` の相手が当たった)を失敗として throw し、内部 enum の生ダンプ
// (`passedViaFallback(FTCore.FlowLocator(...))`)がそのままエラーメッセージに出ていた
// (実害: セレクタ "*立川に到着*||*到着*" で fallback 側が当たったのに失敗扱いになった)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPScrollToFallbackTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// primary が空振り・`||` の右辺(fallback)が当たる → 成功応答を返し、
    /// どちらで当たったかを本文に言う(内部 enum を出さない)。FakeDriver の既定 snapshot は
    /// #login_btn を持つので、primary #no_such_id は外れ fallback #login_btn が即座に当たる
    /// (スワイプなしで見つかる = 探索そのものはテストしない)
    func testFallbackMatchIsAScrollToSuccess() async throws {
        let text = body(try await server.call(tool: "ft_scroll_to",
                                              args: ["selector": "#no_such_id||#login_btn"]))
        XCTAssertTrue(text.contains("scrolled to"), text)
        XCTAssertTrue(text.contains("matched via the fallback"), text)
        XCTAssertFalse(text.contains("passedViaFallback("), text)
        XCTAssertFalse(text.contains("FlowLocator("), text)
    }

    /// 本物の失敗(何にも当たらない)でも enum の生ダンプを出さない(回帰ガード)。
    /// maxSwipes: 0 でスワイプなしの1周だけにして早く落とす
    func testGenuineFailureDoesNotDumpTheStatusEnum() async {
        do {
            _ = try await server.call(tool: "ft_scroll_to",
                                      args: ["selector": "#totally_missing_xyz", "maxSwipes": 0])
            XCTFail("見つからないはずのセレクタが成功した")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("passedViaFallback("), message)
            XCTAssertFalse(message.contains("FlowLocator("), message)
        }
    }
}

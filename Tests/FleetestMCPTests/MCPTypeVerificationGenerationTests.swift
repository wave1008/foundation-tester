// ft_type の検証の読み直し(verificationSnapshot)が新しい世代を採った後でも、
// 先に解いた ref の撃ち先(native)と再現セレクタが元の世代のままであること。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPTypeVerificationGenerationTests: XCTestCase {

    private func field(id: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: id, label: nil,
                    value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
    }

    private func tree(_ element: ElementInfo) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: [element], truncatedCount: 0)
    }

    /// clear-only + snapshotAfter: 検証の読み直しが顔ぶれの違う木(新世代)を採っても、
    /// tap は元の世代の native ref(1)を撃ち、再現セレクタも消えない
    func testClearOnlyTapAndSelectorSurviveAGenerationChangeDuringVerification() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = tree(field(id: "search_box"))
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        // 1枚目 = verifiedRef の撮り直し(同じ木)・以降 = 検証の読み直し(別の顔ぶれ)
        driver.scriptedSnapshots = [tree(field(id: "search_box")), tree(field(id: "other_box"))]
        let result = try await server.call(
            tool: "ft_type", args: ["ref": 1, "text": "", "replace": true, "snapshotAfter": true])
        let text = result.compactMap { $0["text"] as? String }.joined()

        XCTAssertTrue(driver.calls.contains("tap(ref:1)"),
                      "tap が新世代の base で引き直された: \(driver.calls)")
        XCTAssertTrue(text.contains("search_box"), "再現セレクタが消えた: \(text)")
    }
}

final class MCPGoneUnderKeyboardTests: XCTestCase {

    private func field(id: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: id, label: nil,
                    value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 700, width: 200, height: 40), depth: 1)
    }

    func testGoneMessageNamesTheKeyboardOnlyWhenItIsShown() {
        let target = field(id: "submit_btn")
        let withKeyboard = RefGuard.goneMessage(ref: 3, target: target, keyboardShown: true)
        XCTAssertTrue(withKeyboard.contains("keyboard"), withKeyboard)
        let without = RefGuard.goneMessage(ref: 3, target: target)
        XCTAssertFalse(without.contains("keyboard"), without)
        XCTAssertTrue(without.contains("the screen changed"), without)
    }

    /// 配線: キーボードを申告する木から要素が消えた ft_tap は、キーボードを名指しして断る
    func testTapOfAnElementGoneWhileKeyboardIsUpNamesTheKeyboard() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let screen = FTRect(x: 0, y: 0, width: 390, height: 844)
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [field(id: "submit_btn")], truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen, elements: [], truncatedCount: 0,
            keyboardFrame: FTRect(x: 0, y: 500, width: 390, height: 344))
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
            XCTFail("tap should be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("keyboard") || error.localizedDescription.contains("keyboard"),
                          "\(error)")
        }
    }
}

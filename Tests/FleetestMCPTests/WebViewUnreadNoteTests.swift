// webViewUnreadNote(申告 `webViewPath == dom-unread` の木 = WebView の中身を1つも読めていない。
// F25: Android の非 debuggable 実機で DOM が読めない事実が stderr にしか出ず、MCP の応答に無かった)。
// コーパスに置けない(NoteCoverageTests.knownSilent の当該コメント)ので両方向をここで固定する。

import XCTest
@testable import fleetest_mcp
import FTCore

final class WebViewUnreadNoteTests: XCTestCase {

    private func snapshot(path: String?, note: String? = nil) -> SnapshotResponse {
        let webView = ElementInfo(ref: 1, type: "webView", identifier: "web", label: nil, value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 200, width: 1080, height: 1800), depth: 1)
        var response = SnapshotResponse(sessionBundleID: "com.example.app",
                                        screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                                        elements: [webView], truncatedCount: 0, webViewPath: path)
        response.note = note
        return response
    }

    func testFiresOnDomUnreadAndQuotesTheBridgeNote() {
        let note = MCPServer.webViewUnreadNote(snapshot(
            path: WebViewPath.domUnread,
            note: "com.example.app's WebView content could not be read: the devtools socket never opens"))
        XCTAssertTrue(note.hasPrefix("note: the WebView contents could not be read"), note)
        XCTAssertTrue(note.contains("Why: com.example.app's WebView content could not be read"), note)
        XCTAssertTrue(note.contains("ft_screenshot"), "次の一手まで書くこと: \(note)")
    }

    /// note の無い申告(旧ブリッジ)でも事実だけは言う
    func testFiresWithoutANote() {
        let note = MCPServer.webViewUnreadNote(snapshot(path: WebViewPath.domUnread))
        XCTAssertTrue(note.contains("could not be read"), note)
        XCTAssertFalse(note.contains("Why:"), note)
    }

    /// 陰性: DOM が読めた木・申告の無い木では黙る(webView 要素の有無から推測しない)
    func testStaysSilentWhenTheDOMWasReadOrNothingWasDeclared() {
        XCTAssertEqual(MCPServer.webViewUnreadNote(snapshot(path: WebViewPath.dom)), "")
        XCTAssertEqual(MCPServer.webViewUnreadNote(snapshot(path: WebViewPath.delegatedEmpty)), "")
        XCTAssertEqual(MCPServer.webViewUnreadNote(snapshot(path: nil)), "")
    }
}

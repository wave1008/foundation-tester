// addressBarNote(ブラウザのアドレス欄の値を名指しする。2026-08-12・作業3)。
//
// なぜ要るか: 同じ URL を渡しても iOS Safari と Android Chrome で別のページ(フル版 / lite 版)が
// 開くことがあり、木の中身も別物になるが、応答のどこにもそのことに気付く手掛かりが無かった。

import XCTest
@testable import ftester_mcp
import FTCore

final class AddressBarNoteTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil,
                         value: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 2)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1000, height: 2000),
                         elements: elements, truncatedCount: 0)
    }

    // MARK: - 発火する形

    func testFiresWithAndroidChromeURLBar() {
        let snapshot = tree([
            element(1, "webView", label: "page"),
            element(2, "textField", id: "url_bar", value: "tenki.jp/lite/week/3/16/"),
        ])
        let note = MCPServer.addressBarNote(snapshot)
        XCTAssertTrue(note.contains("\"tenki.jp/lite/week/3/16/\""), note)
        XCTAssertTrue(note.contains("ft_screenshot"), note)
    }

    func testFiresWithIOSSafariTabBarItemTitle() {
        let snapshot = tree([
            element(1, "webView", label: "page"),
            element(2, "textField", id: "TabBarItemTitle", label: "アドレス", value: "en.wikipedia.org"),
        ])
        XCTAssertTrue(MCPServer.addressBarNote(snapshot).contains("\"en.wikipedia.org\""))
    }

    /// **不可視文字を落として引用する**(2026-08-12実測): iOS 実機の値には先頭に
    /// U+200E(LEFT-TO-RIGHT MARK)が付く。素の値をそのまま引用すると読み手には
    /// 同じ文字に見えるのに選択・比較が食い違う
    func testQuotesTheCleanedValueWithoutTheInvisibleMark() {
        let snapshot = tree([
            element(1, "webView", label: "page"),
            element(2, "textField", id: "TabBarItemTitle", value: "\u{200E}weather.yahoo.co.jp"),
        ])
        let note = MCPServer.addressBarNote(snapshot)
        XCTAssertTrue(note.contains("\"weather.yahoo.co.jp\""), note)
        XCTAssertFalse(note.contains("\u{200E}"), note)
    }

    // MARK: - 発火しない形

    func testStaysSilentWithoutAWebView() {
        let snapshot = tree([element(1, "textField", id: "url_bar", value: "example.com")])
        XCTAssertEqual(MCPServer.addressBarNote(snapshot), "")
    }

    func testStaysSilentWithoutAnAddressBarElement() {
        let snapshot = tree([
            element(1, "webView", label: "page"),
            element(2, "staticText", label: "some other text"),
        ])
        XCTAssertEqual(MCPServer.addressBarNote(snapshot), "")
    }

    func testStaysSilentWhenTheAddressBarValueIsEmpty() {
        let snapshot = tree([
            element(1, "webView", label: "page"),
            element(2, "textField", id: "url_bar", value: nil),
        ])
        XCTAssertEqual(MCPServer.addressBarNote(snapshot), "")
    }

    /// **知らないブラウザでは黙る**(2026-08-12 のレビューでフォールバックを撤去)。
    /// 「値が URL らしい textField」で拾うと、WebView を載せたアプリの入力欄
    /// (メール・住所)を「アドレス欄」と名乗る —— その形はコーパスに1枚も無いので
    /// 誤検知0の確認が効かない。**identifier で名前が分かるものだけ**を拾う
    func testStaysSilentForATextFieldThatMerelyLooksLikeAURL() {
        let snapshot = tree([
            element(1, "webView", label: "page"),
            element(2, "textField", id: "email_field", value: "someone@example.com"),
            element(3, "textField", id: "site_field", value: "https://example.com/a"),
        ])
        XCTAssertEqual(MCPServer.addressBarNote(snapshot), "")
    }
}

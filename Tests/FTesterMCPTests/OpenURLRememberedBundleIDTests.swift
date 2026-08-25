// ft_open_url が bundleId を省略されたとき「このセッションで最後に ft_launch したアプリ」を
// 既定にすることの開示。
//
// 素の "Delivered <url> to <bundleID>." は**利用者が渡した宛先の確認**と字面が同じで、
// 読み手は自分が指定していないことに気付けない。Android では bundleID が intent の宛先
// そのものなので、その間に別アプリへ移っていれば裏に居るアプリが叩き起こされる。

import XCTest
@testable import ftester_mcp

final class OpenURLRememberedBundleIDTests: XCTestCase {

    func testExplicitBundleIDIsReportedWithoutAnyInference() {
        let summary = MCPServer.openURLSummary(
            url: "https://example.com", bundleID: "com.example.app",
            bundleIDWasRemembered: false, snapshotAfter: false)
        XCTAssertTrue(summary.contains("to com.example.app"), summary)
        XCTAssertFalse(summary.contains("not given"),
                       "明示された bundleId に推測の断りが付いた: \(summary)")
    }

    func testRememberedBundleIDSaysItWasNotGiven() {
        let summary = MCPServer.openURLSummary(
            url: "https://example.com", bundleID: "com.example.app",
            bundleIDWasRemembered: true, snapshotAfter: false)
        XCTAssertTrue(summary.contains("not given"), summary)
        XCTAssertTrue(summary.contains("ft_launch"),
                      "どこから来た宛先なのかが書かれていない: \(summary)")
    }

    /// 宛先そのものが無いとき(ft_launch も無い)は、推測の断りを出す相手が居ない
    func testNoBundleIDMeansNoInferenceClause() {
        let summary = MCPServer.openURLSummary(
            url: "https://example.com", bundleID: nil,
            bundleIDWasRemembered: true, snapshotAfter: false)
        XCTAssertFalse(summary.contains("not given"), summary)
        XCTAssertTrue(summary.hasPrefix("Delivered https://example.com."), summary)
    }

    /// snapshotAfter の有無で出し分ける従来の分岐は保つ(木を返すのに撃ち直せとは言わない)
    func testRememberedClauseSurvivesTheSnapshotAfterBranch() {
        let withTree = MCPServer.openURLSummary(
            url: "https://example.com", bundleID: "com.example.app",
            bundleIDWasRemembered: true, snapshotAfter: true)
        XCTAssertTrue(withTree.contains("not given"), withTree)
        XCTAssertTrue(withTree.contains("the tree below"), withTree)
    }
}

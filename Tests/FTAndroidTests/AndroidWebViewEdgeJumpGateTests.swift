// CDP の端送り(`AndroidWebViewDOM.shouldJumpToEdge` / `ScrollJump`)の門。
// 木に webView が無いのに撃つと、保持された裏の WebView を動かして true を返し、ネイティブのリストが送られない。

import XCTest
@testable import FTAndroid

final class AndroidWebViewEdgeJumpGateTests: XCTestCase {

    func testDoesNotFireWithoutAWebViewInTheLastTree() {
        XCTAssertFalse(AndroidWebViewDOM.shouldJumpToEdge(
            treeHasWebView: false, unavailableFor: nil, package: "com.example"))
        XCTAssertTrue(AndroidWebViewDOM.shouldJumpToEdge(
            treeHasWebView: true, unavailableFor: nil, package: "com.example"))
    }

    func testUnavailablePackageIsNotRetriedButAnotherIs() {
        XCTAssertFalse(AndroidWebViewDOM.shouldJumpToEdge(
            treeHasWebView: true, unavailableFor: "com.example", package: "com.example"))
        XCTAssertTrue(AndroidWebViewDOM.shouldJumpToEdge(
            treeHasWebView: true, unavailableFor: "com.other", package: "com.example"))
    }

    /// 「none」(スクロール余地なし)は手段の無効化ではない = `.unavailable` と別の値
    func testNoRoomIsDistinctFromUnavailable() {
        XCTAssertNotEqual(AndroidWebViewDOM.ScrollJump.noRoom, .unavailable)
        XCTAssertNotEqual(AndroidWebViewDOM.ScrollJump.jumped(moved: false), .unavailable)
    }

    /// AndroidDriver の分岐の配線(ソース走査): 無効化は `.unavailable` だけ・前面は sessionBundleID 側
    func testDriverDisablesOnlyOnUnavailableAndUsesSnapshotForeground() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTAndroid/AndroidDriver.swift"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertTrue(code.contains("case .unavailable:\n            webViewEdgeJumpUnavailableFor = package"))
        XCTAssertTrue(code.contains("case .noRoom:\n            return false"))
        XCTAssertTrue(code.contains("lastTreeForegroundPackage = snapshot.sessionBundleID ?? currentPackage"))
        XCTAssertTrue(code.contains("AndroidWebViewDOM.shouldJumpToEdge("))
        XCTAssertTrue(code.contains("WebViewDOM.hasMultipleWebViews(in: snapshot.elements)"))
        XCTAssertTrue(code.contains("WebViewDOM.isUsable(payload)"))
        XCTAssertTrue(code.contains("WebViewDOM.disclosing("))
    }
}

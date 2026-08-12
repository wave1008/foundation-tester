// ブラウザ画面で「一覧をそのまま信じてよいか」を言う2本の注記。
//
// どちらも 2026-08-12 のブラウザ監査で実測した形を固定する:
//   webViewGapNote  … Android の Chrome が web コンテンツを部分的にしか公開せず、
//                      画面に描かれている表・本文がフルツリーにも1つも無かった
//   urlishLabelsNote … アクセシブルな名前を持たないリンクに Chrome が URL を入れ、
//                      「千代田区」が "13101"、広告が "details%3Fid%3D…" として並んだ
//
// **閾値は固定コーパスの実測で決めた**(MCPServer.webViewGapNote のコメント)。ここでは
// その両側 —— 空き帯のあるツリーと、埋まっているツリー —— を最小形で押さえる。

import XCTest
@testable import ftester_mcp
import FTCore

final class WebTreeNoteTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, _ label: String?,
                         y: Double, height: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 1000, height: height), depth: 2)
    }

    /// webView 1つ + 指定した y 位置の葉、というだけの木
    private func tree(leafYs: [Double], leafHeight: Double = 40) -> SnapshotResponse {
        var elements = [element(1, "webView", "page", y: 0, height: 2000)]
        for (i, y) in leafYs.enumerated() {
            elements.append(element(i + 2, "staticText", "row \(i)", y: y, height: leafHeight))
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 1000, height: 2000),
                                elements: elements, truncatedCount: 0)
    }

    // MARK: - webViewGapNote

    /// 中ほどに 800pt(容器の 40%)の空白がある = 木が落としている疑い
    func testAWideInteriorGapIsReported() {
        let snapshot = tree(leafYs: [0, 100, 200, 300, 1200, 1400, 1600, 1800])
        let note = MCPServer.webViewGapNote(snapshot)
        XCTAssertTrue(note.contains("nothing is listed between"), note)
        XCTAssertTrue(note.contains("ft_screenshot"), "確かめる手段まで書くこと: \(note)")
    }

    /// 一様に埋まっていれば黙る(**誤検知0が使い物になる条件**)
    func testAnEvenlyFilledTreeIsSilent() {
        let ys = stride(from: 0.0, to: 2000.0, by: 50.0).map { $0 }
        XCTAssertEqual(MCPServer.webViewGapNote(tree(leafYs: ys)), "")
    }

    /// **端の余白は数えない**: 先頭が空いているだけのページ(iOS Safari の実測はすべてこの形)で
    /// 出してしまうと、健全な木を毎回疑うことになる
    func testPaddingAtTheTopOrBottomIsNotReported() {
        let ys = stride(from: 600.0, to: 1400.0, by: 50.0).map { $0 }
        XCTAssertEqual(MCPServer.webViewGapNote(tree(leafYs: ys)), "",
                       "上下端に接する空白は容器の余白であって取りこぼしの証拠ではない")
    }

    /// webView が無い画面(ネイティブのみ)では判定自体を行わない
    func testNativeScreensAreNotConsidered() {
        let native = SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1000, height: 2000),
            elements: [element(1, "button", "OK", y: 100, height: 40)], truncatedCount: 0)
        XCTAssertEqual(MCPServer.webViewGapNote(native), "")
    }

    // MARK: - urlishLabelsNote

    func testPercentEncodedAndQueryAndHashLabelsAreReported() {
        for label in ["details%3Fid%3Dcom.example.app%26inline%3Dtrue",
                      "zoomradar?adjust_t=66qs2tg&adjust_deeplink=x",
                      "dc2557a17fdf039c74261b0b5da109ec",
                      "https://example.com/a/b"] {
            XCTAssertTrue(MCPServer.looksLikeURLFragment(label), "URL 断片と判定されるべき: \(label)")
        }
    }

    /// **本文と紛れる形は拾わない**(誤検知の害のほうが大きい)。とくに数字だけの
    /// ラベルは気温・件数と区別が付かない
    func testOrdinaryTextIsNotMistakenForAURL() {
        for label in ["千代田区", "13101", "30℃[0]", "8月12日(水) 19時00分発表",
                      "50%OFF", "Sale 50% off today", nil, "a=b"] {
            XCTAssertFalse(MCPServer.looksLikeURLFragment(label),
                           "本文として扱われるべき: \(label ?? "nil")")
        }
    }

    /// 百分率エンコードの**境界は「2つ以上」**。1つで断じると、たまたま `%` の後ろに
    /// 16進2文字が続く本文(`100%AB` のような表記・16進色の並び)を URL と誤読する。
    /// URL 断片の側は必ず複数出るので、2 で取りこぼさない
    func testASinglePercentEscapeIsNotEnough() {
        XCTAssertFalse(MCPServer.looksLikeURLFragment("cost 100%AB total"),
                       "%XX が1つだけなら本文の可能性が高い")
        XCTAssertTrue(MCPServer.looksLikeURLFragment("cost 100%AB%CD total"),
                      "%XX が2つ並べば URL 断片")
    }

    func testTheNoteNamesTheRefsAndForbidsUsingThemAsContent() {
        let snapshot = SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1000, height: 2000),
            elements: [element(1, "link", "details%3Fid%3Dcom.example%26x%3D1", y: 10, height: 40)],
            truncatedCount: 0)
        let note = MCPServer.urlishLabelsNote(snapshot)
        XCTAssertTrue(note.contains("[1]"), note)
        XCTAssertTrue(note.contains("not the text drawn on"), note)
    }
}

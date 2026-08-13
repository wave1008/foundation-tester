// Android の WebView を DOM から読む経路の純粋ロジック(`AndroidWebViewDOM`。2026-08-13)。
//
// 実機の witness: `android.webkit.WebView` は `<table>` のセルを a11y へ**1つも公開しない**
// (4 SUT で実測)。同じ JS を CDP 経由で走らせると iOS と同じ木になり、
// **まったく同じ1行 `scrollTo '8/15'` が両 OS で通る**(DOM 経路なしの Android だけ落ちる)。
//
// I/O(adb / CDP)はデバイスが要るのでここでは触らない。守るのは
// **別アプリを読まないこと**と**座標の写し**の2つ。

import XCTest
import FTCore
@testable import FTAndroid

final class AndroidWebViewDOMTests: XCTestCase {

    // MARK: - ソケットの選択(**別アプリの DOM を読まない**)

    private static let procNetUnix = """
    0000000000000000: 00000002 00000000 00010000 0001 01 451895 @webview_devtools_remote_21584
    0000000000000000: 00000002 00000000 00010000 0001 01 322358 @chrome_devtools_remote
    0000000000000000: 00000002 00000000 00010000 0001 01 528452 @webview_devtools_remote_10040
    0000000000000000: 00000002 00000000 00010000 0001 01 111111 @some_other_socket
    """

    func testPicksTheSocketOfTheGivenPid() {
        XCTAssertEqual(AndroidWebViewDOM.socketName(procNetUnix: Self.procNetUnix, pid: 21584),
                       "webview_devtools_remote_21584")
        XCTAssertEqual(AndroidWebViewDOM.socketName(procNetUnix: Self.procNetUnix, pid: 10040),
                       "webview_devtools_remote_10040")
    }

    /// **pid が違えば選ばない**。端末には他アプリの WebView ソケットが並ぶので、
    /// ここで妥協すると**別アプリの DOM を自分の木へ混ぜる**
    func testDoesNotPickAnotherAppsSocket() {
        XCTAssertNil(AndroidWebViewDOM.socketName(procNetUnix: Self.procNetUnix, pid: 999))
    }

    /// 前方一致で拾わない(`_2158` が `_21584` に一致してはいけない)
    func testDoesNotMatchOnAPrefix() {
        XCTAssertNil(AndroidWebViewDOM.socketName(procNetUnix: Self.procNetUnix, pid: 2158))
    }

    /// Chrome のソケットは WebView のものではない(混同すると別ブラウザを読む)
    func testIgnoresTheChromeSocket() {
        XCTAssertNil(AndroidWebViewDOM.socketName(procNetUnix: "@chrome_devtools_remote", pid: 1))
    }

    // MARK: - ページの選択

    func testPicksTheFirstPageTarget() {
        let ws = AndroidWebViewDOM.pickPage([
            ["type": "service_worker", "webSocketDebuggerUrl": "ws://sw"],
            ["type": "page", "url": "about:blank", "webSocketDebuggerUrl": "ws://page"],
        ])
        XCTAssertEqual(ws, "ws://page")
    }

    /// **about:blank を捨てない**: `loadDataWithBaseURL` で読ませた画面は url がこれになる(実測)
    func testAboutBlankIsAValidPage() {
        XCTAssertEqual(AndroidWebViewDOM.pickPage(
            [["type": "page", "url": "about:blank", "webSocketDebuggerUrl": "ws://x"]]), "ws://x")
    }

    func testSkipsDevtoolsOwnPagesAndMissingSockets() {
        XCTAssertNil(AndroidWebViewDOM.pickPage([
            ["type": "page", "url": "devtools://devtools/x", "webSocketDebuggerUrl": "ws://d"],
            ["type": "page", "url": "http://a", "webSocketDebuggerUrl": ""],
        ]))
    }

    // MARK: - 座標の写し(CSS px → 物理 px)

    private func payload(x: Double, y: Double, scale: Double = 1,
                         offsetLeft: Double = 0, offsetTop: Double = 0) -> WebViewDOM.Payload {
        let json = """
        {"readyState":"complete",
         "viewport":{"offsetLeft":\(offsetLeft),"offsetTop":\(offsetTop),"scale":\(scale),
                     "width":360,"height":640},
         "crossOriginFrames":0,
         "nodes":[{"role":"staticText","label":"8/15","x":\(x),"y":\(y),
                   "width":56,"height":45,"enabled":true}]}
        """
        return try! WebViewDOM.decode(json)
    }

    /// **density 倍して WebView の原点を足す**。ここを間違えるとタップが画面外や別の行へ飛ぶ
    func testMapsCssPixelsOntoTheScreen() {
        // **原点は x も y も 0 にしない**(2026-08-13): x=0 で書いたら「x の原点を足し忘れる」
        // 変異が生き残った —— 片方が 0 の座標テストは、その軸を1つも守っていない
        let frame = FTRect(x: 24, y: 142, width: 1080, height: 1500)
        let els = AndroidWebViewDOM.elements(payload: payload(x: 16, y: 595),
                                             webViewFrame: frame, density: 3, startingRef: 7)
        XCTAssertEqual(els.count, 1)
        let e = els[0]
        XCTAssertEqual(e.ref, 7)
        XCTAssertEqual(e.label, "8/15")
        XCTAssertEqual(e.frame.x, 24 + 48, accuracy: 0.001)         // 24 + 16 * 3
        XCTAssertEqual(e.frame.y, 142 + 1785, accuracy: 0.001)      // 142 + 595 * 3
        XCTAssertEqual(e.frame.width, 168, accuracy: 0.001)
        XCTAssertEqual(e.web, true, "web の印が無いと OS で扱いが割れる")
    }

    /// ピンチ中は visualViewport の offset/scale を通す(iOS と同じ規約を共有している)
    func testHonoursTheVisualViewport() {
        let els = AndroidWebViewDOM.elements(
            payload: payload(x: 20, y: 100, scale: 2, offsetLeft: 10, offsetTop: 50),
            webViewFrame: FTRect(x: 0, y: 0, width: 1080, height: 1500),
            density: 1, startingRef: 1)
        XCTAssertEqual(els[0].frame.x, 20, accuracy: 0.001)   // (20-10)*2
        XCTAssertEqual(els[0].frame.y, 100, accuracy: 0.001)  // (100-50)*2
    }

    /// 潰れた要素は落とす(a11y 側の規約と揃える)
    func testDropsZeroSizedNodes() {
        let json = """
        {"viewport":{"offsetLeft":0,"offsetTop":0,"scale":1,"width":360,"height":640},
         "nodes":[{"role":"staticText","label":"x","x":0,"y":0,"width":0,"height":10}]}
        """
        let els = AndroidWebViewDOM.elements(payload: try! WebViewDOM.decode(json),
                                             webViewFrame: FTRect(x: 0, y: 0, width: 10, height: 10),
                                             density: 1, startingRef: 1)
        XCTAssertTrue(els.isEmpty)
    }

    // MARK: - 差し込み先の WebView

    func testPicksTheLargestWebView() {
        let small = ElementInfo(ref: 1, type: "webView", identifier: nil, label: nil, value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        let big = ElementInfo(ref: 2, type: "webView", identifier: nil, label: nil, value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 100, width: 1080, height: 900), depth: 1)
        XCTAssertEqual(AndroidWebViewDOM.webViewFrame(in: [small, big])?.height, 900)
    }

    func testNoWebViewMeansNoInjection() {
        let native = ElementInfo(ref: 1, type: "button", identifier: "ok", label: "OK", value: nil,
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        XCTAssertNil(AndroidWebViewDOM.webViewFrame(in: [native]))
    }
}

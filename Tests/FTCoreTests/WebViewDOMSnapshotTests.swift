// WKWebView の DOM 走査経路のうち、デバイス無しで固められる部分の固定。
// デバイスが要るのは「JS が実際に何を返すか」だけで、JSON の写像・座標変換・型語彙はここで守る。

import XCTest
@testable import FTCore

final class WebViewDOMSnapshotTests: XCTestCase {

    /// evaluateJavaScript は**式**を要求する。IIFE の形が崩れると実機でだけ落ちる
    /// (ホスト側のテストが無いと気付けない)ので形だけ固定する
    func testJavaScriptIsSelfContainedExpression() {
        let js = WebViewDOM.javaScript
        XCTAssertTrue(js.hasPrefix("(function"), "IIFE で始まること")
        XCTAssertTrue(js.hasSuffix("})()"), "IIFE で終わること")
        // 可視性判定の要(これが消えると画面に出ていない要素がセレクタに引っかかる)
        XCTAssertTrue(js.contains("elementFromPoint"))
        XCTAssertTrue(js.contains("getComputedStyle"))
        XCTAssertTrue(js.contains("visualViewport"))
        // Swift の複数行文字列で `\s` が `\\s` に化けていないこと(化けると JS が正規表現を誤解する)
        XCTAssertTrue(js.contains(#"replace(/\s+/g, " ")"#))
        XCTAssertFalse(js.contains(#"\\s+"#))
    }

    func testDecodePayload() throws {
        let json = """
        {"readyState":"complete",
         "viewport":{"offsetLeft":0,"offsetTop":0,"scale":1,"width":390,"height":600},
         "crossOriginFrames":2,
         "nodes":[{"role":"link","label":"リンク","x":16,"y":20,"width":100,"height":22,"enabled":true},
                  {"role":"textField","placeholder":"入力","value":"abc","x":16,"y":60,"width":300,"height":44,"enabled":false}]}
        """
        let payload = try WebViewDOM.decode(json)
        XCTAssertEqual(payload.readyState, "complete")
        XCTAssertEqual(payload.crossOriginFrames, 2)
        XCTAssertEqual(payload.nodes?.count, 2)
        XCTAssertEqual(payload.nodes?[0].role, "link")
        XCTAssertEqual(payload.nodes?[1].placeholder, "入力")
        XCTAssertEqual(payload.nodes?[1].value, "abc")
        XCTAssertEqual(payload.nodes?[1].enabled, false)
        XCTAssertNil(payload.error)
    }

    /// JS 側が例外になったときは error だけが返る(呼び出し側は XCUITest へ落とす)
    func testDecodeErrorPayload() throws {
        let payload = try WebViewDOM.decode(#"{"error":"TypeError: x is not a function"}"#)
        XCTAssertNotNil(payload.error)
        XCTAssertNil(payload.nodes)
        XCTAssertNil(payload.viewport)
    }

    /// 未ズーム(scale=1・offset=0)は CSS px がそのまま pt になる
    func testLocalRectWithoutZoom() {
        let viewport = WebViewDOM.Viewport(offsetLeft: 0, offsetTop: 0, scale: 1,
                                           width: 390, height: 600)
        let node = WebViewDOM.Node(role: "button", label: "送信", value: nil, placeholder: nil,
                                   x: 16, y: 100, width: 80, height: 44, enabled: true, checked: nil)
        let rect = WebViewDOM.localRect(node, viewport: viewport)
        XCTAssertEqual(rect.x, 16)
        XCTAssertEqual(rect.y, 100)
        XCTAssertEqual(rect.width, 80)
        XCTAssertEqual(rect.height, 44)
    }

    /// ピンチズーム中は visualViewport の offset を引いてから scale を掛ける。
    /// 順序を逆にすると**ズーム時だけ**タップ座標がずれる(デバイス上でしか気付けない類の事故)
    func testLocalRectWithPinchZoom() {
        let viewport = WebViewDOM.Viewport(offsetLeft: 10, offsetTop: 20, scale: 2,
                                           width: 195, height: 300)
        let node = WebViewDOM.Node(role: "staticText", label: "見出し", value: nil, placeholder: nil,
                                   x: 30, y: 60, width: 100, height: 20, enabled: true, checked: nil)
        let rect = WebViewDOM.localRect(node, viewport: viewport)
        XCTAssertEqual(rect.x, 40)    // (30 - 10) * 2
        XCTAssertEqual(rect.y, 80)    // (60 - 20) * 2
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 40)
    }

    /// scale=0(未定義な値が来たとき)で矩形を潰さない
    func testLocalRectTreatsZeroScaleAsIdentity() {
        let viewport = WebViewDOM.Viewport(offsetLeft: 0, offsetTop: 0, scale: 0,
                                           width: 390, height: 600)
        let node = WebViewDOM.Node(role: "button", label: nil, value: nil, placeholder: nil,
                                   x: 5, y: 5, width: 10, height: 10, enabled: true, checked: nil)
        let rect = WebViewDOM.localRect(node, viewport: viewport)
        XCTAssertEqual(rect.width, 10)
        XCTAssertEqual(rect.height, 10)
    }

    /// 型語彙は既存の契約と同じ綴り(ホスト側が先頭小文字へ畳む)。
    /// 未知のロールは**落とす**(Other にすると容器を掴んでしまう)
    func testTypeNameMapping() {
        XCTAssertEqual(WebViewDOM.typeName(role: "link"), "Link")
        XCTAssertEqual(WebViewDOM.typeName(role: "button"), "Button")
        XCTAssertEqual(WebViewDOM.typeName(role: "staticText"), "StaticText")
        XCTAssertEqual(WebViewDOM.typeName(role: "textField"), "TextField")
        XCTAssertEqual(WebViewDOM.typeName(role: "secureTextField"), "SecureTextField")
        XCTAssertNil(WebViewDOM.typeName(role: "div"))
        XCTAssertNil(WebViewDOM.typeName(role: ""))
    }

    /// ブリッジが返す綴りは ElementInfo が先頭小文字へ畳む = セレクタ `.link` と一致する
    func testTypeNameNormalizesToSelectorSpelling() {
        for role in ["link", "button", "staticText", "textField", "secureTextField"] {
            let type = WebViewDOM.typeName(role: role)!
            XCTAssertEqual(ElementInfo.normalizedType(type), role)
        }
    }

    // MARK: - interop 判定(実測した祖先チェーンをそのまま使う)

    /// SwiftUI ネイティブ。`UIKitPlatformViewHost` は名前に "PlatformView" を含むので、
    /// 目印を雑に "PlatformView" にすると**ここが誤判定**して DOM 経路が死ぬ
    func testNativeSwiftUIHostIsNotInterop() {
        let chain = [
            "WKWebView",
            "_TtGC7SwiftUI21UIKitPlatformViewHostGVS_P10$18a5561b832PlatformViewRepresentableAdaptorV8FTE2EIOSP10$1029d04dc16WebViewContainer__",
            "_TtGC7SwiftUI14_UIHostingViewGVS_15ModifiedContentGVS_8LazyViewV8FTE2EIOS8AppShell_VS_12RootModifier__",
            "UIDropShadowView", "UITransitionView", "UIWindow",
        ]
        XCTAssertFalse(WebViewDOM.isInteropHosted(ancestorClassNames: chain))
    }

    /// Compose Multiplatform(UIKitView interop)。フレームワーク名の接頭辞
    /// `ComposeApp` はプロジェクトごとに変わるので目印に使っていないこと
    func testComposeInteropIsDetected() {
        let chain = [
            "WKWebView", "UIView",
            "ComposeAppandroidx.compose.ui.viewinterop.InteropWrappingView18",
            "ComposeAppandroidx.compose.ui.window.BackgroundInputView12",
            "ComposeAppandroidx.compose.ui.window.ComposeContainerView3",
            "_TtGC7SwiftUI21UIKitPlatformViewHostGVS_42PlatformViewControllerRepresentableAdaptorV6iosApp11ComposeView__",
            "UIDropShadowView", "UITransitionView", "UIWindow",
        ]
        XCTAssertTrue(WebViewDOM.isInteropHosted(ancestorClassNames: chain))
        // 接頭辞が別プロジェクト名でも当たること
        let renamed = chain.map { $0.replacingOccurrences(of: "ComposeApp", with: "MyShared") }
        XCTAssertTrue(WebViewDOM.isInteropHosted(ancestorClassNames: renamed))
    }

    /// Flutter(platform view)。**UIKit アプリの add-to-app でもここに当たる**のが要点で、
    /// アプリ単位の判定(bundle に Flutter.framework があるか)では取りこぼす
    func testFlutterPlatformViewIsDetected() {
        let chain = [
            "webview_flutter_wkwebview.WebViewImpl",
            "FlutterTouchInterceptingView", "ChildClippingView", "FlutterView",
            "UIDropShadowView", "UITransitionView", "UIWindow",
        ]
        XCTAssertTrue(WebViewDOM.isInteropHosted(ancestorClassNames: chain))
    }

    /// 素の UIKit(UIViewController に直接載せた WKWebView)
    func testPlainUIKitHostIsNotInterop() {
        XCTAssertFalse(WebViewDOM.isInteropHosted(
            ancestorClassNames: ["WKWebView", "UIView", "UIViewControllerWrapperView", "UIWindow"]))
    }

    // MARK: - 木への差し込み(Android/iOS 共通。守るのは座標の写しと二重表示を作らないことの2つ)

    private func nodePayload(x: Double, y: Double, scale: Double = 1,
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

    /// **Android: density 倍して WebView の原点を足す**。ここを間違えるとタップが画面外や別の行へ飛ぶ
    func testElementsScalesByDensityAndAddsTheWebViewOrigin() {
        // **原点は x も y も 0 にしない**: x=0 で書いたら「x の原点を足し忘れる」
        // 変異が生き残った —— 片方が 0 の座標テストは、その軸を1つも守っていない
        let frame = FTRect(x: 24, y: 142, width: 1080, height: 1500)
        let els = WebViewDOM.elements(payload: nodePayload(x: 16, y: 595),
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

    /// **iOS: density: 1 は倍率なしと等価**(a11y frame が既に pt)。原点は足すだけ
    func testElementsWithDensityOneAddsOnlyTheOrigin() {
        // 原点を両軸とも 0 にしない: どちらかの軸だけ足し忘れる変異を検出するため
        let frame = FTRect(x: 12, y: 88, width: 390, height: 700)
        let els = WebViewDOM.elements(payload: nodePayload(x: 16, y: 60),
                                      webViewFrame: frame, density: 1, startingRef: 5)
        XCTAssertEqual(els.count, 1)
        let e = els[0]
        XCTAssertEqual(e.ref, 5)
        XCTAssertEqual(e.frame.x, 28, accuracy: 0.001)   // 12 + 16
        XCTAssertEqual(e.frame.y, 148, accuracy: 0.001)  // 88 + 60
        XCTAssertEqual(e.web, true, "web の印が無いと OS で扱いが割れる")
    }

    /// ピンチ中は visualViewport の offset/scale を通す(density の掛け算と独立に効く)
    func testElementsHonoursTheVisualViewport() {
        let els = WebViewDOM.elements(
            payload: nodePayload(x: 20, y: 100, scale: 2, offsetLeft: 10, offsetTop: 50),
            webViewFrame: FTRect(x: 0, y: 0, width: 1080, height: 1500),
            density: 1, startingRef: 1)
        XCTAssertEqual(els[0].frame.x, 20, accuracy: 0.001)   // (20-10)*2
        XCTAssertEqual(els[0].frame.y, 100, accuracy: 0.001)  // (100-50)*2
    }

    /// 潰れた要素は落とす(a11y 側の規約と揃える)
    func testElementsDropsZeroSizedNodes() {
        let json = """
        {"viewport":{"offsetLeft":0,"offsetTop":0,"scale":1,"width":360,"height":640},
         "nodes":[{"role":"staticText","label":"x","x":0,"y":0,"width":0,"height":10}]}
        """
        let els = WebViewDOM.elements(payload: try! WebViewDOM.decode(json),
                                      webViewFrame: FTRect(x: 0, y: 0, width: 10, height: 10),
                                      density: 1, startingRef: 1)
        XCTAssertTrue(els.isEmpty)
    }

    // MARK: - 差し込み先の WebView 選択

    func testWebViewElementPicksTheLargestOne() {
        let small = ElementInfo(ref: 1, type: "webView", identifier: nil, label: nil, value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        let big = ElementInfo(ref: 2, type: "webView", identifier: nil, label: nil, value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 100, width: 1080, height: 900), depth: 1)
        XCTAssertEqual(WebViewDOM.webViewFrame(in: [small, big])?.height, 900)
    }

    func testWebViewElementNilMeansNoInjection() {
        let native = ElementInfo(ref: 1, type: "button", identifier: "ok", label: "OK", value: nil,
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        XCTAssertNil(WebViewDOM.webViewFrame(in: [native]))
    }

    // MARK: - 木への差し込み(重複させない)

    /// WebView の内側の a11y 要素だけを落とす。**外側(ブラウザ chrome)とノード自身は残す**
    /// —— 素朴に木全体を対象にすると url バー等まで消えてしまい、能動タブ選択の手掛かりが壊れる
    func testDroppingWebViewSubtreeDropsOnlyElementsInside() {
        let urlBar = ElementInfo(ref: 1, type: "textField", identifier: "url_bar", label: nil,
                                 value: "example.com", placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1)
        let webView = ElementInfo(ref: 2, type: "webView", identifier: nil, label: "Example Domain",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 40, width: 1080, height: 1800), depth: 1)
        // pre-order: webView の直後に来る depth > 1 の要素が「内側」
        let heading = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "Example Domain",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 10, y: 60, width: 200, height: 30), depth: 2)
        let paragraph = ElementInfo(ref: 4, type: "staticText", identifier: nil, label: "More info...",
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 10, y: 100, width: 200, height: 30), depth: 2)
        let tabButton = ElementInfo(ref: 5, type: "button", identifier: "tab_switcher_button", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 1840, width: 60, height: 60), depth: 1)
        let elements = [urlBar, webView, heading, paragraph, tabButton]

        let result = WebViewDOM.droppingWebViewSubtree(elements, webView: webView)

        XCTAssertEqual(result.map(\.ref), [1, 2, 5], "内側(3,4)だけを落とし、外側と本体は残す")
    }

    func testDroppingWebViewSubtreeWithNoDescendantsIsANoop() {
        let webView = ElementInfo(ref: 1, type: "webView", identifier: nil, label: nil, value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 1)
        let sibling = ElementInfo(ref: 2, type: "button", identifier: nil, label: "OK", value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 100, width: 100, height: 40), depth: 1)
        XCTAssertEqual(WebViewDOM.droppingWebViewSubtree([webView, sibling], webView: webView).map(\.ref),
                       [1, 2])
    }

    // MARK: - webView ノードが無いブラウザ画面の内容領域(2026-08-14 の監査で必要になった)

    private func chrome(_ id: String, _ y: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: Int.random(in: 1...9999), type: "other", identifier: id, label: nil,
                    value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 1080, height: h), depth: 1)
    }

    /// **実測した Chrome の木そのもの**(本文を1要素も公開しない画面)。
    /// `webView` ノードが在るときの矩形 y=210 に近い値へ落ちること
    func testDerivesTheContentBandFromTheBrowserChrome() throws {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)
        let elements = [chrome("control_container", 63, 150), chrome("toolbar_container", 63, 150),
                        chrome("toolbar", 63, 147), chrome("url_bar", 71, 131),
                        chrome("toolbar_hairline", 210, 3), chrome("navigationBarBackground", 2361, 63)]
        let frame = try XCTUnwrap(WebViewDOM.browserContentFrame(in: elements, screen: screen))
        XCTAssertEqual(frame.y, 213, accuracy: 0.001, "上端の chrome の最下端")
        XCTAssertEqual(frame.y + frame.height, 2361, accuracy: 0.001, "下端の chrome の最上端")
        XCTAssertEqual(frame.width, 1080, accuracy: 0.001)
    }

    /// **web の中身を chrome と数えない**。`identifier` を持たない要素は無視する ——
    /// 数えると内容領域が潰れ、差し込んだノードが1件も残らない
    func testIgnoresElementsWithoutAnIdentifier() throws {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)
        var elements = [chrome("toolbar_container", 63, 150), chrome("navigationBarBackground", 2361, 63)]
        elements.append(ElementInfo(ref: 99, type: "staticText", identifier: nil, label: "本文",
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 300, width: 1080, height: 400), depth: 1))
        let frame = try XCTUnwrap(WebViewDOM.browserContentFrame(in: elements, screen: screen))
        XCTAssertEqual(frame.y, 213, accuracy: 0.001, "本文を chrome と数えてはいけない")
    }

    /// **手掛かりが無ければ nil**。画面全体で代用すると原点が chrome のぶんずれ、
    /// タップが全部上へ外れる(黙って外すより差し込まないほうがよい)
    func testWithoutAnyChromeItRefusesRatherThanGuessing() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)
        let body = ElementInfo(ref: 1, type: "staticText", identifier: nil, label: "本文", value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 300, width: 1080, height: 400), depth: 1)
        XCTAssertNil(WebViewDOM.browserContentFrame(in: [body], screen: screen))
        XCTAssertNil(WebViewDOM.browserContentFrame(in: [], screen: screen))
    }

    /// 上下のどちらか片方しか無くても成立する(下端の chrome を持たない端末がある)
    func testOneSidedChromeStillYieldsABand() throws {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)
        let frame = try XCTUnwrap(WebViewDOM.browserContentFrame(
            in: [chrome("toolbar_container", 63, 150)], screen: screen))
        XCTAssertEqual(frame.y, 213, accuracy: 0.001)
        XCTAssertEqual(frame.height, 2424 - 213, accuracy: 0.001)
    }

    // MARK: - a11y で足りているか(既定を a11y にしたときの判定。2026-08-14)

    private func node(_ ref: Int, _ type: String, label: String?, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: depth)
    }

    /// 本文が来ていれば DOM は読まない(a11y で足りている)
    func testSufficientWhenTheWebViewHasLabelledContent() {
        let els = [node(1, "webView", label: nil, depth: 1),
                   node(2, "staticText", label: "本文", depth: 2)]
        XCTAssertTrue(WebViewDOM.browserA11yLooksSufficient(elements: els))
    }

    /// **`webView` ノードが無い** = 本文がまだ来ていない → DOM を読む
    func testInsufficientWithoutAWebViewNode() {
        let els = [node(1, "other", label: nil, depth: 1)]
        XCTAssertFalse(WebViewDOM.browserA11yLooksSufficient(elements: els))
    }

    /// **内側にラベルが1つも無い** = 器だけ来ている → DOM を読む
    func testInsufficientWhenTheWebViewIsEmptyInside() {
        let els = [node(1, "webView", label: nil, depth: 1),
                   node(2, "other", label: nil, depth: 2)]
        XCTAssertFalse(WebViewDOM.browserA11yLooksSufficient(elements: els))
    }

    /// **外側の要素で足りていると誤判定しない**(子孫だけを見る)
    func testLabelsOutsideTheWebViewDoNotCount() {
        let els = [node(1, "webView", label: nil, depth: 1),
                   node(2, "button", label: "ツールバー", depth: 1)]
        XCTAssertFalse(WebViewDOM.browserA11yLooksSufficient(elements: els))
    }
}

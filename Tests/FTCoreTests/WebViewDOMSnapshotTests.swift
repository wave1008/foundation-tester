// WKWebView の DOM 走査経路のうち、デバイス無しで固められる部分の固定。
// 実機が要るのは「JS が実際に何を返すか」だけで、JSON の写像・座標変換・型語彙はここで守る。

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
    /// 順序を逆にすると**ズーム時だけ**タップ座標がずれる(実機でしか気付けない類の事故)
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
}

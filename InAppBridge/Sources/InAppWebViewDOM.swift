// WKWebView の中身を DOM から読む in-app 経路。
//
// **なぜ必要か**: in-app エンジンは WKWebView の a11y ツリーを見られない(Web コンテンツの AX は
// WebContent プロセスが提供する)。従来はこの画面だけ XCUITest へ委譲していたが、委譲中は
// 1 手 378ms(in-app は 3ms)で約120倍の劣化が乗る。同じプロセスに居る利点を使い、
// evaluateJavaScript 1往復で DOM を読む。
//
// **スレッド契約**: capture は**メインスレッドから呼んではいけない**。
// evaluateJavaScript の完了はメインキューへ配送されるため、メインで待つと確実にデッドロックする。
// HTTP ハンドラは detachNewThread 上で動く(InAppHTTPServer)ので、その文脈から呼ぶこと。
//
// 操作(タップ・入力)は DOM 側で行わない。element.click() や value 直接代入は
// user activation・IME・:active の挙動を壊すため、従来どおり合成タッチを使う
// (ref に AX ノードを紐付けないと InAppBridge.tapByRef が座標タップへ落ちる = それが狙い)。

import UIKit
import WebKit

enum InAppWebViewDOM {

    struct Captured {
        /// DOM から得た要素(ref は未採番。呼び出し側が採番する)
        var elements: [ElementInfo]
        /// elements と同じ並びの画面座標フレーム(tap の座標解決用)
        var frames: [CGRect]
        /// 取りこぼしの申告(クロスオリジン iframe)。無ければ nil
        var note: String?
    }

    /// JS 1往復の待ち上限。超えたら DOM 経路をあきらめる(呼び出し側は従来どおり
    /// WebView コンテナだけを返し、ホスト側が XCUITest へ委譲する)。
    /// 実測 3〜10ms なので、これに当たるのは JS 無効・重い同期処理・ページ未生成のとき
    private static let evaluationTimeout: DispatchTimeInterval = .milliseconds(1500)

    /// DOM 経路の殺しスイッチ。`FT_WEBVIEW_DOM=off` で従来動作(XCUITest への画面委譲)に戻る。
    /// 効果測定(委譲時との A/B)と、DOM 経路が疑わしいときの切り分けに使う
    private static let disabled =
        (ProcessInfo.processInfo.environment["FT_WEBVIEW_DOM"] ?? "").lowercased() == "off"

    /// 指定 WKWebView の DOM を読み、画面座標の要素列にして返す。
    /// 失敗(JS 例外・タイムアウト・未ロード)は nil を返す = 従来動作へ落とす。
    static func capture(webView: WKWebView, screen: CGRect) -> Captured? {
        precondition(!Thread.isMainThread,
                     "capture はメインで呼べない(evaluateJavaScript の完了待ちでデッドロックする)")
        guard !disabled else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var captured: Captured?

        DispatchQueue.main.async {
            // 読み込み中は評価しない。`loadHTMLString` の途中は URL が about:blank・DOM が空のまま
            // readyState だけ complete を返すため、ここで弾かないと「中身ゼロの WebView」を
            // 読めたことにしてしまう(ホストは委譲もリトライもしなくなる。2026-07-29 実測)
            guard !webView.isLoading else {
                semaphore.signal()
                return
            }
            // 隔離ワールド(defaultClient)で評価する: ページ側の CSP・スクリプトと衝突させない
            webView.evaluateJavaScript(WebViewDOM.javaScript,
                                       in: nil,
                                       in: WKContentWorld.defaultClient) { result in
                defer { semaphore.signal() }
                guard case .success(let value) = result, let json = value as? String,
                      let payload = try? WebViewDOM.decode(json), payload.error == nil,
                      let viewport = payload.viewport,
                      // **読み込み中の about:blank でも readyState は complete を返す**(実測)。
                      // ネイティブ側の isLoading と両方見ないと空の DOM を「読めた」と誤判定する
                      payload.readyState == "complete"
                else { return }
                captured = build(payload: payload, viewport: viewport, webView: webView, screen: screen)
            }
        }

        guard semaphore.wait(timeout: .now() + evaluationTimeout) == .success else { return nil }
        return captured
    }

    /// **メインで呼ぶこと**(UIView.convert を使う)。evaluateJavaScript の完了ブロック内から呼ばれる。
    private static func build(payload: WebViewDOM.Payload, viewport: WebViewDOM.Viewport,
                              webView: WKWebView, screen: CGRect) -> Captured {
        var elements: [ElementInfo] = []
        var frames: [CGRect] = []

        for node in payload.nodes ?? [] {
            guard let type = WebViewDOM.typeName(role: node.role) else { continue }
            let local = WebViewDOM.localRect(node, viewport: viewport)
            // ローカル → 画面。convert は親階層の transform も含めて正しく写す
            let frame = webView.convert(CGRect(x: local.x, y: local.y,
                                               width: local.width, height: local.height),
                                        to: nil)
            // 画面外は a11y 経路と同じく落とす(落とさないと scrollTo が「スクロール前に見つかる」)
            guard frame.width >= 2, frame.height >= 2 else { continue }
            guard screen.isEmpty || frame.intersects(screen) else { continue }

            let label = (node.label?.isEmpty ?? true) ? nil : node.label
            elements.append(ElementInfo(
                ref: 0,   // 採番は呼び出し側(全体の並びが決まってから)
                type: type,
                identifier: nil,   // HTML の id は当てない(契約: WebView 内は #id を使わない)
                label: label,
                value: (node.value?.isEmpty ?? true) ? nil : node.value,
                placeholder: (node.placeholder?.isEmpty ?? true) ? nil : node.placeholder,
                enabled: node.enabled ?? true,
                frame: FTRect(x: frame.origin.x, y: frame.origin.y,
                              width: frame.width, height: frame.height),
                depth: 0,
                checked: (node.checked ?? false) ? true : nil,
                web: true))
            frames.append(frame)
        }

        var note: String?
        if let count = payload.crossOriginFrames, count > 0 {
            // 黙って要素ゼロにしない(読めない領域があることを記録へ残す)
            note = "クロスオリジン iframe \(count) 個の中身は読めません(main frame のみ対応)"
        }
        return Captured(elements: elements, frames: frames, note: note)
    }
}

import SwiftUI
import WebKit

// WebView 対応スパイク用の暫定画面(Phase 0)。HTML は E2EAppAndroid の
// app/src/main/assets/webview_spike.html と同内容。契約(docs/ui-contract.md)は Phase 1 で書く。

struct WebViewScreen: View {
    var body: some View {
        WebViewContainer(html: Self.html)
            .accessibilityIdentifier(Tags.webviewContainer)
    }

    static let html = """
    <!doctype html>
    <!--
      WebView 画面の中身の正本。docs/ui-contract.md の「WebView 画面」節と対になる。
      4 SUT がそれぞれ同じ内容を持つ(iOS/CMP は文字列定数、Android/Flutter はアセット)。
      **id 属性はテストからは引けない**(HTML の id は iOS/Android とも a11y の identifier に
      現れない。2026-07-29 実測)。テストが指すのは表示テキストと aria-label だけ。
      id はこのファイル内の JS が参照するためだけに置いている。
    -->
    <html lang="ja">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body { font-family: -apple-system, system-ui, sans-serif; font-size: 17px; margin: 0; padding: 16px; }
      h1 { font-size: 22px; }
      a, button, input { font-size: 17px; }
      /* 44px 未満はタップ判定が不安定。行は 56px 以上(Compose iOS の frame クランプ対策と同じ理由) */
      button, input { min-height: 44px; padding: 8px; box-sizing: border-box; }
      input { width: 90%; }
      .row { min-height: 56px; padding: 8px 0; border-bottom: 1px solid #ccc; }
    </style>
    </head>
    <body>
    <h1 id="wv_title">WebView 見出し</h1>
    <p id="wv_text">WebView 本文</p>
    <p><a id="wv_link" href="javascript:void(0)" onclick="setResult('link')">WebView リンク</a></p>
    <p><input id="wv_input" type="text" placeholder="WebView 入力"></p>
    <p><button id="wv_submit" onclick="setResult(document.getElementById('wv_input').value)">送信</button></p>
    <p><button id="wv_aria" aria-label="WebView アリアラベル" onclick="setResult('aria')"><span aria-hidden="true">&#9679;</span></button></p>
    <p id="wv_result">wv_result=-</p>
    <div id="wv_rows"></div>
    <p id="wv_offscreen">WebView 画面外テキスト</p>
    <script>
      function setResult(value) {
        document.getElementById('wv_result').textContent = 'wv_result=' + value;
      }
      var rows = '';
      for (var i = 1; i <= 30; i++) {
        var n = (i < 10 ? '0' : '') + i;
        rows += '<div class="row" id="wv_row_' + n + '">WebView 行 ' + n + '</div>';
      }
      document.getElementById('wv_rows').innerHTML = rows;
    </script>
    </body>
    </html>
    """
}

private struct WebViewContainer: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

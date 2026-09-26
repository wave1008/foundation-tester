---
paths:
  - "Sources/FTBridgeClient/*WebView*.swift"
  - "Sources/FTCore/WebView*.swift"
  - "Sources/FTCore/WebViewDOMSnapshot.swift"
  - "Sources/FTCore/WebViewDOMTree.swift"
  - "Tests/FTAndroidTests/WebViewDOMFallbackTests.swift"
  - "Tests/FTAndroidTests/WebViewDOMFallbackWiringTests.swift"
  - "Tests/FTCoreTests/WebViewDOMSnapshotTests.swift"
  - "Tests/FTCoreTests/WebViewDOMVisibilityTests.swift"
---

# WebView / ブラウザの DOM の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **木の出どころは対象とエンジンで決まる**(一覧は docs/design.md §木はどこから来るか が唯一の定義元)。
  **自作アプリの WebView は DOM**(Android = WebView の版で a11y の属性が入れ替わる(124 は placeholder だけ・
  150 は id だけ)ので、a11y が足りて見えても読む。門は `webView` ノードの有無だけ /
  iOS in-app = WKWebView の a11y が見えない)、**iOS xcuitest は a11y**。
  **ブラウザ(Safari / Chrome)は a11y が既定で、足りないときだけ DOM で補う** —— 「充実度がページごとに
  変わるので常に DOM」は撤回済み(差の正体は a11y 接続直後の数秒の窓で、窓を過ぎれば a11y と DOM の
  ラベル集合は一致・a11y が 6〜20 倍速い)。**常に DOM へ戻さない**。足りないと見なすのは
  「`webView` ノードが無い / その内側にラベルが1つも無い」の2つだけ(`WebViewDOM.browserA11yLooksSufficient`)。
  ブラウザへの**口は3つ・その上の層は1つ**
  (Android Chrome=CDP / iOS Safari シミュレータ=unix ソケット / iOS Safari 実機=usbmuxd →
  lockdown → TLS)。差し込みの判定は `FTCore.WebViewDOM`(`WebViewDOMTree.swift`)の1箇所。
  **`WebViewDOMSnapshot.swift` へホスト専用の関数を足さない**(ブリッジのソース集合に入っており、
  足すと dylib に無駄が入って指紋ゲートが鳴る)。**実機 iOS だけの罠3つ**は docs/design.md §実機だけの罠

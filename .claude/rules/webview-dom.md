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

- **木は a11y が既定。ブラウザで足りないときだけ DOM で補う**(**どの組み合わせでどこから木が
  来るかの一覧は docs/design.md §木はどこから来るか**)。**口は3つ・その上の層は1つ**
  (Android Chrome=CDP / iOS Safari シミュレータ=unix ソケット / iOS Safari 実機=usbmuxd →
  lockdown → TLS)。**条件分岐にしない** —— a11y の充実度はページごとに変わるので、
  ブラウザでは常に DOM を正とする。差し込みの判定は `FTCore.WebViewDOM`(`WebViewDOMTree.swift`)の1箇所。
  **`WebViewDOMSnapshot.swift` へホスト専用の関数を足さない**(ブリッジのソース集合に入っており、
  足すと dylib に無駄が入って指紋ゲートが鳴る)。**実機 iOS だけの罠3つ**は docs/design.md §実機だけの罠

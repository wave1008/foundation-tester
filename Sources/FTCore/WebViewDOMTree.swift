// ブラウザの DOM を木へ差し込む判定(Android/iOS 共通)。
//
// **`WebViewDOMSnapshot.swift` へ置かない**: あちらは `BridgeSourceSet` の inApp ブリッジ入力に
// 入っているので、ホスト側だけで使う関数を足すと **dylib に不要なコードが入り、
// `BridgeContractTests` の指紋が鳴って版を上げるか問い直される**。
// 共有したいのは JS と Payload の形だけで、木の組み立てはホスト専用。
//
// 呼び手は `FTAndroid.AndroidWebViewDOM`(Chrome)と
// `FTBridgeClient.SafariWebInspector`(Safari)。**片方だけ変えない** ——
// 差し込み規則が OS で割れると、同じページで木の形が変わる。

import Foundation

public extension WebViewDOM {

    // MARK: - 木への差し込み(Android/iOS 共通。判定は1箇所に寄せる。CLAUDE.md「判定は MCP と DSL で共有する」と同じ規律)
    
    /// DOM のノードを**画面座標の要素**へ写す(純粋)。
    ///
    /// JS は CSS px・visual viewport 相対で返す。**density だけが OS で違う**:
    /// Android は `CSS px × density = 物理 px`(a11y の bounds が物理 px のため)。
    /// iOS の a11y frame は既に pt なので `density: 1` で呼ぶ(専用の別関数は作らない)。
    public static func elements(payload: Payload, webViewFrame: FTRect,
                                density: Double, startingRef: Int) -> [ElementInfo] {
        guard let nodes = payload.nodes, let viewport = payload.viewport else { return [] }
        var out: [ElementInfo] = []
        var ref = startingRef
        for node in nodes {
            guard let type = typeName(role: node.role) else { continue }
            let local = localRect(node, viewport: viewport)
            let frame = FTRect(x: webViewFrame.x + local.x * density,
                               y: webViewFrame.y + local.y * density,
                               width: local.width * density,
                               height: local.height * density)
            // 高さ・幅が 0 の要素は a11y 側の規約に合わせて落とす(SnapshotBuilder と同じ扱い)
            guard frame.width >= 1, frame.height >= 1 else { continue }
            // **web: true を立てる**。読み手が「#id が効かない画面」だと判断する材料で、
            // ここを落とすと OS で扱いが割れる
            out.append(ElementInfo(ref: ref, type: type, identifier: node.identifier,
                                   label: node.label, value: node.value,
                                   placeholder: node.placeholder,
                                   enabled: node.enabled ?? true, frame: frame, depth: 1,
                                   checked: node.checked, web: true))
            ref += 1
        }
        return out
    }
    
    /// 木の中の WebView ノード本体(DOM を差し込む先・スコープ算出の起点)。**最大のものを選ぶ**
    /// —— 入れ子の WebView はブリッジ側で既に落としているが、複数並ぶ画面では
    /// 面積の大きいほうが本体である公算が高い
    public static func webViewElement(in elements: [ElementInfo]) -> ElementInfo? {
        elements.filter { $0.type.lowercased() == "webview" }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
    
    /// `webViewElement(in:)` の frame だけを要る呼び出し向け
    public static func webViewFrame(in elements: [ElementInfo]) -> FTRect? {
        webViewElement(in: elements)?.frame
    }
    
    /// DOM で読む対象のブラウザ(**この集合の外は自作アプリ扱い = a11y のまま**)。
    /// 口の実装は OS ごとに別だが、**「ブラウザかどうか」の判定は1箇所**に置く
    /// —— 割れると「Safari では DOM・注記は a11y 前提」のような食い違いが出る
    public static let knownBrowserIDs: Set<String> = ["com.apple.mobilesafari", "com.android.chrome"]

    /// **`webView` ノードが無いブラウザ画面の、web コンテンツ領域**(純粋)。
    ///
    /// **これが無いと DOM 経路は「最も要る場面」で発動しない**(2026-08-14 の監査で実測):
    /// Chrome は本文を1要素も公開しない画面で **`webView` ノードごと出さない**ことがあり、
    /// `webViewElement(in:)` が nil になって差し込みを諦めていた。同時刻に CDP からは
    /// 9ms で 34 ノード取れていたので、取りこぼしはこちら側の門の掛け方だった。
    ///
    /// 求め方は**上下のブラウザ chrome に挟まれた帯**。chrome は `identifier` を持ち
    /// 画面の上端/下端に貼り付くので、
    /// **上端側の chrome の最下端**から**下端側の chrome の最上端**までを内容領域とする
    /// (実測の Chrome: `toolbar_container` の底 213 に対し `webView` ノードは y=210)。
    /// **`identifier` を持たない要素は見ない** —— それは web の中身の可能性があり、
    /// 中身を chrome と数えると領域が潰れる。
    /// 手掛かりが1つも無ければ nil(**画面全体で代用しない** —— 原点が chrome のぶんずれ、
    /// タップが全部上へ外れる)
    public static func browserContentFrame(in elements: [ElementInfo], screen: FTRect) -> FTRect? {
        guard screen.height > 0 else { return nil }
        let chrome = elements.filter { !($0.identifier ?? "").isEmpty }
        let topBand = screen.y + screen.height * 0.3
        let bottomBand = screen.y + screen.height * 0.9
        // 上端側 = 上から 30% の内側に収まる chrome。その最下端が内容の上端
        let top = chrome.filter { $0.frame.y + $0.frame.height <= topBand }
            .map { $0.frame.y + $0.frame.height }.max()
        // 下端側 = 下から 10% に入る chrome。その最上端が内容の下端
        let bottom = chrome.filter { $0.frame.y >= bottomBand }.map(\.frame.y).min()
        guard top != nil || bottom != nil else { return nil }
        let y = top ?? screen.y
        let maxY = bottom ?? (screen.y + screen.height)
        guard maxY - y >= 1 else { return nil }
        return FTRect(x: screen.x, y: y, width: screen.width, height: maxY - y)
    }

    /// **ブラウザでは DOM が web コンテンツ領域の唯一の正**。WebView ノードの内側にある a11y 要素を
    /// 落としてから DOM のノードを足す(素朴に append すると同じ本文が二重に並ぶ)。
    /// ノード自身とブラウザ chrome(URL バー等 = WebView の外)は残す。
    /// 子孫の判定は `StepExecutor.descendants` と同じ pre-order + depth 規約をそのまま使う
    /// (ここに2つ目の子孫判定を書かない = 3ブリッジの組み立て規約から外れさせない)
    public static func droppingWebViewSubtree(_ elements: [ElementInfo],
                                              webView: ElementInfo) -> [ElementInfo] {
        let inner = Set(StepExecutor.descendants(of: webView, in: elements).map(\.ref))
        guard !inner.isEmpty else { return elements }
        return elements.filter { !inner.contains($0.ref) }
    }
}

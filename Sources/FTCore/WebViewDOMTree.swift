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
    static func elements(payload: Payload, webViewFrame: FTRect,
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
            // 空文字は nil に畳む(in-app の InAppWebViewDOM.build と同じ。入力欄の label はほぼ常に "")
            out.append(ElementInfo(ref: ref, type: type, identifier: nilIfEmpty(node.identifier),
                                   label: nilIfEmpty(node.label), value: nilIfEmpty(node.value),
                                   placeholder: nilIfEmpty(node.placeholder),
                                   enabled: node.enabled ?? true, frame: frame, depth: 1,
                                   checked: node.checked, web: true))
            ref += 1
        }
        return out
    }
    
    private static func nilIfEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// **差し込みに使える payload か**(純粋)。読み込み中は JS が `nodes: []` を返す
    /// (`about:blank` でも readyState は complete)ので、使えない payload で a11y の WebView 部分木を
    /// 落とすと木から本文が消える。in-app(InAppWebViewDOM)の `readyState == "complete"` の門と揃える。
    /// 偽のときは**置き換えず a11y のまま**にする(Android / Safari の呼び手がこの1箇所を通る)
    static func isUsable(_ payload: Payload) -> Bool {
        payload.error == nil && payload.readyState == "complete" && !(payload.nodes ?? []).isEmpty
    }

    /// 木に `webView` 型の要素が2つ以上あるか(純粋)。Android の自作アプリ経路は最初に応答した
    /// ページを最大面積の WebView ノードへ写すので、複数あると別の WebView の矩形へ写りうる
    static func hasMultipleWebViews(in elements: [ElementInfo]) -> Bool {
        elements.filter { $0.type.lowercased() == "webview" }.count >= 2
    }

    /// 差し込んだ回の取りこぼしの申告を木へ載せる(純粋)。note は既存があれば `; ` でつなぐ。
    /// 打ち切りは取りこぼした数が分からないので `truncatedCount` を 1 増やす
    /// (0 のままだと「切り詰めた木では不在を結論しない」`SnapshotTruncation` が働かない)
    static func disclosing(_ payload: Payload, note: String?,
                           truncatedCount: Int) -> (note: String?, truncatedCount: Int) {
        let added = payloadNote(payload)
        let merged = [note, added].compactMap { $0 }.joined(separator: "; ")
        return (merged.isEmpty ? nil : merged,
                payload.truncated == true ? truncatedCount + 1 : truncatedCount)
    }

    /// 木の中の WebView ノード本体(DOM を差し込む先・スコープ算出の起点)。**最大のものを選ぶ**
    /// —— 入れ子の WebView はブリッジ側で既に落としているが、複数並ぶ画面では
    /// 面積の大きいほうが本体である公算が高い
    static func webViewElement(in elements: [ElementInfo]) -> ElementInfo? {
        elements.filter { $0.type.lowercased() == "webview" }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
    
    /// `webViewElement(in:)` の frame だけを要る呼び出し向け
    static func webViewFrame(in elements: [ElementInfo]) -> FTRect? {
        webViewElement(in: elements)?.frame
    }
    
    /// DOM で読む対象のブラウザ(**この集合の外は自作アプリ扱い = a11y のまま**)。
    /// 口の実装は OS ごとに別だが、**「ブラウザかどうか」の判定は1箇所**に置く
    /// —— 割れると「Safari では DOM・注記は a11y 前提」のような食い違いが出る
    static let knownBrowserIDs: Set<String> = ["com.apple.mobilesafari", "com.android.chrome"]

    /// **ブラウザの a11y が足りているか**(純粋)。足りていれば DOM は読まない。
    ///
    /// **既定は a11y**(ユーザー決定)。実測で、窓を過ぎた実ページでは
    /// a11y と DOM の**ラベル集合が完全に一致**し(Wikipedia 34 / 気象庁 61 / tenki.jp 75、
    /// いずれも差 0)、a11y は 6〜20 倍速い(126ms 対 1430ms)。
    /// 「ページごとに a11y の充実度が変わる」ように見えても、実際に変わっているのは
    /// **サービス接続から木が出来るまでの数秒の窓**だけ(常時 DOM にする理由にはならない)。
    ///
    /// 足りないと見なすのは2つだけ: **`webView` ノードが無い** / **その内側にラベルが1つも無い**。
    /// どちらも「本文がまだ来ていない」形で、`missingPageContentNote` が言うのと同じ状態
    static func browserA11yLooksSufficient(elements: [ElementInfo]) -> Bool {
        guard let webView = webViewElement(in: elements) else { return false }
        return LocatorResolver.descendants(of: webView, in: elements)
            .contains { !($0.label ?? "").isEmpty }
    }

    /// **`webView` ノードが無いブラウザ画面の、web コンテンツ領域**(純粋)。
    ///
    /// **これが無いと DOM 経路は「最も要る場面」で発動しない**(監査で実測):
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
    static func browserContentFrame(in elements: [ElementInfo], screen: FTRect) -> FTRect? {
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
    /// 子孫の判定は `LocatorResolver.descendants` と同じ pre-order + depth 規約をそのまま使う
    /// (ここに2つ目の子孫判定を書かない = 3ブリッジの組み立て規約から外れさせない)
    static func droppingWebViewSubtree(_ elements: [ElementInfo],
                                              webView: ElementInfo) -> [ElementInfo] {
        let inner = Set(LocatorResolver.descendants(of: webView, in: elements).map(\.ref))
        guard !inner.isEmpty else { return elements }
        return elements.filter { !inner.contains($0.ref) }
    }

    /// DOM の要素を **WebView ノードの直後に、その depth + 1 で**差し込む(純粋)。
    /// 子孫は pre-order + depth で決まる(`LocatorResolver.descendants`)ので、末尾へ足すと
    /// `.webView >> …` のスコープに DOM の中身が1件も入らない。in-app(InAppBridge.mergeWebViewDOM)も
    /// 同じ形で差し込む = **片方だけ変えない**。WebView ノードが無い(ブラウザの内容領域だけ推定した)
    /// ときは末尾へ depth 1 のまま足す(子孫にする親が居ない)
    static func insertingDOM(_ added: [ElementInfo], after webView: ElementInfo?,
                             into elements: [ElementInfo]) -> [ElementInfo] {
        guard let webView, let at = elements.firstIndex(where: { $0.ref == webView.ref }) else {
            return elements + added
        }
        let nested = added.map { element -> ElementInfo in
            var copy = element
            copy.depth = webView.depth + 1
            return copy
        }
        var out = elements
        out.insert(contentsOf: nested, at: out.index(after: at))
        return out
    }
}

// WKWebView の中身を DOM から直接読むための、プラットフォーム非依存な部品。
// 実行(evaluateJavaScript)は InAppBridge/Sources/InAppWebViewDOM.swift が行い、
// ここには**デバイス無しで固められるロジックだけ**を置く(JS ソース・JSON 写像・座標変換)。
//
// このファイルは **InAppBridge/build.sh が dylib へ直接コンパイルする**(BridgeDTO.swift と同じ扱い)。
// UIKit / WebKit を import してはいけない(ホスト側 FTCore と共有するため)。
//
// なぜ DOM を読むのか: in-app エンジンからは WKWebView の a11y ツリーが見えず(別プロセス提供)、
// 従来は WebView 画面まるごと XCUITest へ委譲していた。委譲中は 1 手 378ms(in-app は 3ms)で
// 約120倍の劣化になる。DOM を1往復で読めば in-app の速度のまま中身を扱える。

import Foundation

public enum WebViewDOM {

    /// 1往復で DOM を走査して JSON 文字列を返す JS。
    /// **ページ側と衝突させないため隔離ワールドで評価する**(呼び出し側の contentWorld 指定)。
    ///
    /// 可視性の判定はここが本体。a11y ツリーは display:none / visibility:hidden / aria-hidden /
    /// 画面外 / 0px を勝手に落としてくれるが、DOM 走査は全部自分で判定する必要がある
    /// (手を抜くと画面に出ていない要素がセレクタに引っかかる)。
    public static let javaScript = """
    (function () {
      function emit(o) { return JSON.stringify(o); }
      try {
        var vv = window.visualViewport;
        var viewport = {
          offsetLeft: vv ? vv.offsetLeft : 0,
          offsetTop: vv ? vv.offsetTop : 0,
          scale: vv ? vv.scale : 1,
          width: vv ? vv.width : window.innerWidth,
          height: vv ? vv.height : window.innerHeight
        };
        var state = document ? document.readyState : "none";
        if (!document || !document.body) {
          return emit({ readyState: state, viewport: viewport, crossOriginFrames: 0, nodes: [] });
        }

        // クロスオリジン iframe は main frame の JS から読めない。**黙って0件にしない**ため数える
        var crossOriginFrames = 0;
        var frames = document.querySelectorAll("iframe,frame");
        for (var i = 0; i < frames.length; i++) {
          try { if (!frames[i].contentDocument) crossOriginFrames++; } catch (e) { crossOriginFrames++; }
        }

        function roleOf(el) {
          var explicit = (el.getAttribute("role") || "").toLowerCase();
          if (explicit === "link") return "link";
          if (explicit === "button") return "button";
          if (explicit === "checkbox" || explicit === "radio") return "checkBox";
          if (explicit === "img" || explicit === "image") return "image";
          if (explicit === "textbox") return "textField";
          var tag = el.tagName.toLowerCase();
          if (tag === "a") return el.hasAttribute("href") ? "link" : "";
          if (tag === "button") return "button";
          if (tag === "select") return "picker";
          if (tag === "textarea") return "textView";
          if (tag === "img") return "image";
          if (tag === "input") {
            var t = (el.getAttribute("type") || "text").toLowerCase();
            if (t === "password") return "secureTextField";
            if (t === "button" || t === "submit" || t === "reset" || t === "image") return "button";
            if (t === "checkbox" || t === "radio") return "checkBox";
            if (t === "range") return "slider";
            if (t === "hidden") return "skip";
            return "textField";
          }
          return "";
        }

        function ownText(el) {
          // 子に要素を持たない = テキストの葉。a11y ツリーの staticText と同じ粒度にする
          if (el.children.length > 0) return "";
          var t = (el.textContent || "").replace(/\\s+/g, " ").trim();
          return t;
        }

        function labelOf(el, role) {
          var aria = el.getAttribute("aria-label");
          if (aria && aria.trim()) return aria.trim();
          if (role === "image") {
            var alt = el.getAttribute("alt");
            if (alt && alt.trim()) return alt.trim();
          }
          var t = (el.textContent || "").replace(/\\s+/g, " ").trim();
          // 容器の全文が入り込まないよう、葉かボタン/リンクのときだけテキストを label にする
          if (el.children.length === 0 || role === "button" || role === "link") return t;
          return "";
        }

        // 中心点が別要素に取られている = 見えていない。祖先/子孫に当たるのは正常(重なりではない)
        function hittable(el, rect) {
          var cx = rect.left + rect.width / 2;
          var cy = rect.top + rect.height / 2;
          if (cx < 0 || cy < 0 || cx > viewport.width || cy > viewport.height) return false;
          var hit = document.elementFromPoint(cx, cy);
          if (!hit) return false;
          return hit === el || el.contains(hit) || hit.contains(el);
        }

        var nodes = [];
        var MAX_NODES = 400;   // ホスト側の上限(120)より多めに採り、絞り込みはホストへ任せる
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT, null);
        var el = document.body;
        while (el && nodes.length < MAX_NODES) {
          var style = window.getComputedStyle(el);
          var skipSubtree = style.display === "none" || style.visibility === "hidden"
            || style.visibility === "collapse" || el.getAttribute("aria-hidden") === "true"
            || el.hasAttribute("hidden");
          if (skipSubtree) {
            // サブツリーごと飛ばす(次の兄弟へ)
            var next = null;
            var cursor = el;
            while (cursor && cursor !== document.body && !next) {
              next = cursor.nextElementSibling;
              cursor = cursor.parentElement;
            }
            if (!next) break;
            walker.currentNode = next;
            el = next;
            continue;
          }

          var role = roleOf(el);
          if (role !== "skip") {
            var text = ownText(el);
            if (role === "" && text !== "") role = "staticText";
            if (role !== "") {
              var r = el.getBoundingClientRect();
              if (r.width >= 2 && r.height >= 2
                  && r.bottom > 0 && r.right > 0
                  && r.top < viewport.height && r.left < viewport.width
                  && hittable(el, r)) {
                var node = {
                  role: role,
                  label: labelOf(el, role),
                  x: r.left, y: r.top, width: r.width, height: r.height,
                  enabled: !el.disabled
                };
                if (role === "textField" || role === "secureTextField" || role === "textView") {
                  var ph = el.getAttribute("placeholder");
                  if (ph) node.placeholder = ph;
                  if (el.value) node.value = el.value;
                  node.label = (el.getAttribute("aria-label") || "").trim();
                } else if (role === "checkBox") {
                  node.checked = !!el.checked;
                }
                nodes.push(node);
                // リンクは a11y 経路が link + staticText の2要素で出す。エンジン間で見え方を
                // 変えないため同じ形にする(片方だけにすると `.staticText&&…` が engine 依存になる)
                if (role === "link" && text !== "") {
                  nodes.push({ role: "staticText", label: text,
                               x: r.left, y: r.top, width: r.width, height: r.height, enabled: true });
                }
              }
            }
          }

          el = walker.nextNode();
        }

        return emit({ readyState: state, viewport: viewport,
                      crossOriginFrames: crossOriginFrames, nodes: nodes });
      } catch (e) {
        return emit({ error: String(e) });
      }
    })()
    """

    /// JS の戻り値(JSON 文字列)をそのまま写した形。
    public struct Payload: Decodable, Sendable {
        public var readyState: String?
        public var viewport: Viewport?
        public var crossOriginFrames: Int?
        public var nodes: [Node]?
        /// JS 側で例外になったときだけ入る(この場合は XCUITest 経路へ落とす)
        public var error: String?
    }

    /// ピンチズーム時の可視ビューポート。scale=1・offset=0 が既定(未ズーム)。
    public struct Viewport: Decodable, Sendable {
        public var offsetLeft: Double
        public var offsetTop: Double
        public var scale: Double
        public var width: Double
        public var height: Double
    }

    public struct Node: Decodable, Sendable {
        public var role: String
        public var label: String?
        public var value: String?
        public var placeholder: String?
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var enabled: Bool?
        public var checked: Bool?
    }

    public static func decode(_ json: String) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
    }

    /// CSS px(visual viewport 相対)→ WKWebView のローカル座標(pt)。
    /// **ズーム時は visualViewport の offset/scale を通す**(getBoundingClientRect は
    /// レイアウトビューポート基準なので、ピンチ中は素の値だと画面上の位置とずれる)。
    /// ここから先(ローカル → 画面)は UIView.convert が担う = 親のスケール/回転も含めて正しくなる。
    public static func localRect(_ node: Node, viewport: Viewport) -> FTRect {
        let scale = viewport.scale > 0 ? viewport.scale : 1
        return FTRect(x: (node.x - viewport.offsetLeft) * scale,
                      y: (node.y - viewport.offsetTop) * scale,
                      width: node.width * scale,
                      height: node.height * scale)
    }

    /// **その WKWebView が interop 越しに埋め込まれているか**を祖先のクラス名から判定する。
    ///
    /// Compose / Flutter は WebView を interop(UIKitView / platform view)で載せ、合成タッチと
    /// `insertText` を横取りする。DOM は読めるのに**操作だけ届かない**状態になるため、
    /// そういう WebView では DOM 経路を使わず画面ごと XCUITest へ委譲する。
    ///
    /// **アプリ単位(bundle に Flutter.framework があるか等)で判定してはいけない**:
    /// UIKit アプリが Flutter add-to-app や CMP 画面を部分的に抱える構成では、アプリは uikit と
    /// 判定されるのに中の WebView は interop 配下になる(逆に、その1画面のために
    /// アプリ全体で DOM 経路を諦めることにもなる)。危険は WKWebView 単位で決まる。
    ///
    /// 目印は実測(2026-07-29・iOS 27.0 シミュレータ)の祖先チェーンから採った:
    /// - Flutter: `FlutterTouchInterceptingView < ChildClippingView < FlutterView`
    /// - CMP: `ComposeApp…androidx.compose.ui.viewinterop.InteropWrappingView < … ComposeContainerView`
    ///   (先頭の `ComposeApp` は Kotlin フレームワーク名でプロジェクトごとに変わるため**使わない**)
    /// - SwiftUI ネイティブ: `_TtGC7SwiftUI21UIKitPlatformViewHost…`(どの目印にも当たらない)
    public static func isInteropHosted(ancestorClassNames: [String]) -> Bool {
        let markers = [
            "FlutterView",                  // Flutter(add-to-app 含む)
            "FlutterTouchInterceptingView", // platform view のタッチ横取り本体
            "androidx.compose.ui.",         // Compose Multiplatform の interop / コンテナ
            "RNCWebView",                   // react-native-webview(RNCWebViewImpl も contains で拾う。
                                            // 2026-08-08 実測: DOM 読みは通るが合成タッチが Web 側の
                                            // ハンドラに届かず、リンクタップが無反応のまま成功に見える)
        ]
        return ancestorClassNames.contains { name in
            markers.contains { name.contains($0) }
        }
    }

    /// DOM のロール → 既存の型語彙(ブリッジが返す綴り。ホストが先頭小文字へ畳む)。
    /// 未知のロールは Other にせず落とす(容器を掴ませないため)。
    public static func typeName(role: String) -> String? {
        switch role {
        case "link": return "Link"
        case "button": return "Button"
        case "staticText": return "StaticText"
        case "textField": return "TextField"
        case "secureTextField": return "SecureTextField"
        case "textView": return "TextView"
        case "image": return "Image"
        case "checkBox": return "CheckBox"
        case "picker": return "Picker"
        case "slider": return "Slider"
        default: return nil
        }
    }
}

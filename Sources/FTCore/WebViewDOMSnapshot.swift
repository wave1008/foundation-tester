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
            // **alt が無い画像は src のファイル名を名前にする**(2026-08-13)。
            // Chromium の a11y はそうしており(`logo_small.svg` → `logo_small`)、
            // 揃えないと**ブラウザで a11y を DOM に置き換えた瞬間に名前が消える**
            var src = el.getAttribute("src") || "";
            var base = src.split("?")[0].split("#")[0].split("/").pop() || "";
            base = base.replace(/\\.[A-Za-z0-9]+$/, "");
            if (base) return base;
          }
          var t = (el.textContent || "").replace(/\\s+/g, " ").trim();
          // 容器の全文が入り込まないよう、葉かボタン/リンクのときだけテキストを label にする
          if (el.children.length === 0 || role === "button" || role === "link") return t;
          return "";
        }

        // **子孫が全部インラインのテキストなら1ノードへ畳む**(2026-08-13)。
        // Chromium の a11y は `<td><span>19</span> / <span>24</span></td>` を「19 / 24」1件で出すが、
        // 素の DOM 走査は葉ごとに3件出す。揃えないと**同じページなのに
        // 「a11y で読む画面」と「DOM で読む画面」でセレクタが書き分け**になる。
        // **役割を持つ子孫(link/button/input/img…)が1つでもあれば畳まない**(操作対象を潰さない)。
        // ブロック級の子孫があるものも畳まない(`<div>` が段落をまとめて1件になるのを防ぐ)。
        // 走査は el ごとに部分木を舐めるので、**大きい部分木は数で足切りする**(そもそもテキスト塊ではない)
        function isInlineTextBlock(el) {
          var kids = el.getElementsByTagName("*");
          if (kids.length === 0 || kids.length > 50) return false;
          for (var i = 0; i < kids.length; i++) {
            if (roleOf(kids[i]) !== "") return false;
            var d = window.getComputedStyle(kids[i]).display;
            if (d !== "inline" && d !== "inline-block" && d !== "contents") return false;
          }
          return (el.textContent || "").replace(/\\s+/g, " ").trim() !== "";
        }

        // 中心点が別要素に取られている = 見えていない。祖先/子孫に当たるのは正常(重なりではない)。
        //
        // **撃つ点は「見えている部分」の中心**(素の中心ではない)。ページがスクロールして
        // 上端に半分だけ残った入力欄は、素の中心が viewport の外へ出る ——
        // 中心で判定すると**触れる要素が木から丸ごと落ちる**(a11y 経路は残すので、
        // 同じページで経路により見え方が割れる = この経路が守るべき不変条件が壊れる)。
        // **交差が空(完全に画面外)のための分岐は置かない** —— elementFromPoint は viewport の
        // 外の点に null を返す規定なので、寄せた点がそのまま false を導く。分岐を足すと
        // 呼び出し側の矩形ゲートに阻まれて**到達しない行**になり、変異で殺せない砦になる
        function hittable(el, rect) {
          var left = Math.max(rect.left, 0);
          var right = Math.min(rect.right, viewport.width);
          var top = Math.max(rect.top, 0);
          var bottom = Math.min(rect.bottom, viewport.height);
          var hit = document.elementFromPoint((left + right) / 2, (top + bottom) / 2);
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

          // **テキスト塊は1件に畳んで部分木を飛ばす**(a11y と粒度を揃える。宣言は isInlineTextBlock)。
          // **飛ばすのは実際に出せたときだけ** —— 可視判定で落ちた容器の中身まで捨てない
          if (roleOf(el) === "" && isInlineTextBlock(el)) {
            var br = el.getBoundingClientRect();
            if (br.width >= 2 && br.height >= 2 && br.bottom > 0 && br.right > 0
                && br.top < viewport.height && br.left < viewport.width && hittable(el, br)) {
              nodes.push({ role: "staticText",
                           label: (el.textContent || "").replace(/\\s+/g, " ").trim(),
                           x: br.left, y: br.top, width: br.width, height: br.height,
                           enabled: true });
              var after = null;
              var up = el;
              while (up && up !== document.body && !after) {
                after = up.nextElementSibling;
                up = up.parentElement;
              }
              if (!after) break;
              walker.currentNode = after;
              el = after;
              continue;
            }
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
                // **DOM の id を `#id` として出す**。a11y 側(WebView 150)も
                // viewIdResourceName に同じものを出すので、経路が変わっても同じ書き方で指せる
                if (el.id) node.identifier = el.id;
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
        /// DOM の `id`(**`#id` セレクタの供給源**)。2026-08-14 に足した ——
        /// WebView 150 の a11y は既に DOM の id を `viewIdResourceName` に出しており、
        /// DOM 経路だけ出さないと**同じページで経路によってセレクタが変わる**
        public var identifier: String?
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

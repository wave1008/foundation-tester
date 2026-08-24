// WebView の DOM 走査 JS(`WebViewDOM.javaScript`)を**実際に評価して**可視判定を固定する。
//
// 他のテスト(WebViewDOMSnapshotTests)は JSON の写像と座標変換だけを守っており、JS 本体は
// 「文字列に elementFromPoint が入っているか」しか見ていない。可視判定の規則はこのファイルの
// 唯一の砦で、破ると**実機でしか出ない取りこぼし**になる(witness: E2E-CMP
// `WebViewの中身を操作できること.S0010` —— ページがスクロールして上端に半分残った入力欄が
// 木から丸ごと落ち、5回中4回赤くなった)。
//
// DOM は JavaScriptCore に無いので、**JS が実際に触る API だけ**を持つ最小の stub を置く
// (getBoundingClientRect / getComputedStyle / elementFromPoint / TreeWalker / 属性)。
// stub は「後に書いた要素が手前」= 文書順の後勝ちで elementFromPoint を解決する。

import XCTest
import JavaScriptCore
@testable import FTCore

final class WebViewDOMVisibilityTests: XCTestCase {

    // MARK: - 実行ハーネス

    /// `spec`(JS のオブジェクトリテラル)を body に見立てて本番 JS を走らせ、写した Payload を返す。
    private func scan(body spec: String,
                      viewport: (width: Double, height: Double) = (402, 650),
                      file: StaticString = #filePath, line: UInt = #line) throws -> WebViewDOM.Payload {
        let context = try XCTUnwrap(JSContext(), file: file, line: line)
        var failure: String?
        context.exceptionHandler = { _, exception in
            failure = exception?.toString() ?? "unknown JS exception"
        }
        context.evaluateScript(Self.domStub)
        context.evaluateScript("""
        document.body = new El(\(spec), null);
        window.visualViewport.width = \(viewport.width);
        window.visualViewport.height = \(viewport.height);
        """)
        let value = context.evaluateScript(WebViewDOM.javaScript)
        if let failure { XCTFail("JS 例外: \(failure)", file: file, line: line) }
        let json = try XCTUnwrap(value?.toString(), file: file, line: line)
        let payload = try WebViewDOM.decode(json)
        XCTAssertNil(payload.error, "JS が error を返した: \(payload.error ?? "")", file: file, line: line)
        return payload
    }

    private func node(_ payload: WebViewDOM.Payload, id: String) -> WebViewDOM.Node? {
        payload.nodes?.first { $0.identifier == id }
    }

    // MARK: - 上端・下端で切れた要素

    /// 見えている部分の中心で当てる —— **これが素の中心に戻ると木から落ちる**(実害の型)。
    /// 上端で 6pt だけ残った入力欄は、素の中心 (y=-16) が viewport の外にある
    func testPartlyVisibleAtTopEdgeIsListed() throws {
        let payload = try scan(body: """
        { tag: "body", rect: { left: 0, top: 0, width: 402, height: 650 }, children: [
          { tag: "input", id: "wv_input", rect: { left: 16, top: -38, width: 333, height: 44 },
            attrs: { type: "text", placeholder: "WebView 入力", "aria-label": "WebView 入力" },
            value: "hello123" },
          { tag: "button", id: "wv_submit", text: "送信",
            rect: { left: 16, top: 23, width: 49, height: 44 } }
        ] }
        """)
        let input = try XCTUnwrap(node(payload, id: "wv_input"),
                                  "上端で切れた入力欄が木から落ちた(素の中心での判定に戻っている)")
        XCTAssertEqual(input.role, "textField")
        XCTAssertEqual(input.placeholder, "WebView 入力")
        XCTAssertEqual(input.value, "hello123")
        // 矩形は切り取らずそのまま出す(切り出しはホスト側の役目)
        XCTAssertEqual(input.y, -38)
        XCTAssertEqual(input.height, 44)
        XCTAssertNotNil(node(payload, id: "wv_submit"))
    }

    /// 下端でも同じこと(片側だけ直すと横スクロール・下端で同じ穴が残る)
    func testPartlyVisibleAtBottomEdgeIsListed() throws {
        let payload = try scan(body: """
        { tag: "body", rect: { left: 0, top: 0, width: 402, height: 650 }, children: [
          { tag: "button", id: "wv_fixed", text: "固定ボタン",
            rect: { left: 16, top: 630, width: 97, height: 44 } }
        ] }
        """)
        XCTAssertNotNil(node(payload, id: "wv_fixed"),
                        "下端で切れたボタンが木から落ちた")
    }

    /// 右端で切れた要素(横軸も同じ規則で扱う)
    func testPartlyVisibleAtRightEdgeIsListed() throws {
        let payload = try scan(body: """
        { tag: "body", rect: { left: 0, top: 0, width: 402, height: 650 }, children: [
          { tag: "button", id: "wv_carousel", text: "次のカード",
            rect: { left: 390, top: 100, width: 200, height: 44 } }
        ] }
        """)
        XCTAssertNotNil(node(payload, id: "wv_carousel"), "右端で切れたボタンが木から落ちた")
    }

    // MARK: - 落とすべきものは落とし続ける(逆向きの変異を殺す)

    /// **完全に画面外**は出さない(「常に出す」変異はここで落ちる)
    func testFullyOffscreenIsNotListed() throws {
        let payload = try scan(body: """
        { tag: "body", rect: { left: 0, top: 0, width: 402, height: 650 }, children: [
          { tag: "input", id: "wv_above", rect: { left: 16, top: -60, width: 333, height: 44 },
            attrs: { type: "text", placeholder: "上に流れた欄" } },
          { tag: "input", id: "wv_below", rect: { left: 16, top: 700, width: 333, height: 44 },
            attrs: { type: "text", placeholder: "下に流れた欄" } },
          { tag: "button", id: "wv_here", text: "見えている",
            rect: { left: 16, top: 100, width: 97, height: 44 } }
        ] }
        """)
        XCTAssertNil(node(payload, id: "wv_above"), "画面の上へ完全に外れた欄を出した")
        XCTAssertNil(node(payload, id: "wv_below"), "画面の下へ完全に外れた欄を出した")
        XCTAssertNotNil(node(payload, id: "wv_here"))
    }

    /// **別要素に覆われたもの**は出さない = hittable 本来の役目。
    /// 見えている部分の中心へ寄せても、そこが他人に取られていれば落とす
    func testCoveredElementIsNotListed() throws {
        let payload = try scan(body: """
        { tag: "body", rect: { left: 0, top: 0, width: 402, height: 650 }, children: [
          { tag: "button", id: "wv_behind", text: "背後のボタン",
            rect: { left: 16, top: 100, width: 97, height: 44 } },
          { tag: "div", id: "wv_overlay", text: "覆い",
            rect: { left: 0, top: 0, width: 402, height: 650 } }
        ] }
        """)
        XCTAssertNil(node(payload, id: "wv_behind"), "覆われたボタンを出した")
        XCTAssertNotNil(node(payload, id: "wv_overlay"))
    }

    /// 上端で切れた要素が**さらに覆われている**ときも落とす(寄せた点で判定していることの確認)
    func testPartlyVisibleButCoveredIsNotListed() throws {
        let payload = try scan(body: """
        { tag: "body", rect: { left: 0, top: 0, width: 402, height: 650 }, children: [
          { tag: "input", id: "wv_input", rect: { left: 16, top: -38, width: 333, height: 44 },
            attrs: { type: "text", placeholder: "WebView 入力" } },
          { tag: "div", id: "wv_overlay", text: "覆い",
            rect: { left: 0, top: 0, width: 402, height: 650 } }
        ] }
        """)
        XCTAssertNil(node(payload, id: "wv_input"), "覆われた入力欄を出した")
    }

    /// display:none / aria-hidden は従来どおりサブツリーごと落ちる(可視判定の他の砦)
    func testHiddenSubtreeIsSkipped() throws {
        let payload = try scan(body: """
        { tag: "body", rect: { left: 0, top: 0, width: 402, height: 650 }, children: [
          { tag: "div", id: "wv_hidden", display: "none", rect: { left: 0, top: 0, width: 402, height: 100 },
            children: [ { tag: "button", id: "wv_inside_hidden", text: "隠れたボタン",
                          rect: { left: 16, top: 10, width: 97, height: 44 } } ] },
          { tag: "div", id: "wv_aria", attrs: { "aria-hidden": "true" },
            rect: { left: 0, top: 110, width: 402, height: 100 },
            children: [ { tag: "button", id: "wv_inside_aria", text: "読み上げ対象外",
                          rect: { left: 16, top: 120, width: 97, height: 44 } } ] },
          { tag: "button", id: "wv_visible", text: "見えている",
            rect: { left: 16, top: 300, width: 97, height: 44 } }
        ] }
        """)
        XCTAssertNil(node(payload, id: "wv_inside_hidden"))
        XCTAssertNil(node(payload, id: "wv_inside_aria"))
        XCTAssertNotNil(node(payload, id: "wv_visible"))
    }

    // MARK: - stub

    /// JS が実際に触る DOM API だけの最小実装。**本番 JS は1行も持たない**
    private static let domStub = #"""
    var NodeFilter = { SHOW_ELEMENT: 1 };

    function El(spec, parent) {
      this.tagName = (spec.tag || "div").toUpperCase();
      this.id = spec.id || "";
      this._attrs = spec.attrs || {};
      this._own = spec.text || "";
      this._rect = spec.rect || { left: 0, top: 0, width: 0, height: 0 };
      this._style = { display: spec.display || "block",
                      visibility: spec.visibility || "visible" };
      this.parentElement = parent || null;
      this.children = [];
      this.nextElementSibling = null;
      if (spec.value !== undefined) this.value = spec.value;
      if (spec.disabled) this.disabled = true;
      if (spec.checked !== undefined) this.checked = spec.checked;
      var kids = spec.children || [];
      for (var i = 0; i < kids.length; i++) this.children.push(new El(kids[i], this));
      for (var j = 0; j + 1 < this.children.length; j++) {
        this.children[j].nextElementSibling = this.children[j + 1];
      }
    }
    El.prototype.getAttribute = function (n) {
      return this._attrs[n] !== undefined ? this._attrs[n] : null;
    };
    El.prototype.hasAttribute = function (n) { return this._attrs[n] !== undefined; };
    El.prototype.getBoundingClientRect = function () {
      var r = this._rect;
      return { left: r.left, top: r.top, width: r.width, height: r.height,
               right: r.left + r.width, bottom: r.top + r.height };
    };
    El.prototype.descendants = function () {
      var out = [];
      for (var i = 0; i < this.children.length; i++) {
        out.push(this.children[i]);
        out = out.concat(this.children[i].descendants());
      }
      return out;
    };
    El.prototype.getElementsByTagName = function () { return this.descendants(); };
    El.prototype.contains = function (other) {
      var n = other;
      while (n) { if (n === this) return true; n = n.parentElement; }
      return false;
    };
    Object.defineProperty(El.prototype, "textContent", {
      get: function () {
        var t = this._own;
        for (var i = 0; i < this.children.length; i++) t += this.children[i].textContent;
        return t;
      }
    });

    function Walker(root) { this.root = root; this.currentNode = root; }
    Walker.prototype.nextNode = function () {
      var n = this.currentNode;
      if (n.children.length > 0) { this.currentNode = n.children[0]; return this.currentNode; }
      while (n && n !== this.root) {
        if (n.nextElementSibling) { this.currentNode = n.nextElementSibling; return this.currentNode; }
        n = n.parentElement;
      }
      return null;
    };

    var document = {
      readyState: "complete",
      body: null,
      createTreeWalker: function (root) { return new Walker(root); },
      querySelectorAll: function () { return []; },
      // 文書順の後勝ち = 後に書いた要素が手前。display:none / visibility:hidden は当たらない。
      // **viewport の外の点には null**(仕様どおり)—— これを省くと「寄せていない点」でも
      // 当たってしまい、寄せを外す変異をテストが素通しする(2026-08-25 に実際に素通しした)
      elementFromPoint: function (x, y) {
        var vv = window.visualViewport;
        if (x < 0 || y < 0 || x > vv.width || y > vv.height) return null;
        var all = [document.body].concat(document.body.descendants());
        var hit = null;
        for (var i = 0; i < all.length; i++) {
          var s = all[i]._style;
          if (s.display === "none" || s.visibility === "hidden") continue;
          var r = all[i].getBoundingClientRect();
          if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) hit = all[i];
        }
        return hit;
      }
    };

    var window = {
      visualViewport: { offsetLeft: 0, offsetTop: 0, scale: 1, width: 402, height: 650 },
      getComputedStyle: function (el) { return el._style; }
    };
    """#
}

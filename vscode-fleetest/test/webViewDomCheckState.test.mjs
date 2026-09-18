// WebView の DOM 走査スクリプト(Sources/FTCore/WebViewDOMSnapshot.swift の WebViewDOM.javaScript)を
// jsdom で実際に走らせ、チェック状態の出し方を確かめる。Swift の swift test は JS を実行できないため
// ここに置く。スクリプトは in-app ブリッジ(iOS)とホストの DOM 経路(Android CDP / Safari)が共有する。
//
// 状態は value "1"/"0"/"2"(mixed)で出す(WebKit の a11y と同じ形。読み手は FTCore.CheckStateReading)。
// 以前は el.checked しか読まず、ARIA の checkbox(div role=checkbox)が常にオフ = checkIsOFF が誤った緑だった。
//
// jsdom はレイアウトを持たないので、矩形と elementFromPoint を「要素ごとに1行」の配置で差し替える。
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { JSDOM } from "jsdom";

const REPO = path.join(process.cwd(), "..");

/** Swift の複数行文字列リテラルから JS 本体を取り出す(字下げ 4 と `\\` のエスケープを戻す) */
function domScript() {
  const lines = readFileSync(path.join(REPO, "Sources/FTCore/WebViewDOMSnapshot.swift"), "utf8").split("\n");
  const start = lines.findIndex((l) => l.includes('public static let javaScript = """'));
  assert.ok(start >= 0, "WebViewDOM.javaScript が見つかりません");
  let end = start + 1;
  while (lines[end].trim() !== '"""') end++;
  return lines.slice(start + 1, end).map((l) => l.replace(/^ {4}/, "")).join("\n").replace(/\\\\/g, "\\");
}

const PAGE = `<!doctype html><html><body>
<label><input type="checkbox" id="nat_on" checked> NativeOn</label>
<label><input type="checkbox" id="nat_off"> NativeOff</label>
<label><input type="radio" name="r" id="rad_on" checked> RadioOn</label>
<label><input type="radio" name="r" id="rad_off"> RadioOff</label>
<div role="checkbox" aria-checked="true" id="aria_on">AriaOn</div>
<div role="checkbox" aria-checked="false" id="aria_off">AriaOff</div>
<div role="checkbox" aria-checked="mixed" id="aria_mixed">AriaMixed</div>
<div role="switch" aria-checked="true" id="sw_on">SwitchOn</div>
<input type="checkbox" id="indet">
</body></html>`;

test("DOM 走査はチェック状態を value で出し、ARIA と indeterminate も読む", (t) => {
  const dom = new JSDOM(PAGE, { runScripts: "outside-only", pretendToBeVisual: true });
  const window = dom.window;
  t.after(() => window.close());
  window.document.getElementById("indet").indeterminate = true;
  const all = Array.from(window.document.body.querySelectorAll("*"));
  window.Element.prototype.getBoundingClientRect = function () {
    const y = all.indexOf(this) * 30;
    return { left: 0, top: y, right: 300, bottom: y + 20, width: 300, height: 20, x: 0, y };
  };
  window.document.elementFromPoint = (_x, y) => all[Math.floor(y / 30)] ?? null;
  Object.defineProperty(window, "innerHeight", { value: 10000 });
  Object.defineProperty(window, "innerWidth", { value: 400 });

  const out = JSON.parse(window.eval(domScript()));
  assert.equal(out.error, undefined, out.error);
  const byId = Object.fromEntries(out.nodes.filter((n) => n.identifier).map((n) => [n.identifier, n]));
  const expected = {
    nat_on: ["checkBox", "1", true], nat_off: ["checkBox", "0", false],
    rad_on: ["checkBox", "1", true], rad_off: ["checkBox", "0", false],
    aria_on: ["checkBox", "1", true], aria_off: ["checkBox", "0", false],
    aria_mixed: ["checkBox", "2", false], sw_on: ["switch", "1", true],
    indet: ["checkBox", "2", false],
  };
  for (const [id, [role, value, checked]] of Object.entries(expected)) {
    assert.ok(byId[id], `${id} が DOM 走査の結果に無い`);
    assert.deepEqual([byId[id].role, byId[id].value, byId[id].checked], [role, value, checked], id);
  }
});

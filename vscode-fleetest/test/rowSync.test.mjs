// rowSync.js(描き直しで中身の変わらない要素を作り直さない)の単体テスト。マウスを載せている要素が作り直されると
// ツールチップが点滅するので、「同じなら同じ要素」「変われば差し替え」「1段降りて変わったセルだけ」を固定する。
import assert from "node:assert/strict";
import { test } from "node:test";
import { JSDOM } from "jsdom";
import { syncChildren } from "../src/webview/monitor/rowSync.js";

function rows(document, data) {
  return data.map(([key, a, b]) => {
    const tr = document.createElement("tr");
    tr.dataset.key = key;
    for (const text of [a, b]) {
      const td = document.createElement("td");
      td.textContent = text;
      tr.appendChild(td);
    }
    return tr;
  });
}

test("同じ outerHTML の行は残し、変わった行だけ差し替え、余りを消す", (t) => {
  const { window } = new JSDOM("<table><tbody></tbody></table>");
  t.after(() => window.close());
  const body = window.document.querySelector("tbody");
  syncChildren(body, rows(window.document, [["a", "1", "x"], ["b", "2", "y"], ["c", "3", "z"]]));
  const [a, b] = body.children;
  // 挿入後に属性が書き換わっても(hoverTip.js が title を移す等)、比べるのは挿入時点の値
  a.setAttribute("data-hover-tip", "moved");
  syncChildren(body, rows(window.document, [["a", "1", "x"], ["b", "2", "Y"]]));
  assert.equal(body.children.length, 2);
  assert.equal(body.children[0], a, "同じ行は同じ要素");
  assert.notEqual(body.children[1], b, "変わった行は差し替え");
  assert.equal(body.children[1].children[1].textContent, "Y");
});

test("recurseWhen が真の位置は行を残して変わったセルだけ差し替える", (t) => {
  const { window } = new JSDOM("<table><tbody></tbody></table>");
  t.after(() => window.close());
  const body = window.document.querySelector("tbody");
  const same = (old, next) => old.dataset.key === next.dataset.key;
  syncChildren(body, rows(window.document, [["a", "1", "x"]]), { recurseWhen: same });
  const tr = body.children[0];
  const [c0, c1] = tr.children;
  syncChildren(body, rows(window.document, [["a", "1", "changed"]]), { recurseWhen: same });
  assert.equal(body.children[0], tr, "行は残す");
  assert.equal(tr.children[0], c0, "変わっていないセルは同じ要素");
  assert.notEqual(tr.children[1], c1);
  assert.equal(tr.children[1].textContent, "changed");
  // 別のデバイスの行(鍵が違う)は行ごと差し替える
  syncChildren(body, rows(window.document, [["z", "1", "changed"]]), { recurseWhen: same });
  assert.notEqual(body.children[0], tr);
});

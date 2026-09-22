// 「デバイスモニター」タブの「ライブ更新」トグルの配線テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewSelectAllPersist.test.mjs と同じ。
// 契約は monitorWebviewMessages.ts の setShowStreamDuringRun(webview→host)/ showStreamDuringRun(host→webview)。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorWebviewMessages";

const require2 = createRequire(import.meta.url);

let panelHtml;
let webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    write: false,
    external: ["vscode"],
    logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" };
  panelHtml = mod.exports.renderHtml(webviewStub, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")],
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "es2022",
    write: false,
    logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

/** window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない */
function createWebview() {
  const posted = [];
  let state;
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: (next) => { state = next; },
    getState: () => state,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

const sentValues = (posted) => posted.filter((m) => m?.type === "setShowStreamDuringRun").map((m) => m.value);

test("トグルは「すべて選択」の右に既定 ON で置かれる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const checkbox = document.getElementById("chk-show-stream-during-run");
  assert.ok(checkbox);
  assert.equal(checkbox.checked, true);
  assert.ok(checkbox.classList.contains("toggle-switch"), "見た目はトグル(style.css の .toggle-switch)");
  assert.equal(checkbox.getAttribute("role"), "switch");
  const label = checkbox.closest("label");
  // **ラインビューの見出し行の「すべて選択」の右**(ユーザー決定 2026-09-22)—— どちらも
  // タイルの見え方を操るので隣り合わせる。ツールバーからもグリッドビューからも外した
  assert.equal(label.parentElement, document.getElementById("line-view-header"));
  assert.equal(
    label.previousElementSibling,
    document.getElementById("chk-select-all").closest("label"),
    "すぐ左が「すべて選択」",
  );
  assert.ok(label.classList.contains("run-stream-toggle"), "位置と離し方を持つ class");
  assert.equal(document.querySelectorAll("#grid-view-header .run-stream-toggle").length, 0, "グリッドビューには残さない");
});

test("切り替えるたびに host へ送り、host の復元値は投げ返さない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  const checkbox = document.getElementById("chk-show-stream-during-run");

  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "showStreamDuringRun", value: false } }));
  assert.equal(checkbox.checked, false, "復元値を反映する");
  assert.deepEqual(sentValues(posted), [], "復元は送り返さない");

  checkbox.click();
  checkbox.click();
  assert.deepEqual(sentValues(posted), [true, false]);
  for (const message of posted.filter((m) => m?.type === "setShowStreamDuringRun")) {
    assert.equal(isMonitorFromWebviewMessage(message), true, "host 側の検証を通る形で送る");
  }
  assert.equal(isMonitorFromWebviewMessage({ type: "setShowStreamDuringRun", value: "yes" }), false);
});

// トグルの描画は**素の input[type="checkbox"](18px の四角 + 回転ボーダーのチェック)の
// 上書き**で成り立っている。詳細度が同じなので順序が逆転すると黙って四角に戻る ——
// jsdom は CSS を読まないので、スタイルシートのテキストで固める。
test("style.css: トグルは素のチェックボックス描画の後ろに置き、ON は青い地になる", () => {
  const css = readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  const plain = css.indexOf('input[type="checkbox"]:checked::after');
  const toggle = css.indexOf('input[type="checkbox"].toggle-switch {');
  assert.ok(plain >= 0, "素のチェックボックスの描画がある");
  assert.ok(toggle >= 0, "トグルの規則がある");
  assert.ok(toggle > plain, "トグルは素の描画より後ろ(同じ詳細度は順序で決まる)");

  const track = /input\[type="checkbox"\]\.toggle-switch \{([\s\S]*?)\}/.exec(css)[1];
  assert.match(track, /border-radius:\s*7px/, "丸い帯(四角に戻っていない)");

  const on = /input\[type="checkbox"\]\.toggle-switch:checked \{([\s\S]*?)\}/.exec(css);
  assert.ok(on, "ON の規則がある");
  assert.match(on[1], /background-color:\s*var\(--vscode-button-background/, "ON は青い地");
});

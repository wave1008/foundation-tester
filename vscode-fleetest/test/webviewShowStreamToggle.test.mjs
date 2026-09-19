// 「デバイスモニター」タブの「配信を表示する」チェックボックスの配線テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewSelectAllPersist.test.mjs と同じ。
// 契約は monitorWebviewMessages.ts の setShowStreamDuringRun(webview→host)/ showStreamDuringRun(host→webview)。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
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

test("チェックボックスはテスト実行ボタンと同じ行の末尾(右寄せ)に既定 ON で置かれる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const checkbox = document.getElementById("chk-show-stream-during-run");
  assert.ok(checkbox);
  assert.equal(checkbox.checked, true);
  const label = checkbox.closest("label");
  const row = document.getElementById("toolbar-run-row");
  assert.equal(label.parentElement, row, "テスト実行と同じ行");
  assert.equal(document.getElementById("btn-run-tests").parentElement, row);
  assert.equal(row.lastElementChild, label, "行の末尾");
  assert.ok(label.classList.contains("run-stream-toggle"), "右寄せ(margin-left:auto)の class");
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

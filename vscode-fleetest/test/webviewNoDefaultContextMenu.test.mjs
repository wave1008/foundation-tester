// モニターパネル(fleetest mobile)のどこで右クリックしても既定メニュー(Cut/Copy/Paste)を出さない(main.js の
// document の contextmenu = preventDefault)の DOM テスト。文字を打つ入力欄だけは既定メニューを残す。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewAndroidBridgeNotRunning.test.mjs と同じ。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

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

function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

/** 右クリックを送り、既定メニューが止められたか(defaultPrevented)を返す。 */
function rightClick(window, el) {
  const event = new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
  el.dispatchEvent(event);
  return event.defaultPrevented;
}

test("ツールバー・負荷グラフ・スプリッターでは既定メニューを出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  for (const id of ["toolbar", "host-metrics", "btn-run-tests", "chk-show-stream-during-run", "splitter"]) {
    const el = document.getElementById(id);
    assert.ok(el, `${id} がある`);
    assert.equal(rightClick(window, el), true, `${id} の右クリックは既定メニューを止める`);
  }
});

test("文字を打つ入力欄では既定メニューを残す(checkbox は止める)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const input = document.createElement("input");
  input.type = "text";
  document.getElementById("toolbar").appendChild(input);
  assert.equal(rightClick(window, input), false);
  assert.equal(rightClick(window, document.getElementById("settings-lpt")), true, "checkbox は文字を打たない");
});

test("他のタブ・タブバーでも既定メニューを出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  for (const id of ["tabbar", "panel-settings", "panel-profiles", "panel-recordings", "panel-dashboard", "panel-live", "panel-processes"]) {
    const el = document.getElementById(id);
    assert.ok(el, `${id} がある`);
    assert.equal(rightClick(window, el), true, `${id} の右クリックは既定メニューを止める`);
  }
});

test("設定タブの数値の入力欄では既定メニューを残す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const input = document.getElementById("settings-lpt-history");
  assert.equal(input.type, "number");
  assert.equal(rightClick(window, input), false);
});

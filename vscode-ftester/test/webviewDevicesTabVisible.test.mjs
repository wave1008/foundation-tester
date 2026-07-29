// モニター内タブの切替をホストへ知らせる配線(devicesTabVisible)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewHoverTip.test.mjs と同じ。
//
// 背景: デバイスタイルは他タブへ切り替えると display:none になるが、以前は webview 内で
// 閉じており、ホストの deviceStream.setVisible はパネル自体の表示/非表示でしか呼ばれなかった。
// そのため録画・プロファイル等のタブを見ている間も配信 helper と H.264 デコードが動き続けていた。
//
// 検証対象:
// - デバイス以外のタブへ切り替えると visible:false を送る
// - デバイスタブへ戻すと visible:true を送る
// - 起動時の初期タブでも 1 回送る(ホストが初期状態を知る唯一の経路)

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

/** window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない */
function createWebview() {
  const posted = [];
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

function visibilityMessages(posted) {
  return posted.filter((m) => m?.type === "devicesTabVisible");
}

function clickTab(document, id) {
  document.getElementById(`tab-${id}`).dispatchEvent(
    new document.defaultView.MouseEvent("click", { bubbles: true }),
  );
}

test("起動時の初期タブでも devicesTabVisible を1回送る", (t) => {
  const { window, posted } = createWebview();
  t.after(() => window.close());

  const messages = visibilityMessages(posted);
  assert.equal(messages.length, 1, "初期 switchTab で1回だけ送る");
  // 既定の初期タブは devices
  assert.equal(messages[0].visible, true);
});

test("デバイス以外のタブへ切り替えると visible:false を送る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  posted.length = 0;

  clickTab(document, "recordings");

  const messages = visibilityMessages(posted);
  assert.equal(messages.length, 1);
  assert.equal(messages[0].visible, false,
    "タイルが display:none の間は配信 helper とデコードを止められるようにする");
});

test("デバイスタブへ戻すと visible:true を送る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  clickTab(document, "settings");
  posted.length = 0;

  clickTab(document, "devices");

  const messages = visibilityMessages(posted);
  assert.equal(messages.length, 1);
  assert.equal(messages[0].visible, true);
});

test("同じタブを再クリックしても送らない(不要な再構築を起こさない)", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  clickTab(document, "processes");
  posted.length = 0;

  clickTab(document, "processes");

  assert.equal(visibilityMessages(posted).length, 0);
});

test("切替後にデバイスパネルが実際に display:none になっている(前提の確認)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  clickTab(document, "profiles");
  assert.equal(document.getElementById("panel-devices").style.display, "none",
    "この前提が崩れるとホストを止める配線ごと不要になる");

  clickTab(document, "devices");
  assert.equal(document.getElementById("panel-devices").style.display, "flex");
});

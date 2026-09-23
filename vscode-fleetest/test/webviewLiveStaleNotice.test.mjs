// webviewLiveStaleNotice.test.mjs
// デバイスモニターの「ライブ操作」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// harness は webviewLiveActionErrorDismiss.test.mjs と同型(renderHtml + main.js を実バンドルして
// window.eval で実行する)。
//
// 検証対象: snapshot イベントの notes(鮮度警告。契約: ApiLiveCommand.swift 冒頭・liveModel.ts の
// LiveSnapshot.notes)が action-error とは別枠の警告として出て、空配列に戻れば消えること。

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
  const vscodeStub = {
    Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) },
  };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = {
    asWebviewUri: (uri) => `https://localhost${uri.path}`,
    cspSource: "https://localhost",
  };
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
  const dom = new JSDOM(panelHtml, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url: "https://localhost/",
  });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: () => {},
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  window.document.getElementById("tab-live").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );

  const screenshot = window.document.getElementById("live-screenshot");
  screenshot.getBoundingClientRect = () => ({
    left: 0, top: 0, right: 400, bottom: 800, width: 400, height: 800, x: 0, y: 0,
  });

  return { window, document: window.document };
}

function sendLive(window, message) {
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "live", message } }));
}

const STALE_NOTE =
  "this screenshot may be stale: the element tree changed since the previous observation, but the image is byte-identical to the previous one";

function snapshotMessage(notes) {
  return {
    type: "snapshot",
    platform: "ios",
    screen: { width: 400, height: 800 },
    image: "AAAA",
    elements: [],
    notes,
  };
}

test("notes が空配列の間は枠自体が出ない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const notice = document.getElementById("live-stale-notice");
  assert.ok(!notice.classList.contains("visible"), "前提: 最初は出ていない");

  sendLive(window, snapshotMessage([]));
  assert.ok(!notice.classList.contains("visible"), "空配列では出ないこと");
});

test("notes が非空なら警告として出て、本文は CLI の英語文言をそのまま表示する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const notice = document.getElementById("live-stale-notice");
  const text = document.getElementById("live-stale-notice-text");

  sendLive(window, snapshotMessage([STALE_NOTE]));
  assert.ok(notice.classList.contains("visible"), "notes があれば出ること");
  assert.equal(text.textContent, STALE_NOTE, "本文は訳さずそのまま出すこと");
});

test("次の observation で notes が空に戻れば表示も消える", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const notice = document.getElementById("live-stale-notice");
  const text = document.getElementById("live-stale-notice-text");

  sendLive(window, snapshotMessage([STALE_NOTE]));
  assert.ok(notice.classList.contains("visible"));

  sendLive(window, snapshotMessage([]));
  assert.ok(!notice.classList.contains("visible"), "notes が空に戻れば消えること");
  assert.equal(text.textContent, "", "本文も空にすること");
});

test("デバイス切り替え(clearSnapshot)で前のデバイスの注記を持ち越さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const notice = document.getElementById("live-stale-notice");

  sendLive(window, snapshotMessage([STALE_NOTE]));
  assert.ok(notice.classList.contains("visible"));

  sendLive(window, { type: "clearSnapshot" });
  assert.ok(!notice.classList.contains("visible"), "clearSnapshot で消えること");
});

test("actionError とは別枠(片方が出ても他方の状態を変えない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const notice = document.getElementById("live-stale-notice");
  const actionError = document.getElementById("live-action-error");

  sendLive(window, snapshotMessage([STALE_NOTE]));
  assert.ok(notice.classList.contains("visible"), "notes の警告が出ること");
  assert.ok(!actionError.classList.contains("visible"), "action-error は出ないこと(操作は成功している)");

  sendLive(window, { type: "actionError", message: "some failure" });
  assert.ok(actionError.classList.contains("visible"), "actionError は出ること");
  assert.ok(notice.classList.contains("visible"), "actionError を出しても notes の表示は消えないこと");
});

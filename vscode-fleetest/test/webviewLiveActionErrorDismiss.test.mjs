// webviewLiveActionErrorDismiss.test.mjs
// デバイスモニターの「ライブ操作」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// renderHtml(monitorHtml.ts)を vscode スタブ付きでオンザフライ bundle して HTML を生成し、
// src/webview/monitor/main.js も esbuild(write:false)で bundle して window.eval で実行する
// (harness は webviewDevicesTabVisible.test.mjs と同型)。
// 実 VSCode webview との差分は acquireVsCodeApi / getBoundingClientRect / PointerEvent のみ
// (setPointerCapture は jsdom に無いが、liveTab.js 側が try/catch で握る契約なのでシム不要)。
//
// 検証対象: 操作エラーのバナーを利用者が消せること。
//
// 実害(2026-09-21): 自動で消えるのは host が復帰を検知した接続系の3文言だけ
// (monitorLiveController.ts の isConnectionClassMessage)で、ブリッジ接続拒否のように
// serve が返した文言は次の失敗で上書きされるまで残り、閉じる口も無かった。
// host 側のもう一方の口(操作成功で自動クリア)は liveSnapshotCacheRebind.test.mjs が走査で見る。

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
  // renderHtml を vscode スタブで実行して実 HTML を得る
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

  // webview バンドル(media/ 出力を経由せず現ソースから直接 bundle する)
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

/** 実 HTML+バンドルを読み込んだ webview 相当の DOM を作り、host への postMessage を捕捉する。
 * スクリプト実行(=webviewBundle の eval)の直後に「ライブ操作」タブへ切り替える(タブ切替は
 * main.js 側の ft-tab-activated 経由で visibility:true を発火させるのに必要)。 */
/** **window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない**
 * (node --test はファイル単位の子プロセスの終了を待つので、1本の閉じ忘れでスイート全体が
 * 止まる。2026-08-17 に実際に起き、npm test が終わらなくなった)。各 test は t.after で閉じる。 */
function createWebview() {
  const dom = new JSDOM(panelHtml, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url: "https://localhost/",
  });
  const { window } = dom;
  const posts = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posts.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  window.document.getElementById("tab-live").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );

  const screenshot = window.document.getElementById("live-screenshot");
  // jsdom はレイアウトを持たないため表示サイズを固定で与える(400x800)
  screenshot.getBoundingClientRect = () => ({
    left: 0, top: 0, right: 400, bottom: 800, width: 400, height: 800, x: 0, y: 0,
  });

  const sendToWebview = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  // jsdom レルムのオブジェクトは Object.prototype が異なり deepEqual が落ちるため JSON で正規化する
  const liveMessages = () => posts.filter((p) => p.type === "live").map((p) => JSON.parse(JSON.stringify(p.message)));
  return { window, document: window.document, posts, screenshot, sendToWebview, liveMessages };
}

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0, altKey = false }) {
  const event = new window.MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button,
    altKey,
  });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}


function showError(window, text) {
  window.dispatchEvent(new window.MessageEvent("message", {
    data: { type: "live", message: { type: "actionError", message: text } },
  }));
}

test("actionError はデバイスモニターと同じバナー: 本文クリックで閉じ、コピーでは閉じずに文言をコピーする", (t) => {
  const { window, document, posts } = createWebview();
  t.after(() => window.close());

  const banner = document.getElementById("live-action-error");
  const text = document.getElementById("live-action-error-text");
  const copy = document.getElementById("live-action-error-copy");
  assert.ok(banner.classList.contains("banner"), "デバイスモニターと同じ .banner の見た目");
  assert.ok(copy && copy.classList.contains("banner-copy"), "コピーボタンがあること");
  assert.ok(!banner.classList.contains("visible"), "前提: 最初は出ていない");

  showError(window, "Connection to the driver was refused (nothing listening on the port).");
  assert.ok(banner.classList.contains("visible"), "エラーが出ること");
  assert.match(text.textContent, /refused/, "本文は span 側に入ること(ボタンを消さない)");

  copy.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.ok(banner.classList.contains("visible"), "コピーでは閉じないこと");
  const copied = posts.filter((m) => m.type === "copyText");
  assert.equal(copied.length, 1);
  assert.match(copied[0].text, /refused/, "表示中の文言をコピーすること");

  text.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.ok(!banner.classList.contains("visible"), "本文クリックで消えること");
  assert.equal(text.textContent, "", "本文も空にすること");

  showError(window, "another failure");
  assert.ok(banner.classList.contains("visible"), "消したあとも次のエラーは出ること");
});

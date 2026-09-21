// webviewLiveSettleRefresh.test.mjs
// デバイスモニターの「ライブ操作」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// renderHtml(monitorHtml.ts)を vscode スタブ付きでオンザフライ bundle して HTML を生成し、
// src/webview/monitor/main.js も esbuild(write:false)で bundle して window.eval で実行する
// (harness は webviewDevicesTabVisible.test.mjs と同型)。
// 実 VSCode webview との差分は acquireVsCodeApi / getBoundingClientRect / PointerEvent のみ
// (setPointerCapture は jsdom に無いが、liveTab.js 側が try/catch で握る契約なのでシム不要)。
//
// 検証対象: 操作直後の一枚絵が**遷移の途中**だったときの撮り直し(liveTab.js の
// scheduleSettleRefresh)。
//
// 実害(2026-09-21): アプリスイッチャーを開いた状態でホームを押すと、クロスフェード中の絵が
// 届いてそのまま残った(薄くタスクが写っている)。配信が次のフレームを描けば最新になるが、
// 遷移が終わると画面は静止して配信も止まるため、誰も絵を差し替えない。
//
// 守る性質は2つ: 一度だけ撮り直すこと(静止画面で撮り続けない)と、配信が描けたら撮り直さないこと。
// 実時計で待つのはここだけ —— タイマーの発火そのものが検証対象なので、値を縮める口は作らない。

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


const SNAPSHOT = {
  type: "live",
  message: {
    type: "snapshot",
    platform: "ios",
    screen: { width: 400, height: 800 },
    image: "aW1n",
    elements: [],
  },
};

/** SETTLE_REFRESH_MS(700) を跨いで落ち着くまで待つ。 */
const afterSettleWindow = () => new Promise((resolve) => setTimeout(resolve, 1100));

test("操作直後の snapshot のあと、撮り直しを一度だけ要求する", async (t) => {
  const { window, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());

  sendToWebview(SNAPSHOT);
  const before = liveMessages().filter((m) => m.type === "refreshSnapshot").length;

  await afterSettleWindow();
  const refreshes = liveMessages().filter((m) => m.type === "refreshSnapshot");
  assert.equal(refreshes.length, before + 1, "遷移が終わった頃に撮り直しを要求すること");

  // その要求の結果として届いた snapshot では仕掛け直さない(静止画面で撮り続けない)
  sendToWebview(SNAPSHOT);
  await afterSettleWindow();
  assert.equal(
    liveMessages().filter((m) => m.type === "refreshSnapshot").length,
    before + 1,
    "撮り直しの結果でまた撮り直してはいけない",
  );
});

test("配信のフレームが描けたら撮り直さない", async (t) => {
  const { window, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());

  sendToWebview(SNAPSHOT);
  const before = liveMessages().filter((m) => m.type === "refreshSnapshot").length;
  // mjpeg 配信の 1 枚(host が frame を送る経路)。h264 の onFrameRendered と同じく「最新の絵が
  // 出た」ことを意味するので撮り直しは要らない
  sendToWebview({ type: "live", message: { type: "frame", image: "aW1n" } });

  await afterSettleWindow();
  assert.equal(
    liveMessages().filter((m) => m.type === "refreshSnapshot").length,
    before,
    "絵が来ているのに撮り直しを要求してはいけない",
  );
});

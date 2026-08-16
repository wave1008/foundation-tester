// 凍結表示(タイルの ❄️ バッジ)の DOM テスト。
// 実 HTML + 実バンドルを jsdom で動かす方式は webviewTileRelayout.test.mjs と同じ。
//
// 判定そのもの(一様フレームの連続)は Swift 側(MonitorFrozenDebounce)の担当で、
// ここが守るのは**受け取った frozen を落とさずに出すこと**だけ。
// 凍結はタイルの絵を見ても分からない(凍結中も最後のフレームが残る)ので、この表示が
// 消えると「モニターを見ていたのに気付かなかった」が起きる。表示はタイルのバッジのみ。

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
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

/** devices の指定: [{ frozen, state }] を並べる */
function sendDevices(window, specs) {
  const devices = specs.map((spec, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: spec.state ?? "connected",
    detail: "", kind: "virtual", udid: `UDID-${i}`, recording: false, registered: true,
    frozen: spec.frozen === true,
  }));
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
}

const visibleFrozenBadges = (document) =>
  [...document.querySelectorAll("#grid .badge-frozen")].filter((el) => el.style.display !== "none").length;

test("凍結ゼロならバッジを出さない(通常時にノイズを出さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}]);
  assert.equal(visibleFrozenBadges(document), 0);
});

test("凍結した台にだけバッジが付く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{ frozen: true }, {}, { frozen: true }]);
  assert.equal(visibleFrozenBadges(document), 2, "凍結した台にだけバッジを出すこと");
});

test("凍結が解けたらバッジも戻る(出しっぱなしにしない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{ frozen: true }, { frozen: true }]);
  assert.equal(visibleFrozenBadges(document), 2);
  sendDevices(window, [{}, {}]);
  assert.equal(visibleFrozenBadges(document), 0);
});

test("未接続の台にはバッジを出さない(落ちている機は凍結ではない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{ frozen: true, state: "booted" }, { frozen: true, state: "offline" }]);
  assert.equal(visibleFrozenBadges(document), 0);
});

test("frozen を送らない旧 CLI でも壊れない(バッジなし)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const devices = [{
    id: "d0", name: "Dev 0", platform: "ios", state: "connected", detail: "",
    kind: "virtual", udid: "UDID-0", recording: false, registered: true,
  }];
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
  assert.equal(visibleFrozenBadges(document), 0);
});

// ---- 表示は絵文字1文字・意味はホバーの説明 ------------------------------------------
// 文字(「凍結」/ "Frozen")をやめて ❄️ にしたので、**説明はホバーでしか読めない**。
// ネイティブ `title` は表示まで約1秒かかり、モニターの他の説明(hoverTip = 0.2秒)と体感が
// 違うため「出ない」と受け取られる(実際に指摘された)。**実際にホバーして出ることまで**見る。

/** 対象へ mouseover を送り、hoverTip の遅延ぶん待って出たツールチップを返す */
async function hoverTip(window, el) {
  el.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  await new Promise((resolve) => setTimeout(resolve, 260));
  return window.document.querySelector(".hover-tip");
}

test("タイルのバッジは ❄️ で、ホバーすると説明が出る", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{ frozen: true }]);
  const badge = [...document.querySelectorAll("#grid .badge-frozen")]
    .find((el) => el.style.display !== "none");
  assert.ok(badge, "凍結した台にバッジが出ていること");
  assert.equal(badge.textContent, "❄️", "バッジは絵文字1文字");
  const tip = await hoverTip(window, badge);
  assert.ok(tip, "ホバーしても説明が出ていない");
  assert.equal(tip.style.display, "block");
  assert.equal(tip.textContent, "デバイス凍結中");
  assert.equal(badge.title, "", "ネイティブ title が残ると同じ説明が二重に出る");
});

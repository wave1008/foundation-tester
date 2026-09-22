// run ボードのヘッダのプラットフォーム表示フィルタ(iOS / Android / すべて の3択。既定は「すべて」)
// の DOM テスト。選ばれていない側のデバイスは**4つのセクション**(実行中・デバイス一覧・
// 選択したデバイス・実行ログ)から同時に消える —— 落とすのは deviceTiles.js の applyDevices の
// 入口1箇所で、4つともそこから作られるため。
// 契約は monitorWebviewMessages.ts の setPlatformFilter / platformFilter。

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

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** iOS 2台・Android 1台。run ボードのレーンの鍵(udid/serial)と揃えてある。 */
function sendDevices(window) {
  post(window, { type: "devices", devices: [
    { id: "ios:A", name: "iPhone-01", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "U-1", recording: false, registered: true },
    { id: "ios:B", name: "iPhone-02", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "U-2", recording: false, registered: true },
    { id: "and:C", name: "Pixel-01", platform: "android", state: "connected", detail: "",
      kind: "virtual", serial: "S-1", recording: false, registered: true },
  ] });
}

const tileNames = (document) => [...document.querySelectorAll("#grid .tile .tile-name")].map((el) => el.textContent);
const boardNames = (document) => [...document.querySelectorAll(".run-board-lane-name")].map((el) => el.textContent);
const logNames = (document) => [...document.querySelectorAll("#lanes-grid .lane")]
  .filter((el) => el.style.display !== "none").map((el) => el.querySelector(".lane-header").textContent);
const previewCount = (document) => [...document.querySelectorAll("#preview-grid .lane-preview")]
  .filter((el) => el.style.display !== "none").length;
// 3択は**バッジ**(ユーザー決定 2026-09-22)。選んでいるものだけ .selected が付く
const badge = (document, value) => document.getElementById(`rad-platform-${value}`);
const pick = (window, document, value) => {
  badge(document, value).dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
};
const selectedBadges = (document) => ["ios", "android", "all"]
  .filter((value) => badge(document, value).classList.contains("selected"));

test("既定は「すべて」(フィルタを持たない状態と同じ見え方)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.deepEqual(selectedBadges(document), ["all"], "既定は「すべて」だけが色付き");
  assert.equal(badge(document, "all").getAttribute("aria-checked"), "true");
  assert.equal(badge(document, "ios").getAttribute("aria-checked"), "false");
  sendDevices(window);
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"]);
});

test("選んだプラットフォームだけが4つのセクションに残り、「すべて」でその場で戻る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  sendDevices(window);
  document.getElementById("chk-select-all").click();   // 全選択 = 実行ログと拡大表示にも出る
  assert.equal(logNames(document).length, 3, "前提: 実行ログに3台");
  assert.equal(previewCount(document), 3, "前提: 拡大表示に3台");
  assert.deepEqual(boardNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"], "前提: 実行中のツリーに3台");

  pick(window, document, "ios");
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02"], "デバイス一覧");
  assert.deepEqual(boardNames(document), ["iPhone-01", "iPhone-02"], "実行中");
  assert.deepEqual(logNames(document), ["iPhone-01", "iPhone-02"], "実行ログ");
  assert.equal(previewCount(document), 2, "選択したデバイス");
  // **次の監視サイクル(約2秒ごと)が来ても隠れたまま** —— 落とすのは applyDevices の入口なので、
  // ここを通さないと隠した台が次のサイクルで戻ってくる
  sendDevices(window);
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02"], "監視サイクル後も隠れたまま");
  assert.deepEqual(logNames(document), ["iPhone-01", "iPhone-02"], "監視サイクル後も隠れたまま(実行ログ)");

  pick(window, document, "android");
  assert.deepEqual(tileNames(document), ["Pixel-01"], "もう片方へ切り替えられる");

  // **次の監視サイクルを待たない** —— 切り替えたその場で戻る(生の一覧を控えてあるため)
  pick(window, document, "all");
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"]);

  // webview 側の realm で作られたオブジェクトなので、そのまま deepEqual すると prototype 違いで
  // 落ちる(値だけを取り出して比べる)
  assert.deepEqual(posted.filter((m) => m?.type === "setPlatformFilter").map((m) => m.value),
    ["ios", "android", "all"]);
});

test("host の復元値はバッジに入り、投げ返さない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  post(window, { type: "platformFilter", value: "android" });
  assert.deepEqual(selectedBadges(document), ["android"]);
  assert.deepEqual(tileNames(document), ["Pixel-01"]);
  assert.deepEqual(posted.filter((m) => m?.type === "setPlatformFilter"), [], "復元は送り返さない");
});

// 知らない値(古い形の保存値・壊れた設定)で**台が黙って消えない**こと
test("知らない復元値は「すべて」へ倒す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  post(window, { type: "platformFilter", value: "windows" });
  assert.deepEqual(selectedBadges(document), ["all"]);
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"]);
});

// 3つとも同じ幅・選択中の文字は白(ユーザー決定 2026-09-22)。**jsdom は CSS を読まない**ので
// 宣言そのものをテキストで押さえる(run ボードの CSS テストと同じ方式)
test("バッジは3つとも同じ幅で、iOS / Android の選択中は白フォント", async () => {
  const { readFileSync } = await import("node:fs");
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  const base = css.slice(css.indexOf(".platform-badge {"));
  const decl = base.slice(0, base.indexOf("}"));
  assert.match(decl, /min-width:\s*8ch/, "文字数で幅が変わらないよう下限を揃える");
  assert.match(decl, /text-align:\s*center/);
  // 見出し行の中央に置く(ユーザー決定 2026-09-22)。左の項目の幅に依存しない形で
  const group = css.slice(css.indexOf(".run-board-platform-filter {"));
  const groupDecl = group.slice(0, group.indexOf("}"));
  assert.match(groupDecl, /position:\s*absolute/);
  assert.match(groupDecl, /left:\s*50%/);
  assert.match(groupDecl, /transform:\s*translateX\(-50%\)/);
  for (const platform of ["ios", "android"]) {
    const rule = css.slice(css.indexOf(`.platform-badge-${platform}.selected {`));
    assert.match(rule.slice(0, rule.indexOf("}")), /color:\s*#ffffff/, platform);
  }
  const all = css.slice(css.indexOf(".platform-badge-all.selected {"));
  assert.match(all.slice(0, all.indexOf("}")), /color:\s*#1e1e1e/, "白地なので文字だけ暗色");
});

test("setPlatformFilter は host 側の検証を通り、知らない値は弾く", async () => {
  const { isMonitorFromWebviewMessage } = await import("../src/monitorWebviewMessages");
  for (const value of ["all", "ios", "android"]) {
    assert.equal(isMonitorFromWebviewMessage({ type: "setPlatformFilter", value }), true, value);
  }
  assert.equal(isMonitorFromWebviewMessage({ type: "setPlatformFilter", value: "windows" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "setPlatformFilter", ios: true, android: false }), false);
});

// webviewHoverTip.test.mjs
// hoverTip.js(0.2 秒ホバーで全文を出す自前ツールチップ)の DOM テスト。実 HTML+実バンドルで
// 動かす方式は webviewRecordingsTab.test.mjs と同じ(そちらの createWebview のコメント参照)。
//
// 自前実装にした理由はネイティブ title が遅延を指定できないこと。よって
// **「200ms 未満では出ない」「200ms 後に出る」の両方**を検証対象にする(片方だけだと
// 遅延ゼロ実装や表示されない実装が通ってしまう)。
//
// 検証対象:
// - デバイスタイル名・実行ログのレーン見出しに data-hover-tip が付く(ネイティブ title は使わない)
// - ホバー 199ms では非表示、200ms で全文が表示される
// - マウス離脱・スクロールで消える
// - 遅延中に要素が DOM から外れても表示しない(タイル再描画との競合)

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

const LONG_NAME = "iPhone 17 Pro Max(iOS 27.0)-01";

function applyDevices(window, devices) {
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
}

function device(name) {
  return {
    id: name, name, platform: "ios", state: "booted", kind: "virtual",
    udid: "UDID-1", recording: false,
  };
}

/** jsdom はレイアウトを持たないので getBoundingClientRect は全て 0 を返す。
 * 位置計算(はみ出し補正)は数値の妥当性までは見ず、表示/非表示のみを検証する */
function hover(window, el) {
  el.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
}

function tip(document) {
  return document.querySelector(".hover-tip");
}

function tipVisible(document) {
  const el = tip(document);
  return !!el && el.style.display === "block";
}

test("タイル名とレーン見出しに data-hover-tip が付く(ネイティブ title は使わない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  applyDevices(window, [device(LONG_NAME)]);

  const nameEl = document.querySelector(".tile-name");
  assert.ok(nameEl, "タイル名要素がある");
  assert.equal(nameEl.getAttribute("data-hover-tip"), `${LONG_NAME} (ios)`);
  // 祖先タイルの title が遅れて二重に出ないよう空にしてある
  assert.equal(nameEl.getAttribute("title"), "");

  // 実行ログのレーンは laneHydrate(monitorPanel.ts:340 が送る形)で構成される
  window.dispatchEvent(new window.MessageEvent("message", {
    data: {
      type: "laneHydrate",
      snapshot: {
        lanes: [{ id: "w1", name: LONG_NAME, platform: "ios" }],
        linesByLane: {}, runningWorkers: [],
      },
    },
  }));
  const laneName = document.querySelector(".lane-name");
  assert.ok(laneName, "レーン見出しが描画される");
  assert.equal(laneName.textContent, LONG_NAME);
  assert.equal(laneName.getAttribute("data-hover-tip"), LONG_NAME);
});

test("199ms では出ず 200ms で全文が出る", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  applyDevices(window, [device(LONG_NAME)]);
  const nameEl = document.querySelector(".tile-name");

  hover(window, nameEl);
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(tipVisible(document), false, "遅延前は出ない");

  await new Promise((r) => setTimeout(r, 120));
  assert.equal(tipVisible(document), true, "0.2 秒後に出る");
  assert.equal(tip(document).textContent, `${LONG_NAME} (ios)`, "省略されていない全文");
});

test("マウス離脱とスクロールで消える", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  applyDevices(window, [device(LONG_NAME)]);
  const nameEl = document.querySelector(".tile-name");

  hover(window, nameEl);
  await new Promise((r) => setTimeout(r, 260));
  assert.equal(tipVisible(document), true);
  nameEl.dispatchEvent(new window.MouseEvent("mouseout", { bubbles: true }));
  assert.equal(tipVisible(document), false, "離脱で即消える");

  hover(window, nameEl);
  await new Promise((r) => setTimeout(r, 260));
  assert.equal(tipVisible(document), true);
  // scroll は capture 登録(スクロールコンテナ内の発火を拾うため)
  document.body.dispatchEvent(new window.Event("scroll", { bubbles: false }));
  assert.equal(tipVisible(document), false, "スクロールで消える");
});

test("遅延中に要素が DOM から外れたら出さない", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  applyDevices(window, [device(LONG_NAME)]);
  const nameEl = document.querySelector(".tile-name");

  hover(window, nameEl);
  nameEl.remove();
  await new Promise((r) => setTimeout(r, 260));
  assert.equal(tipVisible(document), false);
});

// ---- ネイティブ title の自動の乗り換え(再発防止)----------------------------------------------
// ネイティブ title は VSCode の webview で出ない/約 1 秒待つので、title を書いた箇所が毎回
// 「説明が出ない」不具合になっていた。hoverTip.js が mouseover で自前へ移すので、書き手は title を
// 書くだけでよい。**どこに書いた title でも**(静的 HTML・後から JS で書いたもの・書き換え・祖先)出ること

test("静的 HTML の title(デバイスの健全性の列見出し)も 0.2 秒で自前のツールチップに出る", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const header = [...document.querySelectorAll("#table-device-health thead th")]
    .find((th) => (th.getAttribute("title") || th.getAttribute("data-hover-tip")));
  assert.ok(header, "説明付きの列見出しがある");
  const text = header.getAttribute("data-hover-tip") || header.getAttribute("title");

  hover(window, header);
  await new Promise((r) => setTimeout(r, 260));
  assert.equal(tipVisible(document), true);
  assert.equal(tip(document).textContent, text);
  assert.equal(header.getAttribute("title"), "", "ネイティブ title は空(二重に出さない)");
});

test("後から JS で書いた title・書き換えた title・祖先の title も自前のツールチップに出る", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const outer = document.createElement("div");
  outer.title = "祖先の説明";
  const inner = document.createElement("span");
  inner.textContent = "x";
  outer.appendChild(inner);
  const own = document.createElement("span");
  own.title = "最初の説明";
  document.body.append(outer, own);

  hover(window, own);
  await new Promise((r) => setTimeout(r, 260));
  assert.equal(tip(document).textContent, "最初の説明");
  own.dispatchEvent(new window.MouseEvent("mouseout", { bubbles: true }));

  own.title = "書き換えた説明";
  hover(window, own);
  await new Promise((r) => setTimeout(r, 260));
  assert.equal(tip(document).textContent, "書き換えた説明", "書き換えも次に載ったときに移す");
  own.dispatchEvent(new window.MouseEvent("mouseout", { bubbles: true }));

  hover(window, inner);
  await new Promise((r) => setTimeout(r, 260));
  assert.equal(tipVisible(document), true, "子に載っても祖先の説明が出る(ネイティブと同じ)");
  assert.equal(tip(document).textContent, "祖先の説明");
});

test("title=\"\" は祖先の説明を打ち切る(ネイティブと同じ)", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const outer = document.createElement("div");
  outer.title = "祖先の説明";
  const blocker = document.createElement("span");
  blocker.setAttribute("title", "");
  outer.appendChild(blocker);
  document.body.appendChild(outer);

  hover(window, blocker);
  await new Promise((r) => setTimeout(r, 260));
  assert.equal(tipVisible(document), false);
});

// webviewHoverTip.test.mjs
// hoverTip.js(0.2 秒ホバーで全文を出す自前ツールチップ)と、マシンプロファイル編集フォームの
// 機種/OS 取得要求の DOM テスト。実 HTML+実バンドルで
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
// - 機種/OS が取れないデバイスでも installedDevicesRequest が1回で止まる(無限 spawn 防止)

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

// ---- マシンプロファイル編集フォーム: 機種/OS の取得要求 ----------------------------
// installedDevicesRequest は毎回 `fleetest api installed-devices` を spawn する(devicectl +
// adb getprop で数秒)。値が埋まらないデバイスで応答→再描画→再要求のループに入ると
// CLI を叩き続けるため、**1デバイス1回**に絞れていることを回帰として固定する。

/** 機種/OS を持たない Android 実機 1 台だけのマシンプロファイルを webview に流し込み、
 * その 1 台を選択して編集フォームを開く(=機種/OS が空なので取得要求が出る状態)。 */
function openEditorForUnknownInfoDevice(window, document) {
  window.dispatchEvent(new window.MessageEvent("message", {
    data: {
      type: "machineProfileInfo", error: null, current: "M",
      machines: [{
        name: "M", path: "/M.json", deviceCount: 1,
        devices: [{
          name: "Pixel 4a", platform: "android", kind: "physical",
          serial: "SERIAL1", detail: "SERIAL1",
        }],
      }],
    },
  }));
  document.querySelector(".machine-device-row").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

test("機種/OS が取れないデバイスでも installed-devices の取得要求は1回だけ", async (t) => {
  const posts = [];
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const document = window.document;
  t.after(() => window.close());
  window.acquireVsCodeApi = () => ({
    postMessage: (m) => posts.push(m), setState: () => {}, getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  openEditorForUnknownInfoDevice(window, document);
  const countRequests = () => posts.filter((m) => m.type === "installedDevicesRequest").length;
  assert.equal(countRequests(), 1, "フォームを開いたら1回要求する");

  // 実機が未接続で physicalDevices が空の応答。これで再描画されても再要求してはいけない
  for (let i = 0; i < 3; i++) {
    window.dispatchEvent(new window.MessageEvent("message", {
      data: {
        type: "installedDevices", ok: true, error: null,
        data: {
          ios: { available: true, error: null, devices: [], physicalDevices: [] },
          android: { available: true, error: null, avds: [], physicalDevices: [] },
        },
      },
    }));
  }
  assert.equal(countRequests(), 1, "空応答が繰り返し届いても要求は増えない(無限ループ防止)");
});

// 「未登録」バッジの出し分けの DOM テスト(deviceTiles.js の renderUnregisteredBadge)。
//
// このバッジは「マシンプロファイルに無い台なので up と GPU 再起動が効かない」ことを言う。
// **「(起動中のデバイス)」を選んでいる間は出さない** —— このフィルタは登録に依らず動いて
// いる台を見るためのもので、そこでは未登録は例外ではなく普通の状態。全タイルに同じバッジが
// 並ぶだけで何も区別しない。他のフィルタでは今までどおり出す。
//
// 実 HTML+実バンドルを jsdom で動かす方式は webviewTileRelayout.test.mjs と同じ。

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

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** 全台が未登録(マシンプロファイルが2つ以上ある案件で `api monitor` が縮退したときの実データ)。 */
function sendAllUnregistered(window) {
  post(window, {
    type: "devices",
    devices: ["A", "B", "C"].map((name) => ({
      id: `ios:${name}`, name, platform: "ios", state: "connected", kind: "virtual",
      udid: `UDID-${name}`, recording: false, registered: false,
    })),
  });
}

/** 登録済み1台 + 未登録1台。 */
function sendDevices(window) {
  post(window, {
    type: "devices",
    devices: [
      {
        id: "ios:Registered", name: "Registered", platform: "ios", state: "booted", kind: "virtual",
        udid: "UDID-A", recording: false, registered: true,
      },
      {
        id: "ios:Stray", name: "Stray", platform: "ios", state: "booted", kind: "virtual",
        udid: "UDID-B", recording: false, registered: false,
      },
    ],
  });
}

/** 実行プロファイルの選択(filter==='running' が「(起動中のデバイス)」)。 */
function selectProfile(window, { filter, current = "" }) {
  post(window, { type: "profileInfo", profiles: ["prof1"], current, filter });
}

/** バッジが実際に見えているタイル名。 */
function badgedTiles(document) {
  return [...document.querySelectorAll("#grid .tile")]
    .filter((tile) => {
      const badge = tile.querySelector(".badge-unregistered");
      return badge !== null && badge.style.display !== "none";
    })
    .map((tile) => tile.querySelector(".tile-name").textContent);
}

test("既定(フィルタなし)では未登録の台にバッジを出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);

  assert.deepEqual(badgedTiles(document), ["Stray"]);
});

test("実行プロファイルを選んでいるときも出す(未登録が混ざっていること自体が情報)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  selectProfile(window, { filter: "", current: "prof1" });
  sendDevices(window);

  assert.deepEqual(badgedTiles(document), ["Stray"]);
});

test("「(起動中のデバイス)」を選んでいる間は出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  selectProfile(window, { filter: "running" });
  sendDevices(window);

  assert.deepEqual(badgedTiles(document), []);
});

test("切り替えはデバイスの再送を待たずに反映する(選び直した直後に残らない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  assert.deepEqual(badgedTiles(document), ["Stray"], "前提: 出ている");

  selectProfile(window, { filter: "running" });
  assert.deepEqual(badgedTiles(document), [], "次の監視サイクルを待たずに消える");

  selectProfile(window, { filter: "", current: "prof1" });
  assert.deepEqual(badgedTiles(document), ["Stray"], "戻したら戻る");
});

// バッジは「他と違う」ことを示すもの。区別しないなら出さない。
test("全台が未登録なら出さない(全タイルに同じバッジが並ぶだけで何も区別しない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendAllUnregistered(window);

  assert.equal(document.querySelectorAll("#grid .tile").length, 3, "前提: タイルは出ている");
  assert.deepEqual(badgedTiles(document), []);
});

test("登録済みが1台でも混ざれば、未登録の台に出す(そこでは区別になる)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendAllUnregistered(window);
  assert.deepEqual(badgedTiles(document), [], "前提");

  sendDevices(window); // 登録済み1台 + 未登録1台へ入れ替わる
  assert.deepEqual(badgedTiles(document), ["Stray"]);
});

// 判定は集合全体を見るので、**1枚ずつの描画では足りない** —— 未登録の台が先に来る並びだと、
// その時点では登録済みが1台も居らず「出さない」と決まってしまう。バッチを配り終えてから
// もう一度描き直すことでだけ正しくなる。
test("未登録の台が先に来る並びでも、同じバッチの登録済みを見て判定する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    devices: [
      {
        id: "ios:Stray", name: "Stray", platform: "ios", state: "booted", kind: "virtual",
        udid: "UDID-B", recording: false, registered: false,
      },
      {
        id: "ios:Registered", name: "Registered", platform: "ios", state: "booted", kind: "virtual",
        udid: "UDID-A", recording: false, registered: true,
      },
    ],
  });

  assert.deepEqual(badgedTiles(document), ["Stray"]);
});

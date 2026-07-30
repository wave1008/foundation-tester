// relayoutTiles(deviceTiles.js)が --tile-image-h を書く条件の DOM テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewDevicesTabVisible.test.mjs と同じ。
//
// 背景(実害): devices のポーリングは「デバイス」タブが非表示の間もホストから届き、
// applyDevices が relayoutTiles を呼ぶ。display:none 中は clientHeight=0 で下限 60px に
// 潰れるため、以前はそこで --tile-image-h が 60px に書き換わっていた。auto-fit
// (splitter.js の computeFitTilePaneHeight)は「今のペイン高さ ↔ 今の --tile-image-h」が
// 対応している前提の差分計算なので、タブへ戻ると過大な高さになりタイルがはみ出した。
//
// jsdom にはレイアウトが無く clientHeight は常に 0 なので、「レイアウトがあるとき」は
// 対象タイルの clientHeight を差し替えて再現する。

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
  window.acquireVsCodeApi = () => ({
    postMessage: () => {},
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function sendDevices(window, count) {
  const devices = Array.from({ length: count }, (_, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "booted", kind: "virtual",
    udid: `UDID-${i}`, recording: false,
  }));
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
}

function clickTab(document, id) {
  document.getElementById(`tab-${id}`).dispatchEvent(
    new document.defaultView.MouseEvent("click", { bubbles: true }),
  );
}

function tileImageHeight(document) {
  return document.getElementById("grid").style.getPropertyValue("--tile-image-h");
}

/** jsdom にレイアウトが無いぶんを補い、タイルに「表示されている高さ」を持たせる。 */
function fakeTileHeight(document, height) {
  for (const tile of document.querySelectorAll("#grid .tile")) {
    Object.defineProperty(tile, "clientHeight", { value: height, configurable: true });
  }
}

test("タブ非表示中に devices が届いても --tile-image-h を書き換えない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  fakeTileHeight(document, 306); // 306-66=240px の画像高さで表示中
  sendDevices(window, 2);
  assert.equal(tileImageHeight(document), "240px", "前提: 表示中は実測から書かれている");

  clickTab(document, "recordings");
  fakeTileHeight(document, 0); // display:none 相当
  sendDevices(window, 2);

  assert.equal(
    tileImageHeight(document),
    "240px",
    "非表示中に下限 60px を書くと、タブ復帰時の auto-fit が差分計算を誤ってはみ出す",
  );
});

test("台数が変わる場合も非表示中は書き換えない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  fakeTileHeight(document, 306);
  sendDevices(window, 2);

  clickTab(document, "profiles");
  fakeTileHeight(document, 0);
  sendDevices(window, 3);

  assert.equal(tileImageHeight(document), "240px");
});

test("レイアウトがあるときは実測高さから書く(ガードが広すぎないことの確認)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);

  fakeTileHeight(document, 200);
  sendDevices(window, 2);
  assert.equal(tileImageHeight(document), "134px", "200-66(TILE_CHROME_HEIGHT)");

  fakeTileHeight(document, 100);
  sendDevices(window, 2);
  assert.equal(tileImageHeight(document), "60px", "下限 60px は表示中には従来どおり効く");
});

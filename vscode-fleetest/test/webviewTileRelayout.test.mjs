// relayoutTiles(deviceTiles.js)が --tile-image-h を書く条件の DOM テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewDevicesTabVisible.test.mjs と同じ。
//
// 背景(実害): devices のポーリングは「デバイスモニター」タブが非表示の間もホストから届き、
// applyDevices が relayoutTiles を呼ぶ。display:none 中は clientHeight=0 で下限に
// 潰れるため、以前はそこで --tile-image-h が下限に書き換わり、タブへ戻っても画像が
// 下限の大きさのまま残った。
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
  // 306 - 66(TILE_CHROME_HEIGHT)- 22(マシン名の段 16 + gap 6)= 218px
  fakeTileHeight(document, 306);
  sendDevices(window, 2);
  assert.equal(tileImageHeight(document), "218px", "前提: 表示中は実測から書かれている");

  clickTab(document, "recordings");
  fakeTileHeight(document, 0); // display:none 相当
  sendDevices(window, 2);

  assert.equal(
    tileImageHeight(document),
    "218px",
    "非表示中に下限を書くと、タブ復帰後も画像が下限の大きさのまま残る",
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

  assert.equal(tileImageHeight(document), "218px");
});

test("レイアウトがあるときは実測高さから書く(ガードが広すぎないことの確認)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);

  // **下限(120)より大きくなる高さを与える** —— 下限に当たると「実測から書いた」ことを見ていない
  fakeTileHeight(document, 250);
  sendDevices(window, 2);
  assert.equal(tileImageHeight(document), "162px", "250 - 66(TILE_CHROME_HEIGHT)- 22(マシン名の段)");

  fakeTileHeight(document, 100);
  sendDevices(window, 2);
  assert.equal(tileImageHeight(document), "120px",
    "下限(MIN_TILE_IMAGE_HEIGHT)は表示中には従来どおり効く。**値をここで固定する** ——"
    + " 床はタイルの幅も決めるので、下げると台の中身が判別できない大きさに戻る");
});

// 機械名のバッジは**手元も含めて全タイルに出し、デバイス名の上に置く**
// (ユーザー決定 2026-09-22)。段が台ごとに出たり消えたりすると、共通の --tile-image-h では
// 絵の上端が揃わない。
test("タイルは手元にも local のバッジを名前の上の段に出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices: [
    { id: "d0", name: "Dev 0", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "U-0", recording: false, registered: true },
    { id: "d1", name: "Dev 1", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "U-1", recording: false, registered: true, machine: "m1max" },
  ] } }));
  const tiles = [...document.querySelectorAll("#grid .tile")];
  assert.equal(tiles.length, 2);
  assert.deepEqual(
    tiles.map((tile) => tile.querySelector(".tile-machine-row .badge-remote").textContent),
    ["local", "m1max"],
    "手元にも機械名を出す",
  );
  for (const tile of tiles) {
    assert.equal(tile.firstElementChild.className, "tile-machine-row", "段はデバイス名の上");
    assert.equal(tile.querySelector(".tile-machine-row .badge-remote").style.display, "inline-block");
  }
});

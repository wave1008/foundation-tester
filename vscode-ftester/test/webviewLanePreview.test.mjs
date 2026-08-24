// 出力ペインの拡大表示(選択したデバイスの動画)の DOM テスト。
// 実 HTML + 実バンドルを jsdom で動かす方式は webviewTileRelayout.test.mjs と同じ。
//
// 契約(ユーザー要件 2026-08-24): デバイスタブでフリートのデバイスを選ぶと、セパレーターの
// 下のペインは選択した台ぶんの拡大した動画を左から並べる(**ログは置かない**)。選択が無い
// 間は従来どおり全ワーカーの実行ログ(拡大表示は display:none)。
//
// 絵は「複製」で描く(canvas も img も DOM の2箇所に置けない)。mjpeg は同じ data URL を
// 別の img へ写すだけなので、ここでは **タイルと拡大表示が同じ src を指すこと**を見る。
// h264 の canvas 転写は jsdom に 2d コンテキストが無く描けないので対象外。

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

function sendDevices(window, specs) {
  const devices = specs.map((spec, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: spec.state ?? "connected",
    detail: "", kind: "virtual", udid: `UDID-${i}`, recording: false, registered: true,
  }));
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
}

function sendFrame(window, deviceId, jpegBase64) {
  window.dispatchEvent(new window.MessageEvent("message", {
    data: { type: "frame", device: deviceId, jpegBase64, stream: true },
  }));
}

// jsdom にはレイアウトが無く clientWidth/Height は常に 0。段組みの計算は実測値から決まるので、
// 「レイアウトがあるとき」を出力ペインの寸法差し替えで再現する(webviewTileRelayout.test.mjs と同じ手)。
function giveLanesGridSize(document, width, height) {
  const grid = document.getElementById("lanes-grid");
  Object.defineProperty(grid, "clientWidth", { value: width, configurable: true });
  Object.defineProperty(grid, "clientHeight", { value: height, configurable: true });
}

// タイルの縦横比はデコードできた画像の実寸からしか決まらない(deviceTiles.js)。
// jsdom は画像を読まないので、実寸を持った load を自分で起こす。
function decodeFrame(window, document, index, jpegBase64, naturalWidth, naturalHeight) {
  const device = `d${index}`;
  sendFrame(window, device, jpegBase64);
  const img = document.querySelectorAll("#grid .tile img")[index];
  Object.defineProperty(img, "naturalWidth", { value: naturalWidth, configurable: true });
  Object.defineProperty(img, "naturalHeight", { value: naturalHeight, configurable: true });
  img.dispatchEvent(new window.Event("load"));
}

function clickTile(document, index) {
  const tile = document.querySelectorAll("#grid .tile")[index];
  tile.dispatchEvent(new document.defaultView.MouseEvent("click", { bubbles: true }));
}

const visiblePairs = (document) =>
  [...document.querySelectorAll("#lanes-grid .lane-pair")].filter((el) => el.style.display !== "none");
const visiblePreviews = (document) =>
  [...document.querySelectorAll("#lanes-grid .lane-preview")].filter((el) => el.style.display !== "none");
// 隠れている列(選択で絞り込まれたレーン)の中のログは数えない
const paneTitle = (document) => document.getElementById("lanes-title").textContent;
const visibleLogs = (document) =>
  visiblePairs(document).map((pair) => pair.querySelector(".lane")).filter((el) => el.style.display !== "none");

test("選択が無い間は拡大表示を出さない(従来どおりログだけ)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  assert.equal(visiblePairs(document).length, 3, "全レーンを出すこと");
  assert.equal(visibleLogs(document).length, 3, "選択なしのときはログを出すこと");
  assert.equal(visiblePreviews(document).length, 0, "選択していないのに動画枠を出さないこと");
  assert.equal(paneTitle(document), "実行ログ");
});

test("1台選択でその台の動画だけになる(ログは置かない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  clickTile(document, 1);
  const pairs = visiblePairs(document);
  assert.equal(pairs.length, 1, "選択した台の列だけ残すこと");
  assert.equal(visiblePreviews(document).length, 1);
  assert.equal(visibleLogs(document).length, 0, "拡大表示の列にログを並べないこと");
  assert.equal(pairs[0].children[0].className, "lane-preview");
  // 見出しは中身に合わせる(ログではなく動画を並べている)
  assert.equal(paneTitle(document), "デバイス");
  // ログ側の DOM は消さない(選択を外せば続きが読める)
  assert.equal(pairs[0].querySelector(".lane-header").textContent, "Dev 1");
});

test("2台選択で動画が2つ、選択順ではなくデバイス順に並ぶ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  clickTile(document, 2);
  clickTile(document, 0);
  const pairs = visiblePairs(document);
  assert.equal(pairs.length, 2);
  assert.equal(visiblePreviews(document).length, 2, "選択した台ぶんの動画枠を出すこと");
  assert.equal(visibleLogs(document).length, 0);
  assert.deepEqual(
    pairs.map((pair) => pair.querySelector(".lane-header").textContent),
    ["Dev 0", "Dev 2"],
    "並びはタイルと同じデバイス順(deviceOrder)であること",
  );
});

test("選択を外すと拡大表示が消えてログへ戻る(出しっぱなしにしない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  assert.equal(visiblePreviews(document).length, 1);
  assert.equal(visibleLogs(document).length, 0);
  clickTile(document, 0);
  assert.equal(visiblePreviews(document).length, 0);
  assert.equal(visiblePairs(document).length, 2, "絞り込み解除で全レーンへ戻ること");
  assert.equal(visibleLogs(document).length, 2, "ログを出し直すこと");
  assert.equal(paneTitle(document), "実行ログ", "見出しも戻すこと");
});

test("拡大表示の上にフリートと同じタグが付く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}]);
  clickTile(document, 1);
  const header = visiblePreviews(document)[0].querySelector(".lane-preview-header");
  const name = header.querySelector(".tile-name");
  assert.ok(name, "デバイス名のピルを出すこと");
  assert.equal(name.textContent, "Dev 1");
  // 色分け(プラットフォーム)までタイルと同じであること
  assert.equal(name.className, document.querySelectorAll("#grid .tile-name")[1].className);
  // 絵はタグの下(タグ段 → 枠 の順)
  const wrap = visiblePreviews(document)[0];
  assert.equal(wrap.children[0].className, "lane-preview-header");
  assert.equal(wrap.children[1].className, "lane-preview-frame");
  // タグは描き直しのたびに作り直す(積み上げない)。devices もフレームも数秒おきに届くので、
  // 消さずに append すると DOM が青天井に増える
  sendDevices(window, [{}, {}]);
  sendFrame(window, "d1", "QUJD");
  assert.equal(header.querySelectorAll(".tile-header").length, 1);
});

test("実機・未登録・ホスト名のタグもフリートと同じに出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const devices = [{
    id: "d0", name: "Dev 0", platform: "android", state: "connected", detail: "",
    kind: "physical", udid: "UDID-0", recording: false, registered: false, machineHost: "m1max",
  }];
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
  clickTile(document, 0);
  const header = visiblePreviews(document)[0].querySelector(".lane-preview-header");
  const visibleBadges = [...header.querySelectorAll(".badge")].filter((el) => el.style.display !== "none");
  assert.deepEqual(
    visibleBadges.map((el) => el.textContent).sort(),
    [...document.querySelectorAll("#grid .tile-header .badge, #grid .tile-host-row .badge")]
      .filter((el) => el.style.display !== "none")
      .map((el) => el.textContent)
      .sort(),
    "タイルに出ているタグと同じ集合であること",
  );
  assert.ok(visibleBadges.some((el) => el.textContent === "m1max"), "ホスト名のタグを出すこと");
});

test("手元のデバイスにはホスト名の空段を作らない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}]);
  clickTile(document, 0);
  const header = visiblePreviews(document)[0].querySelector(".lane-preview-header");
  assert.equal(header.querySelectorAll(".tile-host-row").length, 0);
});

test("mjpeg のフレームはタイルと同じ絵が拡大表示にも出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  sendFrame(window, "d0", "QUJD");
  const preview = visiblePreviews(document)[0];
  const img = preview.querySelector(".lane-preview-frame img.lane-preview-media");
  assert.ok(img, "拡大表示に img を置くこと");
  assert.equal(img.getAttribute("src"), "data:image/jpeg;base64,QUJD");
  // 選択していない台の絵は拡大表示に出さない(レーンごと隠れている)
  sendFrame(window, "d1", "WFla");
  assert.equal(visiblePreviews(document).length, 1);
});

test("絵が無い台はタイルと同じプレースホルダを出す(黒い枠で放置しない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{ state: "offline" }]);
  clickTile(document, 0);
  const preview = visiblePreviews(document)[0];
  const placeholder = preview.querySelector(".lane-preview-frame .frame-placeholder");
  assert.ok(placeholder, "未起動の台には拡大表示にもプレースホルダを出すこと");
  assert.equal(placeholder.textContent, document.querySelector("#grid .frame-placeholder").textContent);
});

test("段組みは絵が一番大きくなる形にする(6台なら2段)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  giveLanesGridSize(document, 1200, 900);
  sendDevices(window, Array.from({ length: 6 }, () => ({})));
  // 先に6台を選ぶ(この時点では縦横比が分からないので横一列のまま)
  for (let i = 0; i < 6; i++) {
    clickTile(document, i);
  }
  const grid = document.getElementById("lanes-grid");
  assert.equal(grid.style.gridTemplateColumns, "repeat(6, minmax(0, 1fr))");
  // 絵が届いて縦横比が決まったら組み直す
  for (let i = 0; i < 6; i++) {
    decodeFrame(window, document, i, "QUJD", 390, 844);
  }
  assert.ok(grid.classList.contains("previewing"));
  // 1200x900 に縦持ち6台: 3列2段(横一列だと1台 200px 幅まで縮む)
  assert.equal(grid.style.gridTemplateColumns, "repeat(3, minmax(0, 1fr))");
  assert.equal(grid.style.gridTemplateRows, "repeat(2, minmax(0, 1fr))");
});

test("2台なら左右(横長のペイン)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  giveLanesGridSize(document, 1200, 900);
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  decodeFrame(window, document, 0, "QUJD", 390, 844);
  clickTile(document, 1);
  decodeFrame(window, document, 1, "QUJD", 390, 844);
  const grid = document.getElementById("lanes-grid");
  assert.equal(grid.style.gridTemplateColumns, "repeat(2, minmax(0, 1fr))");
  assert.equal(grid.style.gridTemplateRows, "repeat(1, minmax(0, 1fr))");
});

test("縦横比が混ざるときは一番横に広い台に合わせる(はみ出す台を作らない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  giveLanesGridSize(document, 1200, 900);
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  clickTile(document, 1);
  decodeFrame(window, document, 0, "QUJD", 390, 844);   // 縦持ち
  decodeFrame(window, document, 1, "QUJD", 844, 390);   // 横持ち(タブレット・回転)
  // 縦持ちだけなら左右(2列)が最大だが、横持ちが混ざると2列では横幅が足りず小さくなる
  const grid = document.getElementById("lanes-grid");
  assert.equal(grid.style.gridTemplateColumns, "repeat(1, minmax(0, 1fr))");
  assert.equal(grid.style.gridTemplateRows, "repeat(2, minmax(0, 1fr))");
});

test("ログへ戻したら段組みも横一列へ戻す(行の指定を残さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  giveLanesGridSize(document, 1200, 900);
  sendDevices(window, Array.from({ length: 6 }, () => ({})));
  for (let i = 0; i < 6; i++) {
    clickTile(document, i);
    decodeFrame(window, document, i, "QUJD", 390, 844);
  }
  for (let i = 0; i < 6; i++) {
    clickTile(document, i);
  }
  const grid = document.getElementById("lanes-grid");
  assert.equal(grid.classList.contains("previewing"), false);
  assert.equal(grid.style.gridTemplateColumns, "repeat(6, minmax(0, 1fr))");
  assert.equal(grid.style.gridTemplateRows, "");
});

test("選択したままデバイスが消えても拡大表示を残さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  sendFrame(window, "d0", "QUJD");
  assert.equal(visiblePreviews(document).length, 1);
  // d0 が居なくなる(モニター再起動・端末の取り外し)
  const devices = [{
    id: "d1", name: "Dev 1", platform: "ios", state: "connected", detail: "",
    kind: "virtual", udid: "UDID-1", recording: false, registered: true,
  }];
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
  assert.equal(document.querySelectorAll("#lanes-grid .lane-preview-media").length, 0);
  assert.equal(visiblePreviews(document).length, 0);
  assert.equal(visiblePairs(document).length, 1, "残った台は従来どおりログだけに戻ること");
  assert.equal(visibleLogs(document).length, 1);
});

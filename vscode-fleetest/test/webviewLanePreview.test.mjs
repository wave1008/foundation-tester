// 実行ログビュー(#log-pane)・グリッドビュー(#output-pane)の DOM テスト。
// 実 HTML + 実バンドルを jsdom で動かす方式は webviewTileRelayout.test.mjs と同じ。
//
// 契約(ユーザー要件 2026-09-21): 「デバイスモニター」タブは下段がグリッドビュー(選択した台の
// 拡大表示)と実行ログビュー(**ラインビューで選択した台のログだけ**。どちらも選択0台では空)の
// 2ペインに分かれる。**ちょうど1台選択のときだけ**、グリッドビューの中に 拡大表示|実行ログの複製
// (ミラー)を並べる ―― ログ本体の DOM は実行ログビュー側から動かさない。
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
// 「レイアウトがあるとき」を #preview-grid の寸法差し替えで再現する(webviewTileRelayout.test.mjs と同じ手)。
function givePreviewGridSize(document, width, height) {
  const grid = document.getElementById("preview-grid");
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

// jsdom にはレイアウトが無く getBoundingClientRect は全部 0 を返す。選択の当たり判定は
// **座標**で行う(deviceTiles.js の tileHitAtPoint)ので、タイルを横一列に並べた寸法を与える
// (webviewFleetMarquee.test.mjs の layoutTiles と同じ置き方)。与えないと全タイルが同じ
// 0 矩形になり、どこを押しても先頭のタイルに当たる。
function layoutTilesForHit(document) {
  const stub = (el, left, top, width, height) => {
    el.getBoundingClientRect = () => ({
      left, top, width, height, right: left + width, bottom: top + height, x: left, y: top,
    });
  };
  [...document.querySelectorAll("#grid .tile")].forEach((tile, i) => {
    stub(tile, i * 110, 0, 100, 200);
    stub(tile.querySelector(".frame-wrap"), i * 110 + 10, 30, 80, 140);
  });
}

// 選択の当たりはタイルの画像(.frame-wrap)。タイルの見出し・脚のクリックは全解除になる。
function clickTile(document, index) {
  layoutTilesForHit(document);
  const frame = document.querySelectorAll("#grid .tile .frame-wrap")[index];
  frame.dispatchEvent(new document.defaultView.MouseEvent("click", {
    bubbles: true, clientX: index * 110 + 50, clientY: 100,
  }));
}

const dblclick = (window, el) =>
  el.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
const selectedTileCount = (document) => document.querySelectorAll("#grid .tile.selected").length;

// 実行ログビュー(#lanes-grid の直接の子 .lane)。選択に応じて display で絞る。
const visibleLogs = (document) =>
  [...document.querySelectorAll("#lanes-grid .lane")].filter((el) => el.style.display !== "none");
// グリッドビューの拡大表示(#preview-grid の中の .lane-preview。1台選択時は .lane-pair の中)。
const visiblePreviews = (document) =>
  [...document.querySelectorAll("#preview-grid .lane-preview")].filter((el) => el.style.display !== "none");
const previewDeviceName = (el) => el.querySelector(".lane-preview-header .tile-name")?.textContent;
const visiblePreviewNames = (document) => visiblePreviews(document).map(previewDeviceName);
const logHeaderName = (laneEl) => laneEl.querySelector(".lane-header").textContent;

test("選択が無い間はグリッドビューも実行ログビューも空にする", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  // 台が1枚も来ていない時点から出す(欄が後から現れると見出しの並びが動く)
  assert.equal(document.getElementById("lanes-selection-status").textContent, "0台", "初期表示");
  sendDevices(window, [{}, {}, {}]);
  assert.equal(visibleLogs(document).length, 0, "選択した台だけを出すこと(0台なら1本も出さない)");
  assert.equal(visiblePreviews(document).length, 0, "選択していないのに動画枠を出さないこと");
  assert.equal(document.getElementById("lanes-title").textContent, "実行ログ");
  assert.equal(document.getElementById("grid-view-title").textContent, "選択したデバイス");
  assert.equal(document.getElementById("lanes-selection-status").textContent, "0台", "0台でも出す");
});

test("1台選択で実行ログビューはその台だけに絞り、グリッドビューは拡大表示+ログの複製を並べる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  clickTile(document, 1);

  assert.equal(visibleLogs(document).length, 1, "実行ログビューも選択に絞る");
  assert.equal(logHeaderName(visibleLogs(document)[0]), "Dev 1");
  assert.equal(document.getElementById("lanes-title").textContent, "実行ログ", "見出しは切り替えない");

  assert.equal(visiblePreviews(document).length, 1);
  const previewGrid = document.getElementById("preview-grid");
  assert.ok(previewGrid.classList.contains("single-device"));
  const pair = previewGrid.querySelector(".lane-pair");
  assert.ok(pair, "1台のときは .lane-pair で拡大表示とログの複製を束ねる");
  assert.equal(pair.children[0].className, "lane-preview", "左が動画");
  assert.equal(pair.children[1].className, "lane lane-log-mirror", "右がログの複製");
  assert.equal(pair.children[1].querySelector(".lane-log-title").textContent, "実行ログ");
  assert.equal(document.getElementById("grid-view-title").textContent, "選択したデバイス");
});

test("1台選択の動画の幅は絵に合わせ、2台に増やすとログの複製を解いて幅の指定も外す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  givePreviewGridSize(document, 1200, 500);
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  decodeFrame(window, document, 0, "QUJD", 390, 844);
  const grid = document.getElementById("preview-grid");
  assert.equal(grid.style.gridTemplateColumns, "minmax(0, 1fr)");
  assert.equal(grid.style.gridTemplateRows, "minmax(0, 1fr)");
  const preview = visiblePreviews(document)[0];
  // jsdom の枠の固定費は 0 なので 幅 = 500 × 390/844 の切り上げ(上限 1200×0.6 未満)
  assert.equal(preview.style.width, Math.ceil(500 * 390 / 844) + "px");

  clickTile(document, 1);
  decodeFrame(window, document, 1, "QUJD", 390, 844);
  assert.equal(grid.classList.contains("single-device"), false);
  assert.equal(grid.querySelector(".lane-pair"), null, "2台になったらログの複製の組は解く");
  assert.equal(visiblePreviews(document).length, 2);
  assert.equal(visibleLogs(document).length, 2, "実行ログビューは選択台数ぶん出す(拡大表示とは独立)");
  assert.ok(visiblePreviews(document).every((el) => el.style.width === ""), "幅の指定を残さない");
  assert.equal(grid.style.gridTemplateColumns, "repeat(2, minmax(0, 1fr))");
});

test("グリッドビューの台をダブルクリックすると、その台だけの選択になる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  clickTile(document, 0);
  clickTile(document, 2);
  assert.equal(visiblePreviews(document).length, 2);
  const target = visiblePreviews(document)[1];
  assert.equal(previewDeviceName(target), "Dev 2");
  dblclick(window, target);
  assert.equal(selectedTileCount(document), 1, "1台だけ選択");
  assert.equal(visiblePreviews(document).length, 1);
  assert.equal(previewDeviceName(visiblePreviews(document)[0]), "Dev 2", "ダブルクリックした台");
  assert.ok(document.getElementById("preview-grid").classList.contains("single-device"), "1台なので左に絵・右にログの複製");
});

test("このデバイスのみ選択の後、その台をダブルクリックすると直前の選択へ戻る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  clickTile(document, 0);
  clickTile(document, 2);
  const target = visiblePreviews(document)[1];
  dblclick(window, target);
  assert.equal(visiblePreviews(document).length, 1, "前提: その台だけになる");

  dblclick(window, visiblePreviews(document)[0]);
  assert.deepEqual(visiblePreviewNames(document), ["Dev 0", "Dev 2"], "直前の2台に戻る");
  assert.equal(selectedTileCount(document), 2);

  // 戻した後のダブルクリックは再び「その台のみ」(行き来できる)
  dblclick(window, visiblePreviews(document)[0]);
  assert.deepEqual(visiblePreviewNames(document), ["Dev 0"]);
});

test("全選択からこのデバイスのみ選択した後のダブルクリックは全選択に戻る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  document.getElementById("chk-select-all").click();
  assert.equal(selectedTileCount(document), 3, "前提: 全選択");
  dblclick(window, visiblePreviews(document)[1]);
  assert.equal(selectedTileCount(document), 1);
  dblclick(window, visiblePreviews(document)[0]);
  assert.equal(selectedTileCount(document), 3, "全台の選択に戻る");
  assert.equal(document.getElementById("chk-select-all").checked, true, "全選択の旗も戻る");
});

test("全選択に戻すときは、1台表示の間に現れた台も選ぶ(全選択の意味のまま)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  document.getElementById("chk-select-all").click();
  dblclick(window, visiblePreviews(document)[0]);
  assert.equal(selectedTileCount(document), 1);
  sendDevices(window, [{}, {}, {}, {}]);  // 4台目が現れる
  assert.equal(selectedTileCount(document), 1, "前提: 1台表示のまま");
  dblclick(window, visiblePreviews(document)[0]);
  assert.equal(selectedTileCount(document), 4, "現れた台も含めて全選択");
});

test("手で選択を変えた後は戻さない(ダブルクリックはその台のみ選択)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  clickTile(document, 0);
  clickTile(document, 1);
  clickTile(document, 2);
  dblclick(window, visiblePreviews(document)[0]);  // Dev 0 のみ
  clickTile(document, 1);  // 手で足す(Dev 0 + Dev 1)
  clickTile(document, 1);  // 手で外す(また Dev 0 のみ)
  dblclick(window, visiblePreviews(document)[0]);
  assert.deepEqual(visiblePreviewNames(document), ["Dev 0"], "選択を一度変えたら3台へは戻さない");
});

test("2台選択で動画が2つ・ログも2つ、選択順ではなくデバイス順に並ぶ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}, {}]);
  clickTile(document, 2);
  clickTile(document, 0);
  assert.equal(visiblePreviews(document).length, 2, "選択した台ぶんの動画枠を出すこと");
  assert.equal(visibleLogs(document).length, 2);
  assert.deepEqual(visiblePreviewNames(document), ["Dev 0", "Dev 2"], "並びはタイルと同じデバイス順(deviceOrder)であること");
  assert.deepEqual(visibleLogs(document).map(logHeaderName), ["Dev 0", "Dev 2"]);
});

test("選択を外すと拡大表示も実行ログも消える", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  assert.equal(visiblePreviews(document).length, 1);
  assert.equal(visibleLogs(document).length, 1, "1台選択中は実行ログビューも絞る");
  clickTile(document, 0);
  assert.equal(visiblePreviews(document).length, 0);
  assert.equal(document.getElementById("preview-grid").classList.contains("single-device"), false);
  assert.equal(document.getElementById("preview-grid").querySelector(".lane-pair"), null);
  assert.equal(visibleLogs(document).length, 0, "実行ログも選択に従って消えること");
});

test("拡大表示の上にラインビューと同じタグが付く", (t) => {
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

test("実機・未登録・マシン名のタグもラインビューと同じに出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const devices = [{
    id: "d0", name: "Dev 0", platform: "android", state: "connected", detail: "",
    kind: "physical", udid: "UDID-0", recording: false, registered: false, machine: "m1max",
  }];
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
  clickTile(document, 0);
  const header = visiblePreviews(document)[0].querySelector(".lane-preview-header");
  const visibleBadges = [...header.querySelectorAll(".badge")].filter((el) => el.style.display !== "none");
  assert.deepEqual(
    visibleBadges.map((el) => el.textContent).sort(),
    [...document.querySelectorAll("#grid .tile-header .badge, #grid .tile-machine-row .badge")]
      .filter((el) => el.style.display !== "none")
      .map((el) => el.textContent)
      .sort(),
    "タイルに出ているタグと同じ集合であること",
  );
  assert.ok(visibleBadges.some((el) => el.textContent === "m1max"), "ホスト名のタグを出すこと");
});

// 段数が台で変わると、その台だけ絵の上端が下がる(手元とリモートを並べると揃わない。
// 2026-08-24 のユーザー指摘)。段は常に2つ —— **手元にも実体のある "local" のバッジが出る**
// ので(ユーザー決定 2026-09-22)、高さを作るためのダミーはもう要らない。
test("タグの段数は手元でもリモートでも同じで、手元は local のバッジ(絵の上端を揃える)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const devices = [
    { id: "d0", name: "Dev 0", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "UDID-0", recording: false, registered: true },
    { id: "d1", name: "Dev 1", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "UDID-1", recording: false, registered: true, machine: "m1max" },
  ];
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
  clickTile(document, 0);
  clickTile(document, 1);
  const headers = [...document.querySelectorAll("#preview-grid .lane-preview-header")];
  assert.equal(headers.length, 2);
  for (const header of headers) {
    assert.equal(header.querySelectorAll(".tile-header").length, 1);
    assert.equal(header.querySelectorAll(".tile-machine-row").length, 1, "マシン名の段は常に置く");
  }
  const machineBadgeOf = (header) => header.querySelector(".tile-machine-row .badge-remote");
  // リモートはホスト名がそのまま見える
  assert.equal(machineBadgeOf(headers[1]).textContent, "m1max");
  assert.equal(machineBadgeOf(headers[1]).style.visibility, "");
  // 手元も実体のあるバッジ(隠しダミーではない)
  const local = machineBadgeOf(headers[0]);
  assert.equal(local.textContent, "local");
  assert.equal(local.style.visibility, "");
  // **機械名の段はデバイス名の上**(ユーザー決定 2026-09-22)
  for (const header of headers) {
    assert.equal(header.firstElementChild.className, "tile-machine-row", "段が先(= 上)");
  }
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
  givePreviewGridSize(document, 1200, 900);
  sendDevices(window, Array.from({ length: 6 }, () => ({})));
  // 先に6台を選ぶ(この時点では縦横比が分からないので横一列のまま)
  for (let i = 0; i < 6; i++) {
    clickTile(document, i);
  }
  const grid = document.getElementById("preview-grid");
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
  givePreviewGridSize(document, 1200, 900);
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  decodeFrame(window, document, 0, "QUJD", 390, 844);
  clickTile(document, 1);
  decodeFrame(window, document, 1, "QUJD", 390, 844);
  const grid = document.getElementById("preview-grid");
  assert.equal(grid.style.gridTemplateColumns, "repeat(2, minmax(0, 1fr))");
  assert.equal(grid.style.gridTemplateRows, "repeat(1, minmax(0, 1fr))");
});

test("縦横比が混ざるときは一番横に広い台に合わせる(はみ出す台を作らない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  givePreviewGridSize(document, 1200, 900);
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  clickTile(document, 1);
  decodeFrame(window, document, 0, "QUJD", 390, 844);   // 縦持ち
  decodeFrame(window, document, 1, "QUJD", 844, 390);   // 横持ち(タブレット・回転)
  // 縦持ちだけなら左右(2列)が最大だが、横持ちが混ざると2列では横幅が足りず小さくなる
  const grid = document.getElementById("preview-grid");
  assert.equal(grid.style.gridTemplateColumns, "repeat(1, minmax(0, 1fr))");
  assert.equal(grid.style.gridTemplateRows, "repeat(2, minmax(0, 1fr))");
});

test("選択解除で段組みも横一列(空)へ戻す(行の指定を残さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  givePreviewGridSize(document, 1200, 900);
  sendDevices(window, Array.from({ length: 6 }, () => ({})));
  for (let i = 0; i < 6; i++) {
    clickTile(document, i);
    decodeFrame(window, document, i, "QUJD", 390, 844);
  }
  for (let i = 0; i < 6; i++) {
    clickTile(document, i);
  }
  const grid = document.getElementById("preview-grid");
  assert.equal(grid.classList.contains("previewing"), false);
  assert.equal(grid.style.gridTemplateColumns, "");
  assert.equal(grid.style.gridTemplateRows, "");
  assert.equal(visibleLogs(document).length, 0, "実行ログビューも空へ戻る");
});

// 再起動の間は新しいフレームが来ないので、畳まないと最後の1枚が出たまま残る(タイルを
// 消すだけでは消えない —— 拡大表示はレーン側の DOM に居る)。
test("モニター再起動で拡大表示を畳む(古い絵を出したままにしない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{}, {}]);
  clickTile(document, 0);
  sendFrame(window, "d0", "QUJD");
  assert.equal(visiblePreviews(document).length, 1, "前提: 拡大表示が出ている");

  document.getElementById("btn-restart").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  assert.equal(document.querySelectorAll("#preview-grid .lane-preview-media").length, 0, "絵の要素ごと外すこと");
  assert.equal(visiblePreviews(document).length, 0);
  assert.equal(visibleLogs(document).length, 0, "選択が解けるのでログも出さない(レーン自体は残る)");
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
  assert.equal(document.querySelectorAll("#preview-grid .lane-preview-media").length, 0);
  assert.equal(visiblePreviews(document).length, 0);
  assert.equal(visibleLogs(document).length, 0, "消えた台の選択は残らないのでログも出ない");
});

// 実行ログビューのレーン見出しは、機械バッジをデバイス名の**下**に置く(ユーザー決定 2026-09-21。
// タイルと同じ並び)。段の有無がレーンごとに混ざると高さが揃わないので、**1つでも機械付きが
// 居れば全レーンで確保する** —— CSS はこのクラスで段を出す(jsdom は CSS を読まない)。
test("機械付きのレーンが1つでもあれば #lanes-grid に with-machine-row が付く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const grid = document.getElementById("lanes-grid");

  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices: [
    { id: "d0", name: "Dev 0", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "UDID-0", recording: false, registered: true },
  ] } }));
  assert.equal(grid.classList.contains("with-machine-row"), false, "手元だけなら段は要らない");

  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices: [
    { id: "d0", name: "Dev 0", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "UDID-0", recording: false, registered: true },
    { id: "d1", name: "Dev 1", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "UDID-1", recording: false, registered: true, machine: "m1max" },
  ] } }));
  assert.equal(grid.classList.contains("with-machine-row"), true);
  const hosts = [...document.querySelectorAll("#lanes-grid .lane-host")].map((el) => el.textContent);
  assert.deepEqual(hosts, ["m1max"], "機械バッジは機械付きのレーンにだけ出る(段は全レーンで確保)");
});

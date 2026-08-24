// フリート(デバイスタブ上段)の範囲選択の DOM テスト。
// 実 HTML + 実バンドルを jsdom で動かす方式は webviewTileRelayout.test.mjs と同じ。
//
// 契約(ユーザー要件 2026-08-24): タイルの上をドラッグすると矩形が出て、重なったデバイスが
// 選択される。動かさなければ従来どおりクリック(選択トグル)・空きエリアのクリックで全解除。
//
// 実 VSCode webview との差分は acquireVsCodeApi / getBoundingClientRect / PointerEvent /
// setPointerCapture のみ(いずれも jsdom に無いので下でシムする)。

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
  // 実 webview にはあるが jsdom に無い(ドラッグ中にポインタを掴み続けるためのもので、
  // 掴めなくてもこのテストの操作列は grid へ直接送るので影響しない)
  window.Element.prototype.setPointerCapture = () => {};
  window.Element.prototype.releasePointerCapture = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0, ctrlKey = false, metaKey = false }) {
  const event = new window.MouseEvent(type, {
    bubbles: true, cancelable: true, clientX: x, clientY: y, button, ctrlKey, metaKey,
  });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}

function sendDevices(window, count) {
  const devices = Array.from({ length: count }, (_, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "connected", detail: "",
    kind: "virtual", udid: `UDID-${i}`, recording: false, registered: true,
  }));
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "devices", devices } }));
}

// jsdom にはレイアウトが無いので、タイルの位置は自分で置く。
// 3台を横に並べる: タイルは 幅 100・間隔 10・高さ 200(y 0〜200)、その中の画像は
// 見出し(上 30px)と脚(下 30px)を除いた 80x140(選択の当たりは画像だけなので分けて置く)。
function layoutTiles(document, count) {
  const stub = (el, left, top, width, height) => {
    el.getBoundingClientRect = () => ({
      left, top, width, height, right: left + width, bottom: top + height, x: left, y: top,
    });
  };
  stub(document.getElementById("tile-pane"), 0, 0, 1000, 300);
  [...document.querySelectorAll("#grid .tile")].slice(0, count).forEach((tile, i) => {
    stub(tile, i * 110, 0, 100, 200);
    stub(tile.querySelector(".frame-wrap"), i * 110 + 10, 30, 80, 140);
  });
}

const imageOf = (document, index) => document.querySelectorAll("#grid .tile .frame-wrap")[index];
const tileOf = (document, index) => document.querySelectorAll("#grid .tile")[index];

/** 実ブラウザ同様 pointerdown/up を伴うクリック(座標つき。当たり判定は座標で決まる)。 */
function clickAt(window, target, x, y) {
  target.dispatchEvent(pointerEvent(window, "pointerdown", { x, y }));
  target.dispatchEvent(pointerEvent(window, "pointerup", { x, y }));
  target.dispatchEvent(new window.MouseEvent("click", {
    bubbles: true, cancelable: true, clientX: x, clientY: y,
  }));
}

/** 画像の中心をクリックする。 */
function clickImage(window, document, index) {
  clickAt(window, imageOf(document, index), index * 110 + 50, 100);
}

/** ドラッグの終わりに来る click だけを送る(pointerdown は先行しない)。 */
function trailingClickImage(window, document, index) {
  imageOf(document, index).dispatchEvent(new window.MouseEvent("click", {
    bubbles: true, cancelable: true, clientX: index * 110 + 50, clientY: 100,
  }));
}

/** grid の上を (x0,y0) → (x1,y1) へドラッグする。click は実ブラウザ同様に最後へ送る。 */
function drag(window, document, x0, y0, x1, y1, modifiers = {}) {
  const grid = document.getElementById("grid");
  grid.dispatchEvent(pointerEvent(window, "pointerdown", { x: x0, y: y0, ...modifiers }));
  grid.dispatchEvent(pointerEvent(window, "pointermove", { x: x1, y: y1, ...modifiers }));
  grid.dispatchEvent(pointerEvent(window, "pointerup", { x: x1, y: y1, ...modifiers }));
  grid.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, clientX: x1, clientY: y1 }));
}

const selectedNames = (document) =>
  [...document.querySelectorAll("#grid .tile.selected .tile-name")].map((el) => el.textContent);
const marquee = (document) => document.getElementById("tile-marquee");

test("矩形と重なったデバイスが選択される", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  drag(window, document, 50, 50, 150, 60);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
});

test("ドラッグ中だけ矩形を出す(位置はペイン基準・向きは問わない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  const grid = document.getElementById("grid");
  assert.equal(marquee(document).style.display, "");
  grid.dispatchEvent(pointerEvent(window, "pointerdown", { x: 300, y: 150 }));
  grid.dispatchEvent(pointerEvent(window, "pointermove", { x: 100, y: 50 }));
  assert.equal(marquee(document).style.display, "block");
  // 右下から左上へ引いても矩形は正の幅・高さ
  assert.equal(marquee(document).style.left, "100px");
  assert.equal(marquee(document).style.top, "50px");
  assert.equal(marquee(document).style.width, "200px");
  assert.equal(marquee(document).style.height, "100px");
  grid.dispatchEvent(pointerEvent(window, "pointerup", { x: 100, y: 50 }));
  assert.equal(marquee(document).style.display, "none", "離したら消すこと");
});

test("しきい値未満の動きは従来どおりクリック(タイルの選択トグル)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  const grid = document.getElementById("grid");
  grid.dispatchEvent(pointerEvent(window, "pointerdown", { x: 250, y: 50 }));
  grid.dispatchEvent(pointerEvent(window, "pointermove", { x: 252, y: 51 }));
  assert.equal(marquee(document).style.display, "", "手ぶれで矩形を出さないこと");
  grid.dispatchEvent(pointerEvent(window, "pointerup", { x: 252, y: 51 }));
  clickImage(window, document, 2);
  assert.deepEqual(selectedNames(document), ["Dev 2"]);
});

test("ドラッグの後のクリックで選択が消えない(掴んだタイルのトグル・空きの全解除を止める)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  // タイルの上から引き始め、タイルの上で離す(click の宛先はタイル)
  const grid = document.getElementById("grid");
  grid.dispatchEvent(pointerEvent(window, "pointerdown", { x: 20, y: 50 }));
  grid.dispatchEvent(pointerEvent(window, "pointermove", { x: 150, y: 60 }));
  grid.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 60 }));
  trailingClickImage(window, document, 0);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
  // 捨てるのは直後の1回だけ(次のクリックは通常どおり効く)
  clickImage(window, document, 0);
  assert.deepEqual(selectedNames(document), ["Dev 1"]);
});

test("範囲選択は置き換え(前の選択は残さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  clickImage(window, document, 2);
  assert.deepEqual(selectedNames(document), ["Dev 2"]);
  drag(window, document, 15, 50, 150, 60);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
});

test("何も重ならないドラッグは全解除(空きエリアのクリックと同じ)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  drag(window, document, 15, 50, 150, 60);
  assert.equal(selectedNames(document).length, 2);
  drag(window, document, 400, 220, 600, 280);
  assert.deepEqual(selectedNames(document), []);
});

test("Cmd(Ctrl)を押しながらなら前の選択を残して足せる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  drag(window, document, 15, 50, 50, 60);
  assert.deepEqual(selectedNames(document), ["Dev 0"]);
  drag(window, document, 230, 50, 300, 60, { metaKey: true });
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 2"], "Cmd で追加");
  drag(window, document, 118, 50, 150, 60, { ctrlKey: true });
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1", "Dev 2"], "Ctrl でも同じ");
  // 押さずに引き直せば置き換えに戻る
  drag(window, document, 118, 50, 150, 60);
  assert.deepEqual(selectedNames(document), ["Dev 1"]);
});

test("Cmd ありでも重なった台は二重に入らない(既に選ばれている台をなぞる)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  drag(window, document, 15, 50, 150, 60);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
  drag(window, document, 15, 50, 260, 60, { metaKey: true });
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1", "Dev 2"]);
});

test("デバイスの画像はドラッグできない(掴むとブラウザのドラッグが始まり範囲選択が切れる)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  layoutTiles(document, 2);
  window.dispatchEvent(new window.MessageEvent("message", {
    data: { type: "frame", device: "d0", jpegBase64: "QUJD", stream: true },
  }));
  const tileImg = document.querySelector("#grid .tile img");
  assert.equal(tileImg.draggable, false);
  // 拡大表示の絵も同じ
  clickImage(window, document, 0);
  const previewImg = document.querySelector("#lanes-grid .lane-preview-media");
  assert.equal(previewImg.draggable, false);
});

test("中ボタンのドラッグ(横スクロール)では矩形を出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  const grid = document.getElementById("grid");
  grid.dispatchEvent(pointerEvent(window, "pointerdown", { x: 50, y: 50, button: 1 }));
  grid.dispatchEvent(pointerEvent(window, "pointermove", { x: 300, y: 120, button: 1 }));
  assert.equal(marquee(document).style.display, "");
  assert.deepEqual(selectedNames(document), []);
  grid.dispatchEvent(pointerEvent(window, "pointerup", { x: 300, y: 120, button: 1 }));
});

// 押し損ねで選択を全部失わないよう、タイルの中は「画像の帯なら選択トグル・それ以外は何もしない」。
// 解除はタイルの外(グリッドの空きエリア)だけ(ユーザー決定 2026-08-24)。
test("画像の上下(見出し・脚)のクリックは選択を変えない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  clickImage(window, document, 0);
  clickImage(window, document, 1);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
  // 画像の上(見出しの帯 y 0〜30)
  clickAt(window, document.querySelector("#grid .tile .tile-header"), 50, 10);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
  // 画像の左右の余白の、さらに上下(タイルの角。x は画像の外・y は帯の外)
  clickAt(window, tileOf(document, 0), 5, 10);
  clickAt(window, tileOf(document, 0), 95, 190);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
});

test("解除は画像の高さの外(グリッドの上下の余白)だけ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  clickImage(window, document, 2);
  assert.deepEqual(selectedNames(document), ["Dev 2"]);
  // 画像は y 30〜170。その下の余白(y 250)を押すと解除
  clickAt(window, document.getElementById("grid"), 500, 250);
  assert.deepEqual(selectedNames(document), []);
});

// タイルの隙間は 8px しかなく狙って押すものではない(実害 2026-08-24: 選択が飛ぶ)。
test("タイルとタイルの間でも画像の高さに収まっていれば解除しない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  clickImage(window, document, 0);
  clickImage(window, document, 2);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 2"]);
  // タイル0(〜100)とタイル1(110〜)の隙間 x 105・画像の高さの中 y 100
  clickAt(window, document.getElementById("grid"), 105, 100);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 2"]);
  // 同じ隙間でも画像より上(y 10)なら解除
  clickAt(window, document.getElementById("grid"), 105, 10);
  assert.deepEqual(selectedNames(document), []);
});

test("範囲選択も画像だけを見る(見出し・脚をかすめただけでは選ばない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  // y 0〜20 はタイルの見出しの帯(画像は y 30 から)
  drag(window, document, 0, 0, 400, 20);
  assert.deepEqual(selectedNames(document), []);
  // 画像の帯まで下ろせば選ばれる
  drag(window, document, 0, 0, 400, 40);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1", "Dev 2"]);
});

// 実害の witness(2026-08-24): グリッドの外で離したドラッグの click は grid に来ない。
// 「ドラッグ直後の click を捨てる」旗をそこで落とさないと、次の普通のクリックが1回消える。
test("グリッドの外で離したドラッグの次のクリックを飲み込まない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  const grid = document.getElementById("grid");
  grid.dispatchEvent(pointerEvent(window, "pointerdown", { x: 15, y: 50 }));
  grid.dispatchEvent(pointerEvent(window, "pointermove", { x: 150, y: 60 }));
  // ペインの外で離す = click は grid ではなく上位の共通祖先で起きるので grid には届かない
  grid.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 400 }));
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
  clickImage(window, document, 2);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1", "Dev 2"], "1回目のクリックで選ばれること");
});

// 当たりは「画像の高さの帯 × タイル幅」(ユーザー決定 2026-08-24)。タイルは画像より広いことが
// あり(見出しのバッジで広がる)、その左右の余白を押したときに何も起きないと押し損ねに見える。
test("画像の左右の余白のクリックはそのデバイスのクリック", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  // タイル1は x 110〜210・画像は x 120〜200。左右の余白(x 112 / x 208)を押す
  clickAt(window, tileOf(document, 1), 112, 100);
  assert.deepEqual(selectedNames(document), ["Dev 1"]);
  clickAt(window, tileOf(document, 1), 208, 100);
  assert.deepEqual(selectedNames(document), [], "同じデバイスなのでトグルで外れる");
});

test("画像の下(脚)のクリックは選択もしないし解除もしない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  clickImage(window, document, 1);
  assert.deepEqual(selectedNames(document), ["Dev 1"]);
  // 画像は y 30〜170、その下(y 180)はタイルの中だが帯の外
  clickAt(window, tileOf(document, 1), 150, 180);
  assert.deepEqual(selectedNames(document), ["Dev 1"]);
  // 未選択の台の脚を押しても選ばれない
  clickAt(window, tileOf(document, 2), 260, 180);
  assert.deepEqual(selectedNames(document), ["Dev 1"]);
});

test("範囲選択も左右の余白を含む(画像に触れなくても帯に入れば選ぶ)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  layoutTiles(document, 3);
  // x 95〜118 はタイル0の右端の余白(画像は〜90)とタイル1の左端の余白(画像は 120〜)。
  // どちらの画像にも触れていないが、当たりの帯には入っている
  drag(window, document, 95, 100, 118, 120);
  assert.deepEqual(selectedNames(document), ["Dev 0", "Dev 1"]);
});

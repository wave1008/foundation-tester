// 実機タイルの「ブリッジ操作」文言の DOM テスト(deviceTiles.js の shuttingDown/
// physicalBridgeStarting 分岐)。
//
// 実機は端末そのものを起動・停止しない —— タイル操作で動くのはブリッジだけなので、
// 「シャットダウン中/起動中」ではなく「ブリッジを停止中/起動中」と言う(ユーザー指摘)。
//
// 起動側は queued/running/awaitingStateAfterUp の3状態すべてで「ブリッジ未起動」を
// 経由させない: 実機は device.state が 'offline' に落ちないため、up 完了直後に
// awaitingStateAfterUp が立たないと、次の devices サイクルが来るまでの間だけ
// 「ブリッジ未起動」が混じって点滅する(実害)。
//
// 実 HTML+実バンドルを jsdom で動かす方式は webviewAndroidBridgeNotRunning.test.mjs と同じ。

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

const deviceId = "android:Pixel 実機";
const deviceName = "Pixel 実機";

/** Android 実機1台を送る(bridgeRunning は呼び出し側が指定)。 */
function sendPhysicalAndroid(window, bridgeRunning) {
  post(window, {
    type: "devices",
    devices: [{
      id: deviceId, name: deviceName, platform: "android", state: "connected", kind: "physical",
      serial: "14141JEC204922", recording: false, bridgeRunning,
    }],
  });
}

/** 比較対照(退行防止): 仮想デバイス(エミュレータ/シミュレータ)。 */
function sendVirtual(window, state) {
  post(window, {
    type: "devices",
    devices: [{
      id: "android:Emu 1", name: "Emu 1", platform: "android", state, kind: "virtual",
      serial: "emulator-5554", recording: false,
    }],
  });
}

function sendFrame(window, id) {
  post(window, { type: "frame", device: id, jpegBase64: "AAAA", width: 100, height: 200 });
}

function tile(document) {
  return document.querySelector("#grid .tile");
}

function placeholderText(document) {
  return tile(document).querySelector(".frame-placeholder")?.textContent ?? "";
}

function showsImage(document) {
  return tile(document).querySelector(".frame-wrap img") !== null;
}

function queuedChipText(document) {
  const chip = tile(document).querySelector(".badge-queued");
  return chip && chip.style.display !== "none" ? chip.textContent : "";
}

test("実機 + 起動(up)キュー待ち: チップは「ブリッジ起動待ち」", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, false);
  post(window, { type: "deviceOpBusy", name: deviceName, op: "up", status: "queued" });

  const text = queuedChipText(document);
  assert.match(text, /ブリッジ起動待ち/);
  assert.doesNotMatch(text, /^起動待機$/, "実機の端末を起動するわけではない");
});

test("実機 + 停止(down)キュー待ち: チップは「ブリッジ停止待ち」", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, true);
  post(window, { type: "deviceOpBusy", name: deviceName, op: "down", status: "queued" });

  const text = queuedChipText(document);
  assert.match(text, /ブリッジ停止待ち/);
  assert.doesNotMatch(text, /再起動待機/, "実機のブリッジ停止は再起動ではない");
});

test("退行防止: 仮想デバイスのキュー待ちチップは従来どおり", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendVirtual(window, "offline");
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: "up", status: "queued" });
  assert.match(queuedChipText(document), /起動待機/);

  post(window, { type: "deviceOpBusy", name: "Emu 1", op: "down", status: "queued" });
  assert.match(queuedChipText(document), /再起動待機/);
});

test("実機 + ブリッジ停止(down)実行中: 「ブリッジを停止中」(「シャットダウン中」ではない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, true);
  post(window, { type: "deviceOpBusy", name: deviceName, op: "down", status: "running" });

  const text = placeholderText(document);
  assert.match(text, /ブリッジを停止中/);
  assert.doesNotMatch(text, /^シャットダウン中$/);
});

test("退行防止: 仮想デバイス + down 実行中は従来どおり「シャットダウン中」", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendVirtual(window, "connected");
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: "down", status: "running" });

  assert.match(placeholderText(document), /シャットダウン中/);
});

for (const [label, setup] of [
  ["queued", (window) => {
    sendPhysicalAndroid(window, false);
    post(window, { type: "deviceOpBusy", name: deviceName, op: "up", status: "queued" });
  }],
  ["running", (window) => {
    sendPhysicalAndroid(window, false);
    post(window, { type: "deviceOpBusy", name: deviceName, op: "up", status: "running" });
  }],
  ["awaitingStateAfterUp(完了直後、次の devices サイクル前)", (window) => {
    sendPhysicalAndroid(window, false);
    post(window, { type: "deviceOpBusy", name: deviceName, op: "up", status: "running" });
    post(window, { type: "deviceOpBusy", name: deviceName, op: null, status: null });
  }],
]) {
  test(`実機 + ブリッジ起動(up)が ${label}: 「ブリッジを起動中」を表示し「ブリッジ未起動」を出さない`, (t) => {
    const { window, document } = createWebview();
    t.after(() => window.close());
    setup(window);

    const text = placeholderText(document);
    assert.match(text, /ブリッジを起動中/);
    assert.doesNotMatch(text, /ブリッジ未起動/);
  });
}

test("実機 + 操作なし + bridgeRunning===false: 従来どおり「ブリッジ未起動」", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, false);

  assert.match(placeholderText(document), /ブリッジ未起動/);
});

test("実機 + 起動完了 + 画像が来ている: 画像を出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, false);
  post(window, { type: "deviceOpBusy", name: deviceName, op: "up", status: "running" });
  post(window, { type: "deviceOpBusy", name: deviceName, op: null, status: null });
  sendFrame(window, deviceId);
  // 実際に画像が出るのは次の devices 観測が bridgeRunning:true を伝えたとき
  // (awaitingStateAfterUp の間は offline のままなのでプレースホルダを保つ)。
  assert.equal(showsImage(document), false, "観測が更新されるまではプレースホルダのまま");

  sendPhysicalAndroid(window, true);
  sendFrame(window, deviceId);
  assert.equal(showsImage(document), true);
});

// ブリッジ停止完了直後、遅れて届く devices 観測が停止より前の bridgeRunning:true を運んでくる
// ことがある(生死プローブはモニターの1サイクルの頭で走るため)。この回だけ無視しないと、
// 「停止中」→ 画像が一瞬再表示 → 「未起動」という指摘のちらつきになる(bridgeStoppedLocally)。
function completeBridgeDown(window) {
  post(window, { type: "deviceOpBusy", name: deviceName, op: "down", status: "running" });
  post(window, { type: "deviceOpBusy", name: deviceName, op: null, status: null });
}

test("実機 + ブリッジ停止完了 + 直後の観測が bridgeRunning:true でも画像を出さない(指摘の再現)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, true);
  completeBridgeDown(window);

  sendPhysicalAndroid(window, true);
  sendFrame(window, deviceId);
  assert.equal(showsImage(document), false, "1回目の running 観測はまだ信じない");
  assert.match(placeholderText(document), /ブリッジ未起動/);
});

test("実機 + ブリッジ停止完了 + 観測が bridgeRunning:false: 印は畳まれ「ブリッジ未起動」のまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, true);
  completeBridgeDown(window);

  sendPhysicalAndroid(window, false);
  sendFrame(window, deviceId);
  assert.equal(showsImage(document), false);
  assert.match(placeholderText(document), /ブリッジ未起動/);
});

test("実機 + ブリッジ停止完了 + 2回連続で bridgeRunning:true: 停止が効かなかったとみなし画像を出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, true);
  completeBridgeDown(window);

  sendPhysicalAndroid(window, true);
  sendFrame(window, deviceId);
  assert.equal(showsImage(document), false, "1回目はまだ無視する");

  sendPhysicalAndroid(window, true);
  sendFrame(window, deviceId);
  assert.equal(showsImage(document), true, "2回連続なら停止は効いていないので観測を信じる");
});

test("実機 + ブリッジ停止完了後に新しい起動(up)操作: 印を引きずらず即座に観測を信じる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendPhysicalAndroid(window, true);
  completeBridgeDown(window);

  post(window, { type: "deviceOpBusy", name: deviceName, op: "up", status: "running" });
  post(window, { type: "deviceOpBusy", name: deviceName, op: null, status: null });
  // up 完了後、最初の devices 観測が bridgeRunning:true を伝えたら即座に画像を出す。
  // 停止時の印(bridgeStoppedLocally)が畳まれずに残っていると、1回だけ無視するロジックに
  // 巻き込まれてこの回では画像が出ない(退行)。
  sendPhysicalAndroid(window, true);
  sendFrame(window, deviceId);
  assert.equal(showsImage(document), true);
});

test("退行防止: 仮想デバイスの down 完了後(deviceDownFinished)の挙動は変わらない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendVirtual(window, "connected");
  sendFrame(window, "android:Emu 1");
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: "down", status: "running" });
  post(window, { type: "deviceDownFinished", name: "Emu 1" });

  assert.equal(showsImage(document), false, "offline 先行反映でプレースホルダのまま");
  assert.doesNotMatch(placeholderText(document), /ブリッジ未起動/, "仮想デバイスは端末の未起動と言う");

  sendVirtual(window, "connected");
  sendFrame(window, "android:Emu 1");
  assert.equal(showsImage(document), true, "次の devices 観測で通常どおり画像に戻る");
});

test("退行防止: 仮想デバイスの個別 down 完了直後にフレームが来ても画像を出す(bridgeStoppedLocally は実機専用)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendVirtual(window, "connected");
  sendFrame(window, "android:Emu 1");
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: "down", status: "running" });
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: null, status: null });
  // devices 観測を挟まず直接フレームを送る。device.state はまだ 'connected' のまま
  // (仮想デバイスの個別 down では offline 先行反映が無い)なので、bridgeStoppedLocally が
  // 誤って立っていれば offline 扱いになり画像が消える。実機専用のはずなので消えてはいけない。
  sendFrame(window, "android:Emu 1");
  assert.equal(showsImage(document), true);
});

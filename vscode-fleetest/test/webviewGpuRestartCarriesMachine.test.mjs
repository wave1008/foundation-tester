// タイルの「GPU で再起動」が **(machine, name)** で宛先を言うことの DOM テスト。
//
// 実害の形: リモートのタイルも CPU バッジ(renderMode==='cpu')を出すのでメニューは出るが、
// 名前だけを送っていたため、拡張は手元の `api restart-devices --name` を撃ち**手元の同名の台**が
// 再起動された。deviceOp(起動/停止)は machine を載せていたのに、この経路だけ落ちていた。
// 一括起動の restartNames(start-all-devices --restart)は手元へしか中継されないので、リモートの
// CPU バッジ機は含めない(含めると同じ形で手元の同名の台が再起動される)。
//
// 実 HTML+実バンドルを jsdom で動かす方式は webviewRemoteTilePlaceholder.test.mjs と同じ。

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
  const sent = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => sent.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, sent };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** 手元 1 台 + M1Max 1 台(同名)。どちらも CPU 描画で connected = CPU バッジとメニューが出る形 */
function sendCpuDevices(window) {
  post(window, {
    type: "devices",
    devices: [
      {
        id: "android:Dev 1", name: "Dev 1", platform: "android", state: "connected", kind: "virtual",
        serial: "emulator-5554", renderMode: "cpu", recording: false,
      },
      {
        id: "android:M1Max/Dev 1", name: "Dev 1", platform: "android", state: "connected", kind: "virtual",
        serial: "emulator-5556", renderMode: "cpu", recording: false, machine: "M1Max",
      },
    ],
  });
}

function rightClickGpuRestart(window, document, tile) {
  tile.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));
  const gpuBtn = document.getElementById("device-op-menu-gpu");
  assert.notEqual(gpuBtn.style.display, "none", "CPU バッジのタイルには「GPU で再起動」が出る");
  gpuBtn.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
}

test("リモートのタイルの「GPU で再起動」は machine を載せて送る(手元は machine 無し)", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  sendCpuDevices(window);
  const [local, remote] = document.querySelectorAll("#grid .tile");

  rightClickGpuRestart(window, document, remote);
  const remoteMsg = sent.find((m) => m.type === "deviceRestartGpu");
  // jsdom の realm で作られたオブジェクトは Node 側の Object.prototype と違うので、素の deepEqual は
  // 「same structure but not reference-equal」で落ちる。JSON で写してから比べる
  assert.deepStrictEqual(JSON.parse(JSON.stringify(remoteMsg)),
                         { type: "deviceRestartGpu", name: "Dev 1", machine: "M1Max" });

  sent.length = 0;
  rightClickGpuRestart(window, document, local);
  const localMsg = sent.find((m) => m.type === "deviceRestartGpu");
  assert.equal(localMsg.name, "Dev 1");
  assert.equal(localMsg.machine, undefined, "手元は machine を持たない(= 手元の意味)");
});

test("「デバイスを全て起動」の restartNames にリモートの CPU バッジ機を混ぜない", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    devices: [
      {
        id: "android:M1Max/Dev 1", name: "Dev 1", platform: "android", state: "connected", kind: "virtual",
        serial: "emulator-5556", renderMode: "cpu", recording: false, machine: "M1Max",
      },
      {
        id: "android:Dev 2", name: "Dev 2", platform: "android", state: "connected", kind: "virtual",
        serial: "emulator-5554", renderMode: "cpu", recording: false,
      },
    ],
  });
  document.getElementById("btn-devices-up").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  const up = sent.find((m) => m.type === "devicesUp");
  assert.deepStrictEqual(JSON.parse(JSON.stringify(up)), { type: "devicesUp", restartNames: ["Dev 2"] },
    "start-all-devices --restart は手元へしか中継されないので、リモートの名前は手元の同名の台を再起動してしまう");
});

// 「マシン有効」off の機械の台は、タイルの右クリックから起動できない(停止は残す)
test("マシン有効が off の機械の台は、右クリックの「起動」が理由付きで押せない(停止・有効な機械は従来どおり)", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    devices: [
      { id: "android:M1mini/Off", name: "Off", platform: "android", state: "offline", kind: "virtual",
        recording: false, machine: "M1mini" },
      { id: "android:M1mini/On", name: "On", platform: "android", state: "connected", kind: "virtual",
        serial: "emulator-5554", recording: false, machine: "M1mini" },
      { id: "android:M1Max/Off", name: "Off", platform: "android", state: "offline", kind: "virtual",
        recording: false, machine: "M1Max" },
    ],
  });
  post(window, { type: "remoteConfig", hosts: [
    { machine: "M1mini", host: "u@mini", dir: "", enabled: false },
    { machine: "M1Max", host: "u@max", dir: "", enabled: true },
  ] });
  const [offMini, onMini, offMax] = document.querySelectorAll("#grid .tile");
  const item = document.getElementById("device-op-menu-item");
  const openMenu = (tile) => tile.dispatchEvent(
    new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));

  openMenu(offMini);
  assert.equal(item.disabled, true, "無効な機械の未起動の台は起動できない");
  assert.match(item.textContent, /マシン無効|machine off/);
  item.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(sent.some((m) => m.type === "deviceOp"), false, "押しても送らない");

  openMenu(onMini);
  assert.equal(item.disabled, false, "無効な機械でも起動中の台は停止できる");
  assert.equal(item.dataset.op, "down");

  openMenu(offMax);
  assert.equal(item.disabled, false, "有効な機械の台は起動できる");
  assert.equal(item.dataset.op, "up");
});

// 起動中・起動待ちの1台は右クリックから取り消せる(一括起動・再起動のバッチの台は取り消せない)
test("起動中の1台は「起動をキャンセル」で deviceUpCancel を machine 付きで送る・cancellable 無しは押せない", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    devices: [
      { id: "android:M1Max/A", name: "A", platform: "android", state: "offline", kind: "virtual",
        recording: false, machine: "M1Max" },
      { id: "android:B", name: "B", platform: "android", state: "offline", kind: "virtual", recording: false },
    ],
  });
  post(window, { type: "deviceOpBusy", name: "A", machine: "M1Max", op: "up", status: "running", cancellable: true });
  post(window, { type: "deviceOpBusy", name: "B", op: "up", status: "running" });
  const [a, b] = document.querySelectorAll("#grid .tile");
  const item = document.getElementById("device-op-menu-item");
  const openMenu = (tile) => tile.dispatchEvent(
    new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));

  openMenu(a);
  assert.equal(item.disabled, false);
  assert.equal(item.dataset.op, "cancelUp");
  assert.match(item.textContent, /起動をキャンセル|Cancel Start/);
  item.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.deepStrictEqual(JSON.parse(JSON.stringify(sent.find((m) => m.type === "deviceUpCancel"))),
    { type: "deviceUpCancel", name: "A", machine: "M1Max" });
  assert.equal(sent.some((m) => m.type === "deviceOp"), false, "起動/停止としては送らない");

  openMenu(b);
  assert.equal(item.disabled, true, "一括起動などの台(cancellable 無し)は従来どおり押せない");
  assert.equal(item.dataset.op, "up");
});

// 待機中の台の起動をキャンセルしたとき、「起動中」を経ずに「キャンセル中」→「未起動」になる
test("起動待ちをキャンセルすると「キャンセル中」を出し、busy が外れたら「起動中」を挟まず未起動へ戻る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    devices: [{ id: "android:A", name: "A", platform: "android", state: "offline", kind: "virtual", recording: false }],
  });
  post(window, { type: "deviceOpBusy", name: "A", op: "up", status: "queued", cancellable: true });
  const [tile] = document.querySelectorAll("#grid .tile");
  const label = () => tile.querySelector(".frame-placeholder")?.textContent ?? "";
  const queuedBadge = () => tile.querySelector(".badge-queued");

  tile.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));
  document.getElementById("device-op-menu-item").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.match(label(), /キャンセル中|Cancelling/, "押した直後は取り消し中と言う");
  assert.equal(queuedBadge().style.display, "none", "「起動待機」のチップを残さない");

  post(window, { type: "deviceOpBusy", name: "A", op: null, status: null });
  assert.doesNotMatch(label(), /起動中|Booting|Starting/, "起動していないのに「起動中」を出さない");
  assert.match(label(), /未起動|Not started|Offline/i);
});

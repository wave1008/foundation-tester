// 起動完了の直後に一瞬「待機中 / 起動待機」へ戻らないことの DOM テスト。
//
// 実害(2026-08-29 の報告): 一括起動で「起動中」→ **一瞬「待機中」** →(画面)という
// ちらつきが出ていた。CLI の deviceFinished はモニターの観測サイクル(既定2秒)より先に
// 来るので、busy を剥がした時点では state がまだ offline のまま = 「一括起動中の未起動機」の
// 条件に合致してしまうため。
//
// 規律: **次の観測が来るまで**は起動中を保つ(時間では消さない = 定数を置かない)。
// 観測が来たら、その内容が offline でも畳む —— それはもう推測ではなく事実だから。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);
let panelHtml, webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")], bundle: true, platform: "node",
    format: "cjs", target: "node18", write: false, external: ["vscode"], logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(
    mod, mod.exports, (id) => (id === "vscode" ? vscodeStub : require2(id)));
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" }, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")], bundle: true, platform: "browser",
    format: "iife", target: "es2022", write: false, logLevel: "silent",
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

function sendDevices(window, state) {
  post(window, {
    type: "devices",
    devices: [{
      id: "android:Emu 1", name: "Emu 1", platform: "android", state, kind: "virtual",
      serial: "emulator-5554", recording: false,
    }],
  });
}

function tileText(document) {
  const tile = document.querySelector("#grid .tile");
  return {
    placeholder: tile.querySelector(".frame-placeholder")?.textContent ?? "",
    chip: tile.querySelector(".badge-queued")?.textContent ?? "",
  };
}

test("起動完了の直後(次の観測が来る前)は「起動中」のまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, "offline");
  post(window, { type: "bootBusy", busy: true, bulkOp: "up" });

  post(window, { type: "deviceOpBusy", name: "Emu 1", op: "up", status: "running" });
  assert.match(tileText(document).placeholder, /起動中/);

  // CLI の deviceFinished 相当。**ここで待機中へ戻らないこと**が本題
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: null, status: null });
  const after = tileText(document);
  assert.match(after.placeholder, /起動中/, "一瞬「待機中」へ戻っている");
  assert.equal(after.chip, "", "「起動待機」チップも出さない");
});

test("次の観測が来たらそれに従う(まだ offline なら待機中へ戻る)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, "offline");
  post(window, { type: "bootBusy", busy: true, bulkOp: "up" });
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: "up", status: "running" });
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: null, status: null });

  sendDevices(window, "offline"); // 観測が「まだ未起動」と言った = 事実
  assert.match(tileText(document).placeholder, /待機中/, "観測が来ても起動中に居座ってはいけない");
});

// 「デバイスを全て起動」は実行中だけ「デバイスの起動を中断」に変わる。**同じ位置の同じボタンが
// 別の操作になる**ので、色でも区別が付くようにする(2026-08-29 の指示。見た目は
// style.css の button.bulk-cancel)。
test("一括起動の実行中だけ、ボタンが中断表示 + 赤系クラスになる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, "offline");
  const btn = document.getElementById("btn-devices-up");

  assert.equal(btn.classList.contains("bulk-cancel"), false, "通常時に赤くしない");

  post(window, { type: "bootBusy", busy: true, bulkOp: "up" });
  assert.equal(btn.textContent, "デバイスの起動を中断");
  assert.equal(btn.classList.contains("bulk-cancel"), true);

  post(window, { type: "bootBusy", busy: false, bulkOp: null });
  assert.equal(btn.textContent, "デバイスを全て起動");
  assert.equal(btn.classList.contains("bulk-cancel"), false, "終わったら戻す");
});

test("一括終了(down)の実行中は赤くしない(中断ボタンではない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, "connected");

  post(window, { type: "bootBusy", busy: true, bulkOp: "down" });
  assert.equal(document.getElementById("btn-devices-up").classList.contains("bulk-cancel"), false);
});

test("起動が実って観測が来れば通常表示へ移る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, "offline");
  post(window, { type: "bootBusy", busy: true, bulkOp: "up" });
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: "up", status: "running" });
  post(window, { type: "deviceOpBusy", name: "Emu 1", op: null, status: null });

  sendDevices(window, "booted");
  assert.doesNotMatch(tileText(document).placeholder, /待機中|起動中/);
});

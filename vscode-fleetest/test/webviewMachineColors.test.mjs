// webviewMachineColors.test.mjs
// リモートマシンのバッジ色(machineColors.js)の DOM テスト。実 HTML+実バンドルで動かす方式は
// webviewHoverTip.test.mjs と同じ(そちらのコメント参照)。
//
// **パレットの定義は CLI が持つ**(拡張は定数を持たない)。remoteConfig の machineColors[]
// (鍵→hex)と hosts[].color(machine→鍵)から、既に描かれている `.badge-remote` を塗り直す
// (deviceTiles.js の「デバイスモニター」タブのタイル・laneLog.js の実行ログレーン見出しの両方が対象。
// syncLanesToDevices は applyDevices と同じサイクルで動くため、1回の devices 送信で両方に
// バッジが立つ)。
//
// 具体的な色文字列(#rrggbb vs jsdom が正規化する rgb())には依存せず、「塗られたか
// (空でないか)」「2つの異なる鍵が異なる色になるか」「既定(空)に戻るか」だけを見る。

import assert from "node:assert/strict";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
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

function createWebview(onPost = () => {}) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: onPost, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function device(name, machine) {
  return {
    id: name, name, platform: "ios", state: "booted", kind: "virtual",
    udid: "UDID-1", recording: false, machine,
  };
}

function remoteConfig(hosts, machineColors) {
  return { type: "remoteConfig", hosts, machineColors };
}

test("色付きのマシンは タイル/レーンの両方の .badge-remote が塗られる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "devices", devices: [device("iPhone 17", "M1Ultra")] });
  post(window, remoteConfig(
    [{ machine: "M1Ultra", host: "user@m1u", dir: "", color: "rose" }],
    [{ key: "rose", color: "#f6c1cc" }, { key: "sky", color: "#bcd6f5" }],
  ));

  const badges = [...document.querySelectorAll(".badge-remote[data-machine='M1Ultra']")];
  assert.ok(badges.length >= 2, "タイルとレーンの両方に立つ");
  for (const badge of badges) {
    assert.notEqual(badge.style.backgroundColor, "", "塗られている");
  }
});

test("パレットに無い鍵・未設定のマシンは既定(無地)のまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "devices", devices: [device("iPhone 17", "M1Max")] });
  post(window, remoteConfig(
    [{ machine: "M1Max", host: "user@m1max", dir: "", color: "" }],
    [{ key: "rose", color: "#f6c1cc" }],
  ));

  const badge = document.querySelector(".badge-remote[data-machine='M1Max']");
  assert.ok(badge);
  assert.equal(badge.style.backgroundColor, "", "未設定は既定のまま");
});

test("machineColors が配列でない(古い CLI)は色機能を黙って無効にする", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "devices", devices: [device("iPhone 17", "M1Ultra")] });
  post(window, { type: "remoteConfig", hosts: [{ machine: "M1Ultra", host: "user@m1u", dir: "", color: "rose" }] });

  const badge = document.querySelector(".badge-remote[data-machine='M1Ultra']");
  assert.equal(badge.style.backgroundColor, "", "パレット未受信では塗らない");
});

test("2つの異なる鍵は異なる色になる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "devices", devices: [device("A", "M1Ultra"), device("B", "M1Max")] });
  post(window, remoteConfig(
    [
      { machine: "M1Ultra", host: "user@m1u", dir: "", color: "rose" },
      { machine: "M1Max", host: "user@m1max", dir: "", color: "sky" },
    ],
    [{ key: "rose", color: "#f6c1cc" }, { key: "sky", color: "#bcd6f5" }],
  ));

  const rose = document.querySelector(".badge-remote[data-machine='M1Ultra']");
  const sky = document.querySelector(".badge-remote[data-machine='M1Max']");
  assert.notEqual(rose.style.backgroundColor, "");
  assert.notEqual(sky.style.backgroundColor, "");
  assert.notEqual(rose.style.backgroundColor, sky.style.backgroundColor, "違う鍵は違う色");
});

// config が devices より後着でも、既に描かれたバッジへ反映する(repaintMachineBadges)
test("remoteConfig が devices より後に届いても、既存のバッジが塗り直される", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "devices", devices: [device("iPhone 17", "M1Ultra")] });
  const before = document.querySelector(".badge-remote[data-machine='M1Ultra']");
  assert.equal(before.style.backgroundColor, "", "config 未着の間は無地");

  post(window, remoteConfig(
    [{ machine: "M1Ultra", host: "user@m1u", dir: "", color: "rose" }],
    [{ key: "rose", color: "#f6c1cc" }],
  ));
  const after = document.querySelector(".badge-remote[data-machine='M1Ultra']");
  assert.notEqual(after.style.backgroundColor, "", "後着の config で塗られる");
});

// 手元の台に切り替わったら(machine が無くなったら)dataset/色の両方を外す
test("手元の台に切り替わるとバッジの色・data-machine が外れる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "devices", devices: [device("iPhone 17", "M1Ultra")] });
  post(window, remoteConfig(
    [{ machine: "M1Ultra", host: "user@m1u", dir: "", color: "rose" }],
    [{ key: "rose", color: "#f6c1cc" }],
  ));
  assert.notEqual(document.querySelector(".tile .badge-remote").style.backgroundColor, "");

  post(window, { type: "devices", devices: [device("iPhone 17", undefined)] });
  const badge = document.querySelector(".tile .badge-remote");
  assert.equal(badge.style.backgroundColor, "", "色が外れる");
  assert.equal(badge.dataset.machine, undefined, "data-machine も外れる");
});

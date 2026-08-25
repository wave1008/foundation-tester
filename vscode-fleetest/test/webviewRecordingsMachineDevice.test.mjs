// webviewRecordingsMachineDevice.test.mjs
// 「録画」タブが**どのマシンのどの台で撮ったか**を出すことの DOM E2E(jsdom)。
// ハーネスの作り(renderHtml を vscode スタブ付きで bundle → main.js を window.eval)は
// test/webviewRecordingsTab.test.mjs と同じ。
//
// 供給元: recordingsSessions の machine/devices(run.json + recordings/index.json。recordingsStore.ts)と
// recordingsSession の machine/devices(scenarioID ごと。monitorRecordingsController.ts)。
// マシンはホスト名なのでタイル/マシンプロファイルと同じ .badge-remote、台は同じ配色ピル .tile-name。

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
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" },
    { path: "" },
  );

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
  const video = window.document.getElementById("recordings-video");
  video.load = () => {};
  video.play = () => Promise.resolve();
  video.pause = () => {};
  window.document.getElementById("tab-recordings").click();
  return { window, sendToWebview: (data) => window.dispatchEvent(new window.MessageEvent("message", { data })) };
}

const session = (over) => ({
  project: "SampleApp",
  runID: "20260724-000000",
  runIDs: ["20260724-000000"],
  startedAt: "2026-07-24T00:00:00Z",
  machine: "M1Max",
  machines: ["M1Max"],
  devices: [{ platform: "ios", device: "iPhone 16", machine: "M1Max" }],
  passed: 1,
  failed: 0,
  clipsAttempted: 1,
  clipsFailed: 0,
  encoderFallback: false,
  ...over,
});

const androidFleet = (count) =>
  Array.from({ length: count }, (_, i) => ({ platform: "android", device: `Pixel 9-0${i + 1}`, machine: "M1Max" }));

function sessionRows(window) {
  return [...window.document.getElementById("recordings-sessions").querySelectorAll(".recordings-session-item")];
}

test("セッション一覧の行に実行マシンと台を出す", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "recordingsSessions", sessions: [session()] });

  const meta = sessionRows(window)[0].querySelector(".recordings-session-meta");
  assert.ok(meta, "マシン/台の段がある");
  assert.equal(meta.querySelector(".badge-remote").textContent, "M1Max");
  const pill = meta.querySelector(".tile-name");
  assert.equal(pill.textContent, "iPhone 16");
  assert.ok(pill.classList.contains("tile-name-ios"), "台のピルは platform の配色になる");
  assert.match(pill.title, /iPhone 16/, "省略されても全文が読めるよう title に名前を持つ");
});

test("台が多い run は先頭3台+「ほかN台」に畳み、全台名は title に残す", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "recordingsSessions", sessions: [session({ devices: androidFleet(8) })] });

  const meta = sessionRows(window)[0].querySelector(".recordings-session-meta");
  assert.deepEqual(
    [...meta.querySelectorAll(".tile-name")].map((el) => el.textContent),
    ["Pixel 9-01", "Pixel 9-02", "Pixel 9-03"],
  );
  const more = meta.querySelector(".recordings-session-devices-more");
  assert.equal(more.textContent, "ほか5台");
  assert.equal(more.title.split("\n").length, 8, "畳んだ分も含め全台が title で読める");
});

test("machine も台も無い古い記録では段そのものを作らない", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "recordingsSessions", sessions: [session({ machine: null, machines: [], devices: [] })] });

  assert.equal(sessionRows(window)[0].querySelector(".recordings-session-meta"), null);
});

const VIDEOS = [
  { scenarioID: "デモ.ログイン.S0010", videoUri: "https://localhost/videos/S0010.mp4" },
  { scenarioID: "デモ.ログイン.S0020", videoUri: "https://localhost/videos/S0020.mp4" },
];

const treeScenario = (method) => ({
  scenarioID: `デモ.ログイン.${method}`,
  title: method,
  method,
  startedAt: `2026-07-24T00:0${method === "S0010" ? 0 : 5}:00.000Z`,
  status: "passed",
  offsetMs: 0,
  scenes: [],
});

const SESSION_DETAIL = {
  type: "recordingsSession",
  ok: true,
  project: "SampleApp",
  runID: "20260724-000000",
  error: null,
  videos: VIDEOS,
  errors: [],
  tree: [
    {
      classID: "デモ.ログイン",
      status: "passed",
      firstScenarioID: "デモ.ログイン.S0010",
      scenarios: [treeScenario("S0010"), treeScenario("S0020")],
    },
  ],
  machine: "LDIPC96",
  machines: ["LDIPC96"],
  devices: [
    { scenarioID: "デモ.ログイン.S0010", platform: "ios", device: "iPhone 16", machine: "LDIPC96" },
    { scenarioID: "デモ.ログイン.S0020", platform: "android", device: "Pixel 9-01", machine: "LDIPC96" },
  ],
};

test("再生ビューは見出しに実行マシン、再生中の台を動画に追従して出す", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_DETAIL);

  const machine = window.document.getElementById("recordings-session-machine");
  assert.deepEqual([...machine.querySelectorAll(".badge-remote")].map((b) => b.textContent), ["LDIPC96"]);
  assert.notEqual(machine.style.display, "none");

  // 開いた直後は先頭シナリオの動画が載る(applyRecordingsSession → seekToOffset)
  const deviceEl = window.document.getElementById("recordings-now-playing-device");
  assert.equal(deviceEl.querySelector(".tile-name").textContent, "iPhone 16");

  // 次のテストへ移ると台の表示もその動画のものへ変わる
  window.document.getElementById("recordings-next-test").click();
  const pill = deviceEl.querySelector(".tile-name");
  assert.equal(pill.textContent, "Pixel 9-01");
  assert.ok(pill.classList.contains("tile-name-android"));
});

test("machine/台が無いセッションでは見出しバッジも台も出さない", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ ...SESSION_DETAIL, machine: null, machines: [], devices: [] });

  assert.equal(window.document.getElementById("recordings-session-machine").style.display, "none");
  assert.equal(window.document.getElementById("recordings-now-playing-device").style.display, "none");
});

// ---- 機械ごとに分かれた run を束ねたセッション(runGroup) ----

test("束ねたセッションの行にはマシンが全部出る", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({
    type: "recordingsSessions",
    sessions: [session({
      runIDs: ["20260724-000000", "20260724-000012"],
      machines: ["LDIPC96", "M1Max"],
      devices: [
        { platform: "android", device: "Pixel 9-01", machine: "LDIPC96" },
        { platform: "android", device: "Pixel 9-01", machine: "M1Max" },
      ],
    })],
  });

  const meta = sessionRows(window)[0].querySelector(".recordings-session-meta");
  assert.deepEqual([...meta.querySelectorAll(".badge-remote")].map((b) => b.textContent),
                   ["LDIPC96", "M1Max"]);
  // 同名の台が2機に居るので、名前だけでは区別できない → title に機械名を併記する
  const titles = [...meta.querySelectorAll(".tile-name")].map((p) => p.title);
  assert.equal(titles.length, 2);
  assert.match(titles[0], /LDIPC96/);
  assert.match(titles[1], /M1Max/);
});

test("束ねたセッションの再生ビューは見出しに全マシン、再生中の台にその機械名を出す", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({
    ...SESSION_DETAIL,
    machine: "LDIPC96",
    machines: ["LDIPC96", "M1Max"],
    devices: [
      { scenarioID: "デモ.ログイン.S0010", platform: "android", device: "Pixel 9-01", machine: "LDIPC96" },
      { scenarioID: "デモ.ログイン.S0020", platform: "android", device: "Pixel 9-01", machine: "M1Max" },
    ],
  });

  const machine = window.document.getElementById("recordings-session-machine");
  assert.deepEqual([...machine.querySelectorAll(".badge-remote")].map((b) => b.textContent),
                   ["LDIPC96", "M1Max"]);

  const deviceEl = window.document.getElementById("recordings-now-playing-device");
  assert.equal(deviceEl.querySelector(".badge-remote").textContent, "LDIPC96");
  window.document.getElementById("recordings-next-test").click();
  assert.equal(deviceEl.querySelector(".badge-remote").textContent, "M1Max",
               "別の機械の動画に切り替わったらマシン名も変わる");
});

test("マシンが1台のセッションでは再生中の台にマシン名を足さない(従来の見た目)", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_DETAIL);

  const deviceEl = window.document.getElementById("recordings-now-playing-device");
  assert.equal(deviceEl.querySelector(".badge-remote"), null);
  assert.equal(deviceEl.querySelector(".tile-name").textContent, "iPhone 16");
});

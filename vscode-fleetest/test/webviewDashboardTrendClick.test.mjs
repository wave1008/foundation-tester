// webviewDashboardTrendClick.test.mjs
// ダッシュボードタブ(webview)を実 HTML+実バンドルで動かす DOM E2E(jsdom。方式は
// test/webviewRecordingsTab.test.mjs と同じ)。
// 検証対象: 「不安定なシナリオ」「シナリオ別サマリ」の scenarioID セルをクリックすると
// host へ封筒 {type:'dashboard', message:{type:'trend', scenarioID}} が届き、履歴セクションが
// 開く(読み込み中表示)+ ペインがそのセクションまでスクロールする(長い表の下に開くため)。
// host からの {type:'trend'} 応答で行が描画される。

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
    bundle: true, platform: "node", format: "cjs", target: "node18",
    write: false, external: ["vscode"], logLevel: "silent",
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
    bundle: true, platform: "browser", format: "iife", target: "es2022",
    write: false, logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const posts = [];
  window.acquireVsCodeApi = () => ({ postMessage: (m) => posts.push(m), setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  window.document.getElementById("tab-dashboard").click();
  const sendToWebview = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  return { window, posts, sendToWebview };
}

const RUN = {
  schemaVersion: 1, runID: "20260901-000000Z-abcd1234", project: "P", profile: "ios-inapp",
  host: "H", trigger: "cli", startedAt: "2026-09-01T00:00:00Z", finishedAt: "2026-09-01T00:01:00Z",
};
const PAYLOAD = {
  schemaVersion: 1, project: "P", generatedAt: "2026-09-01T00:02:00Z", since: "2026-06-03T00:00:00Z",
  runs: [RUN],
  summary: [{ scenarioID: "Foo.S0010", runs: 4, successRate: 50, avgDurationMs: 100, medianDurationMs: 100 }],
  flaky: [{ scenarioID: "Foo.S0010", runs: 4, failureRate: 50, flakinessScore: 0.5, recentResults: [true, false, true, false] }],
  devices: { byPlatform: [], byWorker: [] },
  daily: [], slow: [], insights: [], triage: { totalFailed: 0, unreachedCount: 0, rows: [], noteCounts: [] },
  performance: { runs: [], comparisons: [] }, machines: [], runStats: [],
};

test("flaky scenarioID cell click requests the trend and opens the section", (t) => {
  const { window, posts, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "dashboard", message: { type: "data", payload: PAYLOAD } });

  const cell = window.document.querySelector("#table-flaky-body td.scenario-id-clickable");
  assert.ok(cell, "flaky table renders a clickable scenarioID cell");
  // jsdom はレイアウトを持たないので、ペイン・ツールバー・セクションの位置関係だけ与える:
  // セクションはペイン上端から 900px 下、ツールバー(sticky)の高さ 40px
  const pane = window.document.getElementById("panel-dashboard");
  const section = window.document.getElementById("section-trend");
  pane.getBoundingClientRect = () => ({ top: 100 });
  section.getBoundingClientRect = () => ({ top: 1000 });
  Object.defineProperty(window.document.getElementById("dash-toolbar"), "offsetHeight", { value: 40 });
  let scrollTop = 0;
  Object.defineProperty(pane, "scrollTop", { get: () => scrollTop, set: (v) => { scrollTop = v; } });
  cell.click();

  const trendPost = posts.find((p) => p.type === "dashboard" && p.message?.type === "trend");
  assert.deepEqual(JSON.parse(JSON.stringify(trendPost)), { type: "dashboard", message: { type: "trend", scenarioID: "Foo.S0010" } });
  assert.equal(section.style.display, "block");
  assert.equal(scrollTop, 1000 - 100 - 40, "the pane scrolls so the section lands just under the sticky toolbar");

  sendToWebview({
    type: "dashboard",
    message: {
      type: "trend", scenarioID: "Foo.S0010",
      records: [{
        schemaVersion: 1, runID: RUN.runID, scenarioID: "Foo.S0010", platform: "ios", host: "H",
        passed: true, startedAt: "2026-09-01T00:00:10Z", durationMs: 100, scenes: [],
        steps: { total: 1, passed: 1, failed: 0 },
      }],
    },
  });
  assert.equal(window.document.querySelectorAll("#trend-body tbody tr").length, 1);
});

// 日別成功率の横スクロール: モニターはデバイスタブで開くので、データはダッシュボードが
// display:none のうちに届く(scrollWidth/clientWidth が 0 で右端寄せもフェード判定も空振りする)。
// タブが表示された時点(tabs.js の ft-tab-activated)で右端(最新日)へ寄せ、フェードの class が付くこと。
// jsdom は canvas もレイアウトも持たないので、2D コンテキストと wrap の寸法だけ差し替える。
test("daily chart scrolls to the newest day when the dashboard tab is shown after the data arrived", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const fakeContext = new Proxy({}, {
    get: (_target, prop) => {
      if (prop === "measureText") return () => ({ width: 20, actualBoundingBoxAscent: 7, actualBoundingBoxDescent: 2 });
      return () => {};
    },
    set: () => true,
  });
  window.HTMLCanvasElement.prototype.getContext = () => fakeContext;
  const wrap = window.document.querySelector(".daily-chart-wrap");
  let shown = false;
  let scrollLeft = 0;
  Object.defineProperty(wrap, "clientWidth", { get: () => (shown ? 794 : 0) });
  Object.defineProperty(wrap, "scrollWidth", { get: () => (shown ? 964 : 0) });
  Object.defineProperty(wrap, "scrollLeft", { get: () => scrollLeft, set: (v) => { scrollLeft = v; } });

  // createWebview はダッシュボードタブを開いているので、いったんデバイスタブへ(= 非表示で受信)
  window.document.getElementById("tab-devices").click();
  const daily = [];
  for (let d = 0; d < 40; d++) {
    daily.push({ date: `2026-08-${String(1 + (d % 28)).padStart(2, "0")}`, passed: 10, failed: 0, total: 10 });
  }
  sendToWebview({ type: "dashboard", message: { type: "data", payload: { ...PAYLOAD, daily } } });
  assert.equal(scrollLeft, 0, "hidden: nothing to scroll yet");
  assert.equal(wrap.classList.contains("can-scroll-left"), false);

  shown = true;
  window.document.getElementById("tab-dashboard").click();
  assert.equal(scrollLeft, 964, "shown: scrolled to the newest day");
  assert.equal(wrap.classList.contains("can-scroll-left"), true, "older days are to the left");
  assert.equal(wrap.classList.contains("can-scroll-right"), false);
});

test("daily chart ◀▶ buttons: always shown, disabled towards no more days, click = one bar, hold = continuous", async (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const fakeContext = new Proxy({}, {
    get: (_target, prop) => (prop === "measureText"
      ? () => ({ width: 20, actualBoundingBoxAscent: 7, actualBoundingBoxDescent: 2 })
      : () => {}),
    set: () => true,
  });
  window.HTMLCanvasElement.prototype.getContext = () => fakeContext;
  const wrap = window.document.querySelector(".daily-chart-wrap");
  let scrollLeft = 0;
  Object.defineProperty(wrap, "clientWidth", { get: () => 794 });
  Object.defineProperty(wrap, "scrollWidth", { get: () => 964 });
  Object.defineProperty(wrap, "scrollLeft", { get: () => scrollLeft, set: (v) => { scrollLeft = Math.max(0, Math.min(964 - 794, v)); } });
  const daily = [];
  for (let d = 0; d < 40; d++) {
    daily.push({ date: `2026-08-${String(1 + (d % 28)).padStart(2, "0")}`, passed: 10, failed: 0, total: 10 });
  }
  sendToWebview({ type: "dashboard", message: { type: "data", payload: { ...PAYLOAD, daily } } });
  const left = window.document.getElementById("daily-scroll-left");
  const right = window.document.getElementById("daily-scroll-right");
  // 受信直後は右端(最新日): 両方表示され、右だけ disabled
  assert.equal(scrollLeft, 170);
  assert.equal(left.disabled, false);
  assert.equal(right.disabled, true);

  // 短押し = 1本ぶん(20 + 4)
  left.dispatchEvent(new window.MouseEvent("mousedown", { button: 0, bubbles: true }));
  left.dispatchEvent(new window.MouseEvent("mouseup", { button: 0, bubbles: true }));
  wrap.dispatchEvent(new window.Event("scroll"));
  assert.equal(scrollLeft, 170 - 24);
  assert.equal(right.disabled, false);

  // 押しっぱなし = 遅延後に連続移動、離すと止まる
  left.dispatchEvent(new window.MouseEvent("mousedown", { button: 0, bubbles: true }));
  await new Promise((resolve) => setTimeout(resolve, 500));
  left.dispatchEvent(new window.MouseEvent("mouseup", { button: 0, bubbles: true }));
  const afterHold = scrollLeft;
  assert.ok(afterHold < 170 - 24 - 24, `held: moved further than one more bar (now ${afterHold})`);
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(scrollLeft, afterHold, "released: no further movement");

  // 縦ホイールは横スクロールになる(横成分が主ならブラウザ既定に任せる)
  scrollLeft = 0;
  const wheel = new window.WheelEvent("wheel", { deltaX: 0, deltaY: 40, cancelable: true });
  wrap.dispatchEvent(wheel);
  assert.equal(scrollLeft, 40);
  assert.equal(wheel.defaultPrevented, true);
});

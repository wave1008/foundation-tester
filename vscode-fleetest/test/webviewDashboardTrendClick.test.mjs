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
  dailyFullSuite: [], fullSuiteMinScenarios: 30,
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

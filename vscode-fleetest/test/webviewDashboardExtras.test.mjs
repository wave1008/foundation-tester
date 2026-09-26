// webviewDashboardExtras.test.mjs
// ダッシュボードタブ(webview)の追加項目を実 HTML+実バンドルで動かす DOM E2E(jsdom。方式は
// webviewDashboardTrendClick.test.mjs と同じ)。対象: 失敗の内訳(欠けた欄は「–」)・
// 注意喚起の折りたたみとリンク・シナリオ別サマリの並べ替え・絞り込み・
// 失敗ステップの file:line クリックでエディタを開く。

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
  total: 3, passed: 2, failed: 1,
};

function basePayload(overrides = {}) {
  return {
    schemaVersion: 1, project: "P", generatedAt: "2026-09-01T00:02:00Z", since: "2026-06-03T00:00:00Z",
    runs: [RUN],
    summary: [],
    flaky: [],
    devices: { byPlatform: [], byWorker: [] },
    daily: [], slow: [], insights: [],
    triage: { totalFailed: 0, unreachedCount: 0, rows: [], noteCounts: [] },
    machines: [], runStats: [],
    ...overrides,
  };
}

// ---- 失敗の内訳(欠けた欄は「–」・「その他」に丸めない) --------------------------------

test("triage: section が欠けた行は「–」で出す(丸めない)", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const payload = basePayload({
    triage: {
      totalFailed: 7,
      unreachedCount: 1,
      rows: [
        { command: "exist", failureKind: "assertionFailed", count: 2, scenarioCount: 2, scenarioIDs: ["D"] },
        { section: "action", command: "tap", failureKind: "elementNotFound", count: 5, scenarioCount: 3, scenarioIDs: ["A", "B", "C"] },
      ],
      noteCounts: [{ note: "interruption-dismissed", count: 3 }],
    },
  });
  sendToWebview({ type: "dashboard", message: { type: "data", payload } });

  const section = window.document.getElementById("section-triage");
  assert.equal(section.style.display, "block");
  const rows = window.document.querySelectorAll("#table-triage-body tr");
  assert.equal(rows.length, 2);
  const firstCells = [...rows[0].children].map((c) => c.textContent);
  assert.equal(firstCells[0], "–", "section 欠落は「–」");
  assert.notEqual(firstCells[0], "その他");
  assert.equal(firstCells[1], "exist");
  assert.equal(firstCells[2], "assertionFailed");
  assert.equal(firstCells[3], "2");

  const summaryText = window.document.getElementById("triage-summary").textContent;
  assert.match(summaryText, /7/);
  assert.match(summaryText, /1/);

  const noteRows = window.document.querySelectorAll("#table-triage-notes-body tr");
  assert.equal(noteRows.length, 1);
  assert.equal(noteRows[0].children[0].textContent, "interruption-dismissed");
});

test("triage: scenarioIDs 欠落は「–」、シナリオ例セルのクリックで実行履歴を開く", (t) => {
  const { window, posts, sendToWebview } = createWebview();
  t.after(() => window.close());
  const payload = basePayload({
    triage: {
      totalFailed: 1,
      unreachedCount: 0,
      rows: [{ count: 1, scenarioCount: 0, scenarioIDs: [] }],
      noteCounts: [],
    },
  });
  sendToWebview({ type: "dashboard", message: { type: "data", payload } });
  const row = window.document.querySelector("#table-triage-body tr");
  assert.equal(row.children[5].textContent, "–");

  const payload2 = basePayload({
    triage: {
      totalFailed: 1,
      unreachedCount: 0,
      rows: [{ section: "action", command: "tap", failureKind: "x", count: 1, scenarioCount: 1, scenarioIDs: ["Foo.S0010"] }],
      noteCounts: [],
    },
  });
  sendToWebview({ type: "dashboard", message: { type: "data", payload: payload2 } });
  const cell = window.document.querySelector("#table-triage-body tr .scenario-id-clickable");
  assert.ok(cell);
  cell.click();
  const trendPost = posts.find((p) => p.type === "dashboard" && p.message?.type === "trend");
  // jsdom の realm で作られたオブジェクトなので JSON で Node 側へ写してから比べる
  // (webviewDashboardTrendClick.test.mjs と同じ理由)。
  assert.deepEqual(JSON.parse(JSON.stringify(trendPost.message)), { type: "trend", scenarioID: "Foo.S0010" });
});

test("triage: triage キーが無いペイロードではセクションを隠す(旧 CLI)", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const payload = basePayload();
  delete payload.triage;
  sendToWebview({ type: "dashboard", message: { type: "data", payload } });
  assert.equal(window.document.getElementById("section-triage").style.display, "none");
});

// ---- 注意喚起の折りたたみとリンク ----------------------------------------------------

function unsettledInsight(n) {
  return { kind: "unsettledSteps", severity: "warn", scenarioID: "S" + n, platform: "ios", message: "msg " + n, count: n };
}

test("insights: 同じ kind が4件以上なら先頭3件+「他 N 件」に折りたたむ", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const insights = [unsettledInsight(1), unsettledInsight(2), unsettledInsight(3), unsettledInsight(4), unsettledInsight(5)];
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({ insights }) } });

  const items = [...window.document.querySelectorAll("#insights-list .insight-item")];
  const shownMessages = items.filter((li) => !li.classList.contains("insight-more")).map((li) => li.textContent);
  assert.equal(shownMessages.length, 3);
  const more = items.find((li) => li.classList.contains("insight-more"));
  assert.ok(more, "折りたたみ行がある");
  assert.match(more.textContent, /2/);
});

test("insights: severity ごとに見出しを分ける(critical→warn→info の順)", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const insights = [
    { kind: "newFailure", severity: "critical", scenarioID: "A", platform: "ios", message: "critical msg" },
    { kind: "durationRegression", severity: "info", scenarioID: "B", platform: "ios", message: "info msg" },
    unsettledInsight(1),
  ];
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({ insights }) } });
  const headings = [...window.document.querySelectorAll("#insights-list .insight-severity-heading")].map((h) => h.textContent);
  assert.equal(headings.length, 3);
  // critical/warn/info の日本語ラベルがこの順で並ぶ
  const order = headings.map((h) => (h.includes("重大") ? "critical" : h.includes("警告") ? "warn" : "info"));
  assert.deepEqual(order, ["critical", "warn", "info"]);
});

test("insights: scenarioID を持つ行は本文クリックで実行履歴、worker は一致する行があるときだけ別のリンクを添える", (t) => {
  const { window, posts, sendToWebview } = createWebview();
  t.after(() => window.close());
  // 実データの deviceBias は scenarioID と worker の両方を持つ
  const payload = basePayload({
    devices: { byPlatform: [], byWorker: [{ worker: "ios:iPhone 15", runs: 3, successRate: 33 }] },
    insights: [
      { kind: "newFailure", severity: "critical", scenarioID: "Foo.S0010", platform: "ios", message: "critical msg" },
      { kind: "deviceBias", severity: "warn", scenarioID: "Bar.S0010", platform: "ios", worker: "ios:iPhone 15", message: "device bias matched" },
      { kind: "deviceBias", severity: "warn", scenarioID: "Baz.S0010", platform: "ios", worker: "ios:iPhone 99 (存在しない)", message: "device bias unmatched" },
    ],
  });
  sendToWebview({ type: "dashboard", message: { type: "data", payload } });

  const items = [...window.document.querySelectorAll("#insights-list .insight-item")];
  const scenarioItem = items.find((li) => li.textContent.includes("critical msg"));
  const matchedItem = items.find((li) => li.textContent.includes("device bias matched"));
  const unmatchedItem = items.find((li) => li.textContent.includes("device bias unmatched"));
  assert.ok(scenarioItem.querySelector(".scenario-id-clickable"), "scenarioID を持つ行はリンクになる");
  assert.equal(scenarioItem.querySelector(".insight-worker-link"), null, "worker の無い行に台へのリンクは出さない");
  assert.ok(matchedItem.querySelector(".insight-worker-link"), "一致する worker 行があれば台へのリンクを添える");
  assert.equal(unmatchedItem.querySelector(".insight-worker-link"), null, "一致する行が無ければ台へのリンクを出さない");

  matchedItem.querySelector(".scenario-id-clickable:not(.insight-worker-link)").click();
  const trendPost = posts.find((p) => p.type === "dashboard" && p.message?.type === "trend");
  assert.deepEqual(JSON.parse(JSON.stringify(trendPost.message)), { type: "trend", scenarioID: "Bar.S0010" });

  const workerRow = [...window.document.querySelectorAll("#table-devices-worker-body tr")]
    .find((tr) => tr.dataset.worker === "ios:iPhone 15");
  matchedItem.querySelector(".insight-worker-link").click();
  assert.ok(workerRow.classList.contains("row-highlight"), "一致する worker 行を一時的に強調する");
});

test("insights: 0件なら空メッセージを出す", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({ insights: [] }) } });
  assert.equal(window.document.getElementById("insights-empty").style.display, "block");
  assert.equal(window.document.getElementById("insights-list").style.display, "none");
});

// ---- シナリオ別サマリの並べ替え・絞り込み ----------------------------------------------

function summaryRow(scenarioID, successRate, runs) {
  return { scenarioID, runs, successRate, avgDurationMs: runs * 1000, lastRunAt: "2026-09-01T00:00:00Z", lastPassed: successRate >= 100 };
}

test("summary: シナリオIDの部分一致で絞り込み、件数表示が追随する", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const summary = [summaryRow("Alpha", 100, 5), summaryRow("Beta", 50, 3), summaryRow("Gamma", 80, 2)];
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({ summary }) } });

  assert.equal(window.document.querySelectorAll("#table-summary-body tr").length, 3);
  const filterInput = window.document.getElementById("summary-filter");
  filterInput.value = "beta";
  filterInput.dispatchEvent(new window.Event("input"));
  const rows = window.document.querySelectorAll("#table-summary-body tr");
  assert.equal(rows.length, 1);
  assert.equal(rows[0].children[0].textContent, "Beta");
  assert.match(window.document.getElementById("summary-count").textContent, /1/);
});

test("summary: 「失敗を含むものだけ」チェックで successRate<100 だけに絞る", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const summary = [summaryRow("Alpha", 100, 5), summaryRow("Beta", 50, 3), summaryRow("Gamma", 80, 2)];
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({ summary }) } });

  const checkbox = window.document.getElementById("summary-failures-only");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change"));
  const ids = [...window.document.querySelectorAll("#table-summary-body tr")].map((tr) => tr.children[0].textContent);
  assert.deepEqual(ids.sort(), ["Beta", "Gamma"]);
});

test("summary: 列見出しクリックで昇順/降順に並べ替える(数値列は数値で)", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  const summary = [summaryRow("Alpha", 100, 5), summaryRow("Beta", 50, 30), summaryRow("Gamma", 80, 2)];
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({ summary }) } });

  const runsHeader = window.document.querySelector('#table-summary thead th[data-sort-key="runs"]');
  runsHeader.click();
  let ids = [...window.document.querySelectorAll("#table-summary-body tr")].map((tr) => tr.children[0].textContent);
  assert.deepEqual(ids, ["Gamma", "Alpha", "Beta"], "昇順(2, 5, 30)");
  assert.ok(runsHeader.classList.contains("sort-asc"));

  runsHeader.click();
  ids = [...window.document.querySelectorAll("#table-summary-body tr")].map((tr) => tr.children[0].textContent);
  assert.deepEqual(ids, ["Beta", "Alpha", "Gamma"], "降順");
  assert.ok(runsHeader.classList.contains("sort-desc"));

  const idHeader = window.document.querySelector('#table-summary thead th[data-sort-key="scenarioID"]');
  idHeader.click();
  ids = [...window.document.querySelectorAll("#table-summary-body tr")].map((tr) => tr.children[0].textContent);
  assert.deepEqual(ids, ["Alpha", "Beta", "Gamma"], "文字列の昇順");
});

// ---- 失敗ステップの file:line クリックでエディタを開く ------------------------------------

test("run 詳細: failedSteps の file:line セルはクリックで openSource を送る", (t) => {
  const { window, posts, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload() } });

  const runRow = window.document.querySelector("#table-runs-body tr");
  runRow.click();
  const detailReq = posts.find((p) => p.type === "dashboard" && p.message?.type === "runDetail");
  assert.ok(detailReq);

  sendToWebview({
    type: "dashboard",
    message: {
      type: "runDetail",
      payloads: [
        {
          schemaVersion: 1,
          project: "P",
          run: RUN,
          scenarios: [
            {
              runID: RUN.runID, scenarioID: "Foo.S0010", platform: "ios", host: "H", passed: false,
              startedAt: "2026-09-01T00:00:00Z", durationMs: 500, scenes: [],
              steps: { total: 1, passed: 0, failed: 1, skipped: 0, healed: 0, passedViaFallback: 0 },
              failedSteps: [
                { index: 0, description: "tap(#login)", section: "action", command: "tap", file: "Foo.swift", line: 10 },
              ],
            },
          ],
        },
      ],
    },
  });

  const scenarioRow = window.document.querySelector("#run-detail-body .scenario-row-clickable");
  assert.ok(scenarioRow);
  scenarioRow.click();

  const fileLineCell = window.document.querySelector("#run-detail-body td.scenario-id-clickable");
  assert.ok(fileLineCell, "file:line セルがクリック可能になっている");
  assert.equal(fileLineCell.textContent, "Foo.swift:10");
  fileLineCell.click();

  const openSourcePost = posts.find((p) => p.type === "dashboard" && p.message?.type === "openSource");
  assert.deepEqual(JSON.parse(JSON.stringify(openSourcePost.message)), { type: "openSource", file: "Foo.swift", line: 10 });
});

test("run 詳細: line 欠落は 1 を既定にして openSource を送る", (t) => {
  const { window, posts, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload() } });
  window.document.querySelector("#table-runs-body tr").click();
  sendToWebview({
    type: "dashboard",
    message: {
      type: "runDetail",
      payloads: [
        {
          schemaVersion: 1,
          project: "P",
          run: RUN,
          scenarios: [
            {
              runID: RUN.runID, scenarioID: "Foo.S0010", platform: "ios", host: "H", passed: false,
              startedAt: "2026-09-01T00:00:00Z", durationMs: 500, scenes: [],
              steps: { total: 1, passed: 0, failed: 1, skipped: 0, healed: 0, passedViaFallback: 0 },
              failedSteps: [{ index: 0, description: "tap(#login)", file: "Foo.swift" }],
            },
          ],
        },
      ],
    },
  });
  window.document.querySelector("#run-detail-body .scenario-row-clickable").click();
  window.document.querySelector("#run-detail-body td.scenario-id-clickable").click();
  const openSourcePost = posts.find((p) => p.type === "dashboard" && p.message?.type === "openSource");
  assert.deepEqual(JSON.parse(JSON.stringify(openSourcePost.message)), { type: "openSource", file: "Foo.swift", line: 1 });
});

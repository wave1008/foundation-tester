// webviewDashboardExtras.test.mjs
// ダッシュボードタブ(webview)の追加項目を実 HTML+実バンドルで動かす DOM E2E(jsdom。方式は
// webviewDashboardTrendClick.test.mjs と同じ)。対象: 注意喚起の折りたたみとリンク・シナリオ別サマリの並べ替え・絞り込み・
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
    deviceHealth: [],
    slow: [], insights: [],
    machines: [], runStats: [],
    ...overrides,
  };
}

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
  showAllDevices(window);
  // 実データの deviceBias は scenarioID と worker の両方を持つ
  const payload = basePayload({
    deviceHealth: [
      {
        host: "H", worker: "ios:iPhone 15", removed: 3, removedByCause: {}, requeued: 0,
        preRunExcluded: 0, preRunRepaired: 0, recovered: 0, recoveredByKind: {}, appCrashes: 0,
      },
    ],
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

  const workerRow = [...window.document.querySelectorAll("#table-device-health-body tr")]
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

// ---- デバイスの健全性: モニター(今の状態)と api results(deviceHealth)の結合 ------------------

/** 「アクティブなデバイスを表示」(既定 ON)を外し、全台を出す(表の中身を確かめるテスト用) */
function showAllDevices(window) {
  const toggle = window.document.getElementById("chk-device-health-active-only");
  toggle.checked = false;
  toggle.dispatchEvent(new window.Event("change"));
}

function healthRow(overrides = {}) {
  return {
    host: "H", worker: "android:Pixel 8", removed: 0, removedByCause: {}, requeued: 0,
    preRunExcluded: 0, preRunRepaired: 0, recovered: 0, recoveredByKind: {}, appCrashes: 0,
    ...overrides,
  };
}

function monitorDevice(overrides = {}) {
  return { id: "id", name: "Pixel 8", platform: "android", state: "connected", detail: "", ...overrides };
}

test("デバイスの健全性: モニターだけ・履歴だけ・両方の台が行に出て、片方にしか無い値は「–」になる", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  showAllDevices(window);

  // "H" というホストで走った run は、この Mac(手元)自身の run(machineAlias が "local" を書く実装。
  // DeviceMachineGrouping.localDisplayName)を想定して local へ揃える。
  const payload = basePayload({
    machines: [{ host: "H", machine: "local" }],
    deviceHealth: [
      healthRow({ worker: "android:history-only", removed: 2 }),
      healthRow({ worker: "ios:both", removed: 1 }),
    ],
  });
  sendToWebview({ type: "dashboard", message: { type: "data", payload } });
  sendToWebview({
    type: "devices",
    filter: "all",
    devices: [
      monitorDevice({ id: "ios:monitor-only", name: "monitor-only", platform: "ios" }),
      monitorDevice({ id: "ios:both", name: "both", platform: "ios", state: "offline" }),
    ],
  });

  const rows = [...window.document.querySelectorAll("#table-device-health-body tr")];
  const byWorker = (worker) => rows.find((tr) => tr.dataset.worker === worker);

  const historyOnly = byWorker("android:history-only");
  assert.ok(historyOnly, "履歴だけの台も行に出る");
  assert.equal(historyOnly.children[2].textContent, "–", "モニターに居ない台の状態は「–」");
  assert.equal(historyOnly.children[4].textContent, "2");

  const monitorOnly = byWorker("ios:monitor-only");
  assert.ok(monitorOnly, "モニターだけの台も行に出る");
  assert.notEqual(monitorOnly.children[2].textContent, "–", "モニターに居る台の状態は出す");
  assert.equal(monitorOnly.children[4].textContent, "–", "deviceHealth に居ない台の回数は「–」");

  const both = byWorker("ios:both");
  assert.ok(both, "両方に居る台は1行に結合される");
  assert.notEqual(both.children[2].textContent, "–");
  assert.equal(both.children[4].textContent, "1");
});

test("デバイスの健全性: ストレージは使用量だけを出し、空き(母数が OS で違う)は出さない", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload() } });
  sendToWebview({
    type: "devices",
    filter: "all",
    devices: [
      monitorDevice({
        id: "android:device-scope", name: "device-scope",
        storage: { usedBytes: 1500000000, freeBytes: 3000000000, freeScope: "device", measuredAt: "2026-09-27T00:00:00Z" },
      }),
      monitorDevice({
        id: "android:host-volume", name: "host-volume",
        storage: { usedBytes: 1500000000, freeBytes: 3000000000, freeScope: "hostVolume", measuredAt: "2026-09-27T00:00:00Z" },
      }),
      monitorDevice({ id: "android:no-storage", name: "no-storage" }),
    ],
  });

  const rows = [...window.document.querySelectorAll("#table-device-health-body tr")];
  const byWorker = (worker) => rows.find((tr) => tr.dataset.worker === worker);

  const deviceScope = byWorker("android:device-scope").children[3].textContent;
  const hostVolume = byWorker("android:host-volume").children[3].textContent;
  const noStorage = byWorker("android:no-storage").children[3].textContent;

  assert.equal(deviceScope, "1.4 GB 使用");
  assert.equal(hostVolume, "1.4 GB 使用", "iOS のホストの空きも出さない");
  assert.equal(noStorage, "–", "測れていない台は「–」(0 で埋めない)");
});

// ---- デバイスの健全性: モニターの台名を deviceCatalog で実行プロファイルの name へ揃える ------

function sendDeviceCatalog(sendToWebview, devices) {
  sendToWebview({ type: "dashboard", message: { type: "deviceCatalog", devices } });
}

test("デバイスの健全性: registered の台は name をそのままプロファイルの name として結合する", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({
    type: "dashboard",
    message: {
      type: "data",
      payload: basePayload({
        machines: [{ host: "H", machine: "local" }],
        deviceHealth: [healthRow({ worker: "ios:iPhone 15 Pro", removed: 1 })],
      }),
    },
  });
  sendToWebview({
    type: "devices", filter: "all",
    devices: [monitorDevice({ id: "ios:iPhone 15 Pro", name: "iPhone 15 Pro", platform: "ios", registered: true })],
  });

  const rows = [...window.document.querySelectorAll("#table-device-health-body tr")];
  assert.equal(rows.length, 1, "同じ台が2行に分かれない");
  assert.equal(rows[0].dataset.worker, "ios:iPhone 15 Pro");
  assert.equal(rows[0].children[4].textContent, "1");
  assert.notEqual(rows[0].children[2].textContent, "–");
});

test("デバイスの健全性: 未登録の iOS は udid で deviceCatalog を引いてプロファイルの name に揃える", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({
    type: "dashboard",
    message: {
      type: "data",
      payload: basePayload({
        machines: [{ host: "H", machine: "local" }],
        deviceHealth: [healthRow({ worker: "ios:iPhone 15 Pro", removed: 1 })],
      }),
    },
  });
  sendDeviceCatalog(sendToWebview, [{ platform: "ios", name: "iPhone 15 Pro", udid: "UDID-1" }]);
  sendToWebview({
    type: "devices", filter: "all",
    devices: [
      // 未登録の iOS の台はモニターの name がシミュレータの名前になる(たまたまプロファイルの
      // name と同じ字面になることもあるが保証はない、という実測に合わせて別の字面にする)。
      monitorDevice({ id: "ios:sim-name", name: "iPhone 15 Pro (Clone)", platform: "ios", udid: "UDID-1", registered: false }),
    ],
  });

  const rows = [...window.document.querySelectorAll("#table-device-health-body tr")];
  assert.equal(rows.length, 1, "udid が一致すれば1行に結合される");
  assert.equal(rows[0].dataset.worker, "ios:iPhone 15 Pro");
  assert.equal(rows[0].children[4].textContent, "1");
  assert.notEqual(rows[0].children[2].textContent, "–");
});

test("デバイスの健全性: 未登録の Android は avd(+machine)で deviceCatalog を引いてプロファイルの name に揃える", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({
    type: "dashboard",
    message: {
      type: "data",
      payload: basePayload({
        machines: [{ host: "H", machine: "local" }],
        deviceHealth: [healthRow({ worker: "android:Pixel 9(Android 15)-01", removed: 1 })],
      }),
    },
  });
  // 実際のプロファイルは手元を "local" と書き、モニターは手元の machine を省く(実測)。
  // 同じ AVD 名の台が別の機械にもあるので、machine で手元の台を選ぶ
  sendDeviceCatalog(sendToWebview, [
    { platform: "android", machine: "M1Max", name: "Pixel 9(Android 15)-01 on M1Max", avd: "Pixel_9_Android_15_-01" },
    { platform: "android", machine: "local", name: "Pixel 9(Android 15)-01", avd: "Pixel_9_Android_15_-01" },
  ]);
  sendToWebview({
    type: "devices", filter: "all",
    devices: [
      // 未登録の Android Emulator はモニターの name が AVD 名そのものになる(実測)。
      monitorDevice({ id: "android:Pixel_9_Android_15_-01", name: "Pixel_9_Android_15_-01", platform: "android", registered: false }),
    ],
  });

  const rows = [...window.document.querySelectorAll("#table-device-health-body tr")];
  assert.equal(rows.length, 1, "avd(+machine)が一致すれば1行に結合される");
  assert.equal(rows[0].dataset.worker, "android:Pixel 9(Android 15)-01");
  assert.equal(rows[0].children[4].textContent, "1");
  assert.notEqual(rows[0].children[2].textContent, "–");
});

test("デバイスの健全性: deviceCatalog に当たらない未登録の台は name を推測で変えず、別の行のままにする", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  showAllDevices(window);
  sendToWebview({
    type: "dashboard",
    message: {
      type: "data",
      payload: basePayload({
        machines: [{ host: "H", machine: "local" }],
        deviceHealth: [healthRow({ worker: "android:Pixel 9(Android 15)-01", removed: 1 })],
      }),
    },
  });
  // deviceCatalog は空(またはこの台の avd に当たる記載が無い) —— 当てられないので推測しない。
  sendDeviceCatalog(sendToWebview, []);
  sendToWebview({
    type: "devices", filter: "all",
    devices: [
      monitorDevice({ id: "android:Pixel_9_Android_15_-01", name: "Pixel_9_Android_15_-01", platform: "android", registered: false }),
    ],
  });

  const rows = [...window.document.querySelectorAll("#table-device-health-body tr")];
  assert.equal(rows.length, 2, "当てられない台は履歴の行とは別の行のまま(推測で結合しない)");
  const workers = rows.map((tr) => tr.dataset.worker).sort();
  assert.deepEqual(workers, ["android:Pixel 9(Android 15)-01", "android:Pixel_9_Android_15_-01"]);
});

test("デバイスの健全性: 今の状態は色の点+文字、実行中・凍結・異常フラグはチップで出し、metal-errors は出さない", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  showAllDevices(window);
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({ deviceHealth: [] }) } });
  sendToWebview({
    type: "devices", filter: "all",
    devices: [
      monitorDevice({ id: "android:a", name: "a", state: "connected", inRun: true, frozen: true,
        health: ["wifi-disabled", "metal-errors", "new-flag"] }),
      monitorDevice({ id: "android:b", name: "b", state: "booted" }),
      monitorDevice({ id: "android:c", name: "c", state: "offline" }),
      monitorDevice({ id: "android:d", name: "d", state: "weird" }),
    ],
  });
  const cellOf = (name) => [...window.document.querySelectorAll("#table-device-health-body tr")]
    .find((tr) => tr.dataset.worker === "android:" + name).children[2];

  const a = cellOf("a");
  assert.ok(a.querySelector(".dh-state-dot.dh-state-connected"));
  assert.match(a.textContent, /接続中/, "色だけでなく文字も出す");
  assert.ok(a.querySelector(".dh-chip-running"));
  assert.match(a.querySelector(".dh-chip-frozen").textContent, /❄️/);
  const flags = [...a.querySelectorAll(".dh-chip-health")].map((c) => c.textContent);
  assert.deepEqual(flags, ["⚠ Wi-Fi 無効", "⚠ new-flag"], "既知は訳し、未知は原文、metal-errors は出さない");

  assert.ok(cellOf("b").querySelector(".dh-state-booted"));
  assert.ok(cellOf("c").querySelector(".dh-state-offline"));
  assert.ok(cellOf("d").querySelector(".dh-state-unknown"), "未知の state は不明として出す");
  assert.equal(cellOf("b").querySelector(".dh-chip-running"), null);
});

test("デバイスの健全性: マシンは独立した列で、機械が変わる行に区切りを付け、デバイス列は名前と OS のラベル", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  showAllDevices(window);
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({
    machines: [{ host: "H", machine: "local" }, { host: "R", machine: "M1Max" }],
    deviceHealth: [
      healthRow({ host: "R", worker: "ios:iPhone 17", removed: 1 }),
      healthRow({ host: "H", worker: "ios:iPhone 17", removed: 2 }),
      healthRow({ host: "H", worker: "android:Pixel 9", removed: 3 }),
    ],
  }) } });
  const rows = [...window.document.querySelectorAll("#table-device-health-body tr")];
  assert.deepEqual(rows.map((tr) => tr.children[0].textContent), ["local", "local", "M1Max"]);
  assert.deepEqual(rows.map((tr) => tr.children[1].textContent), ["AndroidPixel 9", "iOSiPhone 17", "iOSiPhone 17"]);
  assert.deepEqual(rows.map((tr) => tr.classList.contains("dh-machine-start")), [false, false, true]);
  // デバイスモニターと同じバッジ: マシンは .badge-remote(手元は data-machine を持たない = 既定色)、
  // OS はタイルの名前ピルと同じ色のクラス
  assert.ok(rows[0].children[0].querySelector(".badge.badge-remote"));
  assert.equal(rows[0].children[0].querySelector(".badge-remote").dataset.machine, undefined);
  assert.equal(rows[2].children[0].querySelector(".badge-remote").dataset.machine, "M1Max");
  assert.ok(rows[0].children[1].querySelector(".tile-name-android"));
  assert.ok(rows[1].children[1].querySelector(".tile-name-ios"));
});

test("デバイスの健全性: 「アクティブなデバイスを表示」は既定 ON で未起動とモニターに居ない台を隠し、OFF で全部出す", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({
    machines: [{ host: "H", machine: "local" }],
    deviceHealth: [healthRow({ worker: "android:history-only", removed: 1 })],
  }) } });
  sendToWebview({
    type: "devices", filter: "all",
    devices: [
      monitorDevice({ id: "android:on", name: "on", state: "connected" }),
      monitorDevice({ id: "android:booted", name: "booted", state: "booted" }),
      monitorDevice({ id: "android:off", name: "off", state: "offline" }),
    ],
  });
  const workers = () => [...window.document.querySelectorAll("#table-device-health-body tr")].map((tr) => tr.dataset.worker).sort();
  const toggle = window.document.getElementById("chk-device-health-active-only");
  assert.equal(toggle.checked, true, "既定は ON");
  assert.deepEqual(workers(), ["android:booted", "android:on"]);
  toggle.checked = false;
  toggle.dispatchEvent(new window.Event("change"));
  assert.deepEqual(workers(), ["android:booted", "android:history-only", "android:off", "android:on"]);
});

test("デバイスの健全性: 注意喚起から隠れている台へ飛ぶと、絞り込みを外してその行を強調する", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({
    machines: [{ host: "H", machine: "local" }],
    deviceHealth: [healthRow({ worker: "ios:iPhone 15", removed: 1 })],
    insights: [{ kind: "deviceBias", severity: "warn", scenarioID: "Bar.S0010", platform: "ios",
      worker: "ios:iPhone 15", message: "device bias" }],
  }) } });
  const toggle = window.document.getElementById("chk-device-health-active-only");
  assert.equal(window.document.querySelector('#table-device-health-body tr[data-worker="ios:iPhone 15"]'), null,
    "モニターに居ない台は既定で隠れている");
  window.document.querySelector("#insights-list .insight-worker-link").click();
  assert.equal(toggle.checked, false);
  const row = window.document.querySelector('#table-device-health-body tr[data-worker="ios:iPhone 15"]');
  assert.ok(row && row.classList.contains("row-highlight"));
});

test("デバイスの健全性: モニターの周期で表に出る値が変わらなければ描き直さない", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  showAllDevices(window);
  sendToWebview({ type: "dashboard", message: { type: "data", payload: basePayload({ deviceHealth: [] }) } });
  const devices = [monitorDevice({ id: "android:a", name: "a", state: "connected" })];
  sendToWebview({ type: "devices", filter: "all", devices });
  const first = window.document.querySelector('#table-device-health-body tr[data-worker="android:a"]');
  sendToWebview({ type: "devices", filter: "all", devices });
  assert.equal(window.document.querySelector('#table-device-health-body tr[data-worker="android:a"]'), first,
    "同じ内容の周期では行を作り直さない");
  sendToWebview({ type: "devices", filter: "all", devices: [monitorDevice({ id: "android:a", name: "a", state: "offline" })] });
  const after = window.document.querySelector('#table-device-health-body tr[data-worker="android:a"]');
  assert.notEqual(after, first, "状態が変われば描き直す");
  assert.match(after.children[2].textContent, /未起動/);
});

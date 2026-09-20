// run ボード(デバイスモニターの実行状況表示。docs/design.md §18)の DOM テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewSelectOnlyDevice.test.mjs と同じ
// (型検査の効かない postMessage 境界を実データで縛る)。

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

/** window.close() を忘れると main.js/runBoard.js の setInterval が残ってプロセスが終わらない */
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

function click(window, el) {
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
}

/** 手元の1台。lane.key(udid)と揃えてある(runBoard.js の deviceIdForLane が突き合わせる)。 */
function sendLocalDevice(window) {
  post(window, {
    type: "devices",
    devices: [{ id: "ios:iPhone 17-01", name: "iPhone 17-01", platform: "ios", state: "connected",
                kind: "virtual", udid: "UDID-1", recording: false }],
  });
}

function monitorRunsMessage(overrides) {
  return {
    type: "monitorRuns",
    observed: true,
    runs: [{
      pid: 41233, runID: "run-1", mine: true,
      project: "ec-mobile", profile: "ios-smoke",
      elapsedSeconds: 261, total: 12, done: 7, failed: 2,
      lanes: [{ key: "UDID-1", name: "iPhone 17-01", platform: "ios", scenario: "05_検索",
                scenarioElapsedSeconds: 72 }],
    }],
    ...overrides,
  };
}

// 「不明」と「空き」を混ぜないのがこのボードの要点なので、記号だけに頼らず語で言い切る
// (● と ○ は形が似ている)。3値が同時に出る盤面を1枚作って確かめる。
test("機械の要約は3値とも語を出す(空き・実行中・不明)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max", "M1Ultra"] });
  post(window, { type: "monitorRuns", observed: true, runs: [] });          // 手元 = 観測できて 0 本
  post(window, monitorRunsMessage({ machine: "M1Max" }));                    // 実行中
  // M1Ultra へは1行も送らない = 一度も聞いていない
  const chips = [...document.querySelectorAll("#run-board-machines .run-board-machine")]
    .map((el) => el.textContent);
  assert.deepEqual(chips, ["local○空き", "M1Max●実行中", "M1Ultra?不明"]);
});

test("run 0本でもヘッダは残る(「モニターが見ていない」と「走っていない」を区別できるように)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 0");
});

test("monitorRuns を受けるとヘッダの件数と行が増える。行クリックでラインビューの台を選択する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendLocalDevice(window);
  post(window, monitorRunsMessage());

  assert.equal(document.getElementById("run-board-title").textContent, "実行中 1");
  const summary = document.querySelector(".run-board-row-summary");
  assert.ok(summary, "run 1件ぶんの行ができる");
  assert.match(summary.querySelector(".run-board-scope").textContent, /ec-mobile \/ ios-smoke/);
  assert.match(summary.querySelector(".run-board-counts").textContent, /7\/12/);

  click(window, summary);
  assert.equal(document.querySelectorAll("#grid .tile.selected").length, 1,
    "run の行クリックで、その run が使っている台をラインビューで選択する");
});

// 「開ける行だ」と分かることが目的なので、状態は文字ではなく aria-expanded / data-expanded で持つ
// (字を差し替える形は細くて気づかれなかった)。CSS はこの data 属性で三角を回す。
test("展開トグルは状態を属性で持ち、文字は回るだけ(開けると分かる形)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, monitorRunsMessage());
  const chevron = document.querySelector(".run-board-chevron");
  assert.equal(chevron.textContent, "▶", "文字は展開しても差し替えない");
  assert.equal(chevron.getAttribute("aria-expanded"), "false");
  assert.match(chevron.title, /開く/);
  click(window, chevron);
  assert.equal(chevron.textContent, "▶");
  assert.equal(chevron.getAttribute("aria-expanded"), "true");
  assert.equal(chevron.dataset.expanded, "true", "向きは CSS の回転で表すので data 属性が要る");
  assert.match(chevron.title, /閉じる/);
});

test("レーン行クリックはその1台だけを選択する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    devices: [
      { id: "ios:iPhone 17-01", name: "iPhone 17-01", platform: "ios", state: "connected",
        kind: "virtual", udid: "UDID-1", recording: false },
      { id: "ios:iPhone 17-02", name: "iPhone 17-02", platform: "ios", state: "connected",
        kind: "virtual", udid: "UDID-2", recording: false },
    ],
  });
  post(window, monitorRunsMessage());
  // 展開しないとレーン行は DOM から見えない(表示は run-board-row-expanded クラスで切り替え)ので、
  // まず展開する(▸/▾ のクリック)。
  click(window, document.querySelector(".run-board-chevron"));
  const laneEl = document.querySelector(".run-board-lane");
  assert.ok(laneEl, "展開するとレーン行が見える");
  click(window, laneEl);
  // タイル要素は device.id を DOM の id 属性に持たない(選択は class で表す)ので、
  // **名前で**確かめる —— 「1枚選ばれた」だけでは別の台を選んでいても通ってしまう
  const selected = [...document.querySelectorAll("#grid .tile.selected")]
    .map((el) => el.querySelector(".tile-name").textContent.trim());
  assert.deepEqual(selected, ["iPhone 17-01"]);
});

test("observed:false は run を消さず「不明」に倒す(件数から外れる)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, monitorRunsMessage({ machine: "M1Max" }));
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 1");
  post(window, { type: "monitorRuns", machine: "M1Max", observed: false, runs: [] });
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 0",
    "観測できなくなった機械の run は数えない(不明を実行中に混ぜない)");
});

test("runBoardReset は控えを丸ごと畳む(モニター再起動と同じ寿命)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, monitorRunsMessage());
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 1");
  post(window, { type: "runBoardReset" });
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 0");
  assert.equal(document.querySelectorAll(".run-board-row").length, 0);
});

test("runBoardCollapsed は開閉トグルの状態を復元し、再送はしない", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  const board = document.getElementById("run-board");
  assert.equal(board.dataset.collapsed, "false");
  post(window, { type: "runBoardCollapsed", value: true });
  assert.equal(board.dataset.collapsed, "true");
  assert.equal(sent.filter((m) => m.type === "setRunBoardCollapsed").length, 0,
    "host からの復元値の反映では setRunBoardCollapsed を送り返さない");

  click(window, document.getElementById("run-board-toggle"));
  assert.equal(board.dataset.collapsed, "false", "ボタン操作でトグルする");
  assert.deepStrictEqual(
    JSON.parse(JSON.stringify(sent.filter((m) => m.type === "setRunBoardCollapsed"))),
    [{ type: "setRunBoardCollapsed", value: false }],
    "利用者の操作は host へ伝えて永続化させる",
  );
});

test("待機中のレーン(scenario 省略)は「⏹ 待機」と経過「—」を出す(レーンごとの残り本数は持たない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, monitorRunsMessage({
    runs: [{
      ...monitorRunsMessage().runs[0],
      lanes: [{ key: "UDID-1", name: "iPhone 17-03", platform: "ios" }],
    }],
  }));
  click(window, document.querySelector(".run-board-chevron"));
  const laneEl = document.querySelector(".run-board-lane");
  assert.match(laneEl.querySelector(".run-board-lane-scenario").textContent, /待機/);
  assert.equal(laneEl.querySelector(".run-board-lane-elapsed").textContent, "—");
});

test("他人の run(mine:false)は issuer を出す。自分の run では出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, monitorRunsMessage({
    runs: [{ ...monitorRunsMessage().runs[0], mine: false, issuer: "alice@air" }],
  }));
  click(window, document.querySelector(".run-board-chevron"));
  const issuerEl = document.querySelector(".run-board-issuer");
  assert.notEqual(issuerEl.style.display, "none");
  assert.match(issuerEl.textContent, /alice@air/);

  post(window, { type: "runBoardReset" });
  post(window, monitorRunsMessage());
  const issuerElAfter = document.querySelector(".run-board-issuer");
  assert.equal(issuerElAfter.style.display, "none", "自分の run では issuer 行を出さない");
});

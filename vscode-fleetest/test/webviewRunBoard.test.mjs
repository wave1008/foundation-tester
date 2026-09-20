// run ボード(デバイスモニターの実行状況表示。docs/design.md §18)の DOM テスト。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewSelectOnlyDevice.test.mjs と同じ
// (型検査の効かない postMessage 境界を実データで縛る)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
      pid: 41233, runID: "run-1", mine: true, phase: "running",
      project: "ec-mobile", profile: "ios-smoke",
      elapsedSeconds: 261, total: 12, done: 7, failed: 2,
      lanes: [{ key: "UDID-1", name: "iPhone 17-01", platform: "ios", scenario: "05_検索",
                scenarioElapsedSeconds: 72 }],
    }],
    ...overrides,
  };
}

// run のある機械は run の行として出るので、ここには現れない(二重に出さない)。
// 「不明」と「空き」は混ぜない —— 記号だけだと ○ と ? の区別が形頼みなので語でも言い切る。
test("走っていない機械は本体に行として並ぶ(実行中の機械は出ない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max", "M1Ultra"] });
  post(window, { type: "monitorRuns", observed: true, runs: [] });   // 手元 = 観測できて 0 本
  post(window, monitorRunsMessage({ machine: "M1Max" }));            // 実行中 → run の行になる
  // M1Ultra へは1行も送らない = 一度も聞いていない
  // 三角は列を揃えるための飾り(押せない)なので、名前と状態だけを見る
  const idle = [...document.querySelectorAll(".run-board-idle-machine")].map((el) =>
    el.querySelector(".run-board-idle-machine-name").textContent
      + el.querySelector(".run-board-idle-machine-status").textContent);
  assert.deepEqual(idle, ["local空き", "M1Ultra—"], "空きは語・不明は「—」");
  assert.equal(document.querySelectorAll(".run-board-chevron-empty").length, 2,
    "子を持たない行にも三角を置く(列を揃えるため)");
  const unknown = [...document.querySelectorAll(".run-board-machine-state-unknown")][0];
  assert.equal(unknown.title, "実行状況を観測できていません", "ダッシュの意味は title で言う");
  assert.equal(document.querySelectorAll(".run-board-row").length, 1, "M1Max は run の行として出る");
  assert.equal(document.getElementById("run-board-machines"), null, "ヘッダの要約は置かない");
});

// 供給(デバイスの用意)の間も run は走っているので、ボードに行を出す —— 出さないと
// 「テスト実行中なのに空き」に見える(2026-09-20 の実害。リモートでは供給が 15〜20 秒)。
test("準備中の run は本数でなく「準備中」を出し、進捗バーは隠す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", machine: "M1Max", observed: true, runs: [{
    pid: 41233, runID: "run-1", mine: true, phase: "preparing",
    project: "E2E-iOS", profile: "ios-inapp",
    elapsedSeconds: 12, total: 0, done: 0, failed: 0, lanes: [],
  }] });
  assert.equal(document.querySelector(".run-board-counts").textContent, "準備中(デバイスを用意しています)");
  assert.equal(document.querySelector(".run-board-progress").style.display, "none");
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 1",
    "準備中も「実行中」の件数に数える(走っているので)");
  // その機械は「空き」の一覧から外れる
  post(window, { type: "hostMetricsMachines", machines: ["M1Max"] });
  const idle = [...document.querySelectorAll(".run-board-idle-machine")].map((el) =>
    el.querySelector(".run-board-idle-machine-name").textContent
      + el.querySelector(".run-board-idle-machine-status").textContent);
  assert.deepEqual(idle, ["local—"], "準備中でも M1Max は使用中(空きに出さない)");
});

test("進捗バーに塗り幅を設定する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, monitorRunsMessage());   // 7/12
  assert.equal(document.querySelector(".run-board-progress-bar").style.width, `${(7 / 12) * 100}%`);
});

// 塗りは <span> なので、display: block を外すと inline に戻って width が1ピクセルも効かない
// (枠だけ出て塗りが見えない = 2026-09-20 の実害)。**jsdom は CSS を読み込まない**ので
// getComputedStyle では捕まえられず、宣言そのものをテキストで押さえる。
test("進捗バーの塗りは display: block を持つ(span の inline では width が効かない)", () => {
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  const start = css.indexOf(".run-board-progress-bar {");
  assert.notEqual(start, -1, ".run-board-progress-bar の宣言が見つからない");
  const declarations = css.slice(start, css.indexOf("}", start));
  assert.match(declarations, /display:\s*block/);
});

// 走っていない機械の行は run 行と混ぜて機械の順に並べるので、列は min-width で揃える。
// 行の高さは固定する —— 和文の「空き」と記号の「—」は既定の行高が違い、揃えないと上下に揺れる。
// **jsdom は CSS を読み込まない**ので宣言そのものをテキストで押さえる(進捗バーと同じ理由)。
test("走っていない機械の行は名前の幅と行の高さを固定する", () => {
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  const row = css.slice(css.indexOf(".run-board-idle-machine {"));
  const rowDecl = row.slice(0, row.indexOf("}"));
  assert.match(rowDecl, /line-height:\s*18px/, "語と — で行の高さが変わらないよう固定する");
  const name = css.slice(css.indexOf(".run-board-idle-machine-name {"));
  assert.match(name.slice(0, name.indexOf("}")), /min-width:/, "状態の列を揃える");
});

// 機械の並びは常に同じ(local → 登録簿の順)。run が始まると行の種類は変わるが**位置は動かない**
// —— 動くと目が追えない(2026-09-20 の指摘: M1Max の run が local の上に来ていた)。
test("並びは常に機械の順で、run が始まっても位置が動かない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max", "M1Ultra"] });
  post(window, { type: "monitorRuns", observed: true, runs: [] });                 // local = 空き
  post(window, { type: "monitorRuns", machine: "M1Ultra", observed: true, runs: [] });
  const label = () => [...document.getElementById("run-board-rows").children].map((el) =>
    el.classList.contains("run-board-idle-machine")
      ? el.querySelector(".run-board-idle-machine-name").textContent
      : `run:${el.querySelector(".run-board-machine-badge").textContent || "local"}`);
  assert.deepEqual(label(), ["local", "M1Max", "M1Ultra"], "M1Max は一度も聞いていない = 不明");

  post(window, monitorRunsMessage({ machine: "M1Max" }));   // 真ん中の機械で run が始まる
  assert.deepEqual(label(), ["local", "run:M1Max", "M1Ultra"], "位置は同じまま行の種類だけ変わる");
});

test("ヘッダ行はどこを押しても開閉する(三角だけが当たり判定ではない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const header = document.getElementById("run-board-header");
  const toggle = document.getElementById("run-board-toggle");
  assert.equal(toggle.dataset.expanded, "true");
  click(window, document.getElementById("run-board-title"));   // タイトルを押す
  assert.equal(toggle.dataset.expanded, "false", "ヘッダのどの子を押しても畳む");
  click(window, header);
  assert.equal(toggle.dataset.expanded, "true");
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

test("ヘッダの開閉も文字は回るだけ(行の chevron と同じ規律)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const toggle = document.getElementById("run-board-toggle");
  assert.equal(toggle.textContent, "▶");
  assert.equal(toggle.dataset.expanded, "true", "初期は開いている");
  click(window, toggle);
  assert.equal(toggle.textContent, "▶", "文字は差し替えない");
  assert.equal(toggle.dataset.expanded, "false");
  assert.equal(toggle.getAttribute("aria-expanded"), "false");
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
  // まず展開する(三角のクリック)。
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

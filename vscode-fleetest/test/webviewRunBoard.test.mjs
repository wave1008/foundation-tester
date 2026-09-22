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
  let state;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => sent.push(message),
    setState: (next) => { state = next; },
    getState: () => state,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, sent, getState: () => state };
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
      pid: 41233, runID: "run-1", mine: true, phase: "running", requeued: 0, laneDropouts: 0,
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
/** 走っていない機械の行を「機械名 + 状態」で読む(行の作りは run 行と共有 = .run-board-row)。 */
const machineRows = (document) => [...document.querySelectorAll(".run-board-row-machine")].map((el) =>
  el.querySelector(".run-board-machine-badge").textContent
    + el.querySelector(".run-board-idle-machine-status").textContent);

/** その行のツリーに並ぶ台の名前。 */
const laneNames = (el) => [...el.querySelectorAll(".run-board-lane-name")].map((n) => n.textContent);

test("走っていない機械は本体に行として並ぶ(実行中の機械は出ない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max", "M1Ultra"] });
  post(window, { type: "monitorRuns", observed: true, runs: [] });   // 手元 = 観測できて 0 本
  post(window, monitorRunsMessage({ machine: "M1Max" }));            // 実行中 → run の行になる
  // M1Ultra へは1行も送らない = 一度も聞いていない
  // 三角は列を揃えるための飾り(押せない)なので、名前と状態だけを見る
  const idle = machineRows(document);
  assert.deepEqual(idle, ["local空き", "M1Ultra—"], "空きは語・不明は「—」");
  assert.equal(document.querySelectorAll(".run-board-chevron-empty").length, 2,
    "子を持たない行にも三角を置く(列を揃えるため)");
  const unknown = [...document.querySelectorAll(".run-board-machine-state-unknown")][0];
  assert.equal(unknown.title, "実行状況を観測できていません", "ダッシュの意味は title で言う");
  assert.equal(document.querySelectorAll(".run-board-row:not(.run-board-row-machine)").length, 1, "M1Max は run の行として出る");
  assert.equal(document.getElementById("run-board-machines"), null, "ヘッダの要約は置かない");
});

// 供給(デバイスの用意)の間も run は走っているので、ボードに行を出す —— 出さないと
// 「テスト実行中なのに空き」に見える(2026-09-20 の実害。リモートでは供給が 15〜20 秒)。
test("準備中の run は本数でなく「準備中」を出し、進捗バーは隠す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", machine: "M1Max", observed: true, runs: [{
    pid: 41233, runID: "run-1", mine: true, phase: "preparing", requeued: 0, laneDropouts: 0,
    project: "E2E-iOS", profile: "ios-inapp",
    elapsedSeconds: 12, total: 0, done: 0, failed: 0, lanes: [],
  }] });
  // **run の行に限って見る** —— 機械の行も同じ作り(.run-board-row)なので、素の
  // querySelector では local の機械行(中身は空)を掴む
  const runRow = document.querySelector(".run-board-row:not(.run-board-row-machine)");
  assert.equal(runRow.querySelector(".run-board-counts").textContent, "準備中(デバイスを用意しています)");
  assert.equal(runRow.querySelector(".run-board-progress").style.display, "none");
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 1",
    "準備中も「実行中」の件数に数える(走っているので)");
  // その機械は「空き」の一覧から外れる
  post(window, { type: "hostMetricsMachines", machines: ["M1Max"] });
  const idle = machineRows(document);
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
// 中身で行の高さが変わると、レーンが増減したように見える(2026-09-20 の実害:
// 「0:08(中央 0:08)」が3行に折れた)。**jsdom は CSS を読まない**のでテキストで押さえる。
test("レーン行は高さを固定し、経過は折り返さない", () => {
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  const lane = css.slice(css.indexOf(".run-board-lane {"));
  assert.match(lane.slice(0, lane.indexOf("}")), /line-height:\s*18px/);
  const elapsed = css.slice(css.indexOf(".run-board-lane-elapsed {"));
  const decl = elapsed.slice(0, elapsed.indexOf("}"));
  assert.match(decl, /white-space:\s*nowrap/, "折り返すと行が伸びる");
  assert.doesNotMatch(decl, /\n\s*width:/, "固定幅だと中央値つきの表示が入らない");
});

// 走っていない機械の行は run 行と**同じ作り**(.run-board-row)を使うので、行の高さも
// インデントも共有の宣言が効く。見出しの1行だけ控えめにし、**下の台のツリーは薄くしない**。
test("走っていない機械の行は run 行と同じ作りで、見出しだけ控えめにする", () => {
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  const summary = css.slice(css.indexOf("\n.run-board-row-summary {"));   // 行頭で探す(子孫セレクタに当てない)
  assert.match(summary.slice(0, summary.indexOf("}")), /line-height:\s*20px/,
    "語と — で行の高さが変わらないよう固定する(run 行と共有)");
  const dim = css.slice(css.indexOf(".run-board-row-machine > .run-board-row-summary {"));
  assert.match(dim.slice(0, dim.indexOf("}")), /opacity:/, "見出しの1行だけ控えめにする");
  assert.equal(css.includes(".run-board-idle-machine {"), false, "専用の行の作りは残さない");
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
    el.classList.contains("run-board-row-machine")
      ? el.querySelector(".run-board-machine-badge").textContent
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
  assert.equal(document.querySelectorAll(".run-board-row:not(.run-board-row-machine)").length, 0);
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

// ---- 台のツリー(ユーザー決定 2026-09-22: 実行状態に関わらず出す) ----

/** 機械ごとの台。machine 省略 = 手元(MonitorDevice の規約)。 */
function sendDevices(window, devices) {
  post(window, {
    type: "devices",
    devices: devices.map((d) => ({
      id: `ios:${d.name}`, name: d.name, platform: "ios", state: "connected",
      kind: "virtual", recording: false, ...d,
    })),
  });
}

// run が1本も走っていなくても、認識した台は機械の行のツリーに出す(出さないと「何も無い」
// ボードになり、フリートに何が居るのかがここから分からない)。
test("run が無い機械の行にも台がツリーで並ぶ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max"] });
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  post(window, { type: "monitorRuns", machine: "M1Max", observed: true, runs: [] });
  sendDevices(window, [
    { name: "iPhone 17 Pro-01", udid: "U-L1" },
    { name: "iPhone 17 Pro-02", udid: "U-L2" },
    { name: "iPhone 17 Pro-01", id: "ios:M1Max-01", udid: "U-M1", machine: "M1Max" },
  ]);
  const machines = [...document.querySelectorAll(".run-board-row-machine")];
  assert.deepEqual(machines.map((el) => el.querySelector(".run-board-machine-badge").textContent),
    ["local", "M1Max"]);
  assert.deepEqual(laneNames(machines[0]), ["iPhone 17 Pro-01", "iPhone 17 Pro-02"], "手元の台");
  assert.deepEqual(laneNames(machines[1]), ["iPhone 17 Pro-01"], "その機械の台だけ");
  // 何を見ている台なのか = モニターの範囲(ツールバーの選択)
  post(window, { type: "profileInfo", project: "sui-ec-mobile", projects: ["sui-ec-mobile"],
                 profiles: ["local+remote"], current: "local+remote" });
  assert.equal(document.querySelector(".run-board-row-machine .run-board-scope").textContent,
    "sui-ec-mobile / local+remote");
});

// run 中でも「その機械の台」を全部出す(ユーザー決定)。run が使っていない台も見える。
test("run の行にも機械の全台が並び、run が使う台にだけシナリオが添う", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [
    { name: "iPhone 17-01", udid: "UDID-1" },   // monitorRunsMessage のレーンと同じ鍵
    { name: "iPhone 17-02", udid: "UDID-2" },   // run に出ていない台
  ]);
  post(window, monitorRunsMessage());
  const row = document.querySelector(".run-board-row:not(.run-board-row-machine)");
  assert.deepEqual(laneNames(row), ["iPhone 17-01", "iPhone 17-02"], "run に出ていない台も並ぶ");
  const scenarios = [...row.querySelectorAll(".run-board-lane-scenario")].map((el) => el.textContent);
  assert.deepEqual(scenarios, ["▶ 05_検索", ""], "run が使っている台にだけシナリオを添える");
});

// タイルが消えた台(観測窓の外)でも run の事実は残す —— レーンの側にしか無い台を落とすと、
// 走っているのにツリーから消える
test("レーンにしか無い台も run の行に残る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{ name: "iPhone 17-02", udid: "UDID-2" }]);   // レーンの台は居ない
  post(window, monitorRunsMessage());
  const row = document.querySelector(".run-board-row:not(.run-board-row-machine)");
  assert.deepEqual(laneNames(row), ["iPhone 17-02", "iPhone 17-01"], "台の一覧のあとにレーンだけの台");
});

// 三角を押した「その場で」開閉する —— 次の監視サイクル(約2秒)を待つ作りにすると、
// 押してから開くまでの遅れが目に見える(ユーザー指摘 2026-09-22)。
test("機械の行の三角は押したその場で開閉する(次の監視サイクルを待たない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  sendDevices(window, [{ name: "iPhone 17 Pro-01", udid: "U-L1" }]);
  const row = document.querySelector(".run-board-row-machine");
  assert.equal(row.classList.contains("run-board-row-expanded"), false, "既定は畳んだ状態");

  click(window, row.querySelector(".run-board-chevron"));
  assert.equal(row.classList.contains("run-board-row-expanded"), true, "押した直後に開く");
  assert.equal(row.querySelector(".run-board-chevron").dataset.expanded, "true");

  click(window, row.querySelector(".run-board-chevron"));
  assert.equal(row.classList.contains("run-board-row-expanded"), false, "押した直後に畳む");
});

// 「マシン有効」を off にした機械はディスパッチの対象外なので、ボードからも外す
// (ユーザー決定 2026-09-22)—— 「空き」と並べると使える機械に見える。
test("無効にした機械は行を出さない(有効に戻すとその場で戻る)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max", "M1mini"] });
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  assert.deepEqual(machineRows(document), ["local空き", "M1Max—", "M1mini—"], "前提: 3機とも出る");

  post(window, { type: "remoteConfig", machineColors: [],
                 hosts: [{ machine: "M1Max", enabled: true }, { machine: "M1mini", enabled: false }] });
  assert.deepEqual(machineRows(document), ["local空き", "M1Max—"], "無効にした機械は出さない");

  post(window, { type: "remoteConfig", machineColors: [],
                 hosts: [{ machine: "M1Max", enabled: true }, { machine: "M1mini", enabled: true }] });
  assert.deepEqual(machineRows(document), ["local空き", "M1Max—", "M1mini—"], "有効に戻すとその場で戻る");
});

// ---- 2カラム(ユーザー決定 2026-09-22: 左 = ツリー・右 = ステータス) ----
// jsdom は寸法を持たないので、境目の幅の計算は clientWidth を差し替えて見る。

/** 行の幅を与える(content = 416 - 左右 padding 8×2 = 400)。 */
function giveWidth(document, width = 416) {
  Object.defineProperty(document.getElementById("run-board-rows"), "clientWidth",
    { value: width, configurable: true });
}
const leftWidth = (document) => document.getElementById("run-board").style.getPropertyValue("--rb-left");
const colText = (el, side) => el.querySelector(`.run-board-col-${side}`).textContent;

test("ステータスは右カラム・名前は左カラムに入る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendLocalDevice(window);
  post(window, monitorRunsMessage());
  const summary = document.querySelector(".run-board-row:not(.run-board-row-machine) .run-board-row-summary");
  assert.match(colText(summary, "left"), /ec-mobile \/ ios-smoke/, "左 = 機械とスコープ");
  assert.match(colText(summary, "right"), /7\/12/, "右 = 進捗");
  assert.match(colText(summary, "right"), /4:21/, "右 = 経過");
  const lane = document.querySelector(".run-board-lane");
  assert.equal(colText(lane, "left"), "iPhone 17-01", "左 = 台の名前だけ");
  assert.match(colText(lane, "right"), /05_検索/, "右 = 実行中のシナリオ");
});

test("機械の行も同じ2カラム(状態は右)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  const summary = document.querySelector(".run-board-row-machine .run-board-row-summary");
  assert.equal(colText(summary, "left").includes("local"), true);
  // **textContent では見ない** —— run 行と DOM を共有しているので、隠してある経過("/")も混ざる
  const status = summary.querySelector(".run-board-idle-machine-status");
  assert.equal(status.textContent, "空き");
  assert.ok(status.closest(".run-board-col-right"), "状態は右カラムに居る");
});

/** 左カラムの中身なりの幅(jsdom は寸法を持たないので、字数 × perChar を返す)。
 *  **小数を返す** —— 整数へ丸めた値で測ると 1px 未満だけ足りずに "…" が出る(実地 2026-09-22)。 */
function giveLabelWidth(window, perChar) {
  Object.defineProperty(window.HTMLElement.prototype, "getBoundingClientRect", {
    configurable: true,
    value() {
      const width = this.classList.contains("run-board-col-left")
        ? this.textContent.length * perChar + 0.4
        : 0;
      return { width, height: 0, left: 0, top: 0, right: width, bottom: 0, x: 0, y: 0 };
    },
  });
}

// 既定は**いちばん長いラベルがちょうど収まる幅**(ユーザー決定)。比率ではないので、
// 台が増えて名前が伸びたら追従する(ドラッグするまでの間)。
test("境目の既定はいちばん長いラベルに合わせ、ドラッグで幅が変わる", (t) => {
  const { window, document, sent, getState } = createWebview();
  t.after(() => window.close());
  giveWidth(document);
  giveLabelWidth(window, 10);
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  // 機械の行の左カラムは "▶local"(6字)。**いちばん長い行に合わせる**ので、台が出ると
  // そちら("iPhone 17 Pro-01" = 16字)に広がる
  assert.equal(leftWidth(document), "80px", "6字 × 10 = 60 は下限 80 まで");
  sendDevices(window, [{ name: "iPhone 17 Pro-01", udid: "U-1" }]);
  // 16字 × 10 + 端数 0.4 → **切り上げる**(切り捨てるとその行だけ "…" になる)
  assert.equal(leftWidth(document), "161px", "短い行ではなく長い行に合わせ、端数は切り上げる");

  const split = document.getElementById("run-board-split");
  assert.equal(split.getAttribute("role"), "separator");
  assert.equal(split.getAttribute("aria-orientation"), "vertical");
  split.setPointerCapture = () => {};
  split.releasePointerCapture = () => {};
  const drag = (type, clientX) => split.dispatchEvent(
    new window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX }));

  drag("pointerdown", 208);
  drag("pointermove", 158);   // 行の左端(0)+ padding 8 を引いて 150
  assert.equal(leftWidth(document), "150px");
  drag("pointerup", 158);
  assert.equal(leftWidth(document), "150px", "離しても保つ(このパネルが生きている間)");
  // **どこにも保存しない**(ユーザー決定 2026-09-22)—— 寿命はこのパネルそのもの。タブを閉じたら
  // 解放して既定へ戻すので、host へ送るのも getState へ書くのも「閉じても残る」形になる
  assert.deepEqual(sent.filter((m) => m?.type === "setRunBoardSplit"), [], "host へ送らない");
  assert.equal(Object.prototype.hasOwnProperty.call(getState() ?? {}, "runBoardSplit"), false,
    "getState にも入れない");
});

test("境目は端まで引き切れない(左右どちらも 80px は残す)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  giveWidth(document);
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  const split = document.getElementById("run-board-split");
  split.setPointerCapture = () => {};
  split.releasePointerCapture = () => {};
  const drag = (type, clientX) => split.dispatchEvent(
    new window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX }));

  drag("pointerdown", 208);
  drag("pointermove", -500);
  assert.equal(leftWidth(document), "80px");
  drag("pointermove", 5000);
  assert.equal(leftWidth(document), "320px", "400 - 80");
});


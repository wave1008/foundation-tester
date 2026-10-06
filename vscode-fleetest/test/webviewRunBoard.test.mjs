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

// **1行 = 1機械**(ユーザー決定 2026-09-30)。行の鍵は run の行が "run\0…"・run の無い機械が "idle\0…"。
const boardRows = (document) => [...document.querySelectorAll("#run-board-rows > .run-board-row")];
const idleRows = (document) => boardRows(document).filter((el) => el.dataset.rowKey.startsWith("idle\u0000"));
const runRows = (document) => boardRows(document).filter((el) => el.dataset.rowKey.startsWith("run\u0000"));
const badgeOf = (el) => el.querySelector(".run-board-row-summary .run-board-machine-badge").textContent;

// 「不明」と「空き」は混ぜない —— 記号だけだと ○ と ? の区別が形頼みなので語でも言い切る。
/** run の無い機械の行を「機械名 + 状態」で読む。 */
const machineRows = (document) => idleRows(document).map((el) =>
  badgeOf(el) + el.querySelector(".run-board-idle-machine-status").textContent);

/** その行のツリーに並ぶデバイスの名前。 */
const laneNames = (el) => [...el.querySelectorAll(".run-board-lane-name")].map((n) => n.textContent);

test("1行 = 1機械。run のある機械は同じ行に範囲と進捗、無い機械はバッジと状態だけ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max", "M1Ultra"] });
  post(window, { type: "profileInfo", project: "sut-ec-mobile", projects: ["sut-ec-mobile"],
                 profiles: ["local+remote"], current: "local+remote" });
  post(window, { type: "monitorRuns", observed: true, runs: [] });   // 手元 = 観測できて 0 本
  post(window, monitorRunsMessage({ machine: "M1Max" }));            // 実行中 → run の行になる
  // M1Ultra へは1行も送らない = 一度も聞いていない
  assert.deepEqual(boardRows(document).map(badgeOf), ["local", "M1Max", "M1Ultra"], "機械の順に1行ずつ");
  assert.deepEqual(machineRows(document), ["local空き", "M1Ultra—"], "空きは語・不明は「—」");
  const [runRow] = runRows(document);
  assert.equal(runRow.querySelector(".run-board-scope").textContent, "ec-mobile / ios-smoke",
    "run の範囲はマシン名の横に出す");
  assert.match(runRow.querySelector(".run-board-counts").textContent, /7\/12/, "進捗も同じ行");
  assert.equal(idleRows(document)[0].querySelector(".run-board-scope").textContent, "",
    "run の無い機械はバッジだけ(範囲は出さない)");
  const unknown = [...document.querySelectorAll(".run-board-machine-state-unknown")][0];
  assert.equal(unknown.title, "実行状況を観測できていません", "ダッシュの意味は title で言う");
  assert.equal(document.getElementById("run-board-machines"), null, "ヘッダの要約は置かない");
});

// 機械分担の run は機械ごとに行が分かれ、それぞれが自分の進捗を出す。件数は run の数のまま
test("機械分担の run は機械ごとの行になり、件数は1本と数える", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max"] });
  const base = monitorRunsMessage().runs[0];
  post(window, { type: "monitorRuns", observed: true,
                 runs: [{ ...base, runGroup: "g-1", total: 10, done: 3, failed: 0 }] });
  post(window, { type: "monitorRuns", machine: "M1Max", observed: true,
                 runs: [{ ...base, pid: 99, runID: "run-2", runGroup: "g-1", total: 8, done: 5, failed: 0 }] });
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 1");
  assert.deepEqual(runRows(document).map((el) =>
    `${badgeOf(el)}:${el.querySelector(".run-board-counts").textContent}`), ["local:3/10", "M1Max:5/8"]);
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
  // **run の行に限って見る** —— run の無い機械の行も同じ作り(.run-board-row)なので、素の
  // querySelector では local の行を掴む
  const [runRow] = runRows(document);
  assert.equal(runRow.querySelector(".run-board-counts").textContent, "準備中(デバイスを用意しています)");
  assert.equal(runRow.querySelector(".run-board-progress").style.display, "none");
  assert.equal(document.getElementById("run-board-title").textContent, "実行中 1",
    "準備中も「実行中」の件数に数える(走っているので)");
  // その機械は「空き」の一覧から外れる
  post(window, { type: "hostMetricsMachines", machines: ["M1Max"] });
  const idle = machineRows(document);
  assert.deepEqual(idle, ["local—"], "準備中でも M1Max は使用中(空きに出さない)");
});

// 最初のシナリオの前の compile-ocr の待ち(RunProgressState.ocrCompileWaitBegan)。進捗も残りもまだ意味を持たない
test("Vision のコンパイル待ちの run は「Vision コンパイル中」を出し、進捗バーは隠す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", machine: "M1Max", observed: true, runs: [{
    pid: 41233, runID: "run-1", mine: true, phase: "compiling", requeued: 0, laneDropouts: 0,
    project: "E2E-iOS", profile: "ios-inapp",
    elapsedSeconds: 30, total: 4, done: 0, failed: 0, lanes: [],
  }] });
  const [runRow] = runRows(document);
  assert.equal(runRow.querySelector(".run-board-counts").textContent, "Vision コンパイル中");
  assert.equal(runRow.querySelector(".run-board-progress").style.display, "none");
});

test("失敗があるときだけ ❌失敗数 を足し、無ければ本数だけ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const base = { pid: 41233, runID: "run-1", mine: true, phase: "running", requeued: 0, laneDropouts: 0,
    project: "E2E-iOS", profile: "ios-inapp", elapsedSeconds: 30, lanes: [] };
  post(window, { type: "monitorRuns", observed: true, runs: [{ ...base, total: 54, done: 54, failed: 2 }] });
  assert.equal(runRows(document)[0].querySelector(".run-board-counts").textContent, "54/54 ❌2");
  post(window, { type: "monitorRuns", observed: true, runs: [{ ...base, total: 54, done: 10, failed: 0 }] });
  assert.equal(runRows(document)[0].querySelector(".run-board-counts").textContent, "10/54");
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

// run の無い機械の行も run の行と**同じ作り**(.run-board-row)を使うので、行の高さも
// インデントも共有の宣言が効く。
test("run の無い機械の行も run の行と同じ作りで、デバイスは機械の1段下に並ぶ", () => {
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  const summary = css.slice(css.indexOf("\n.run-board-row-summary {"));   // 行頭で探す(子孫セレクタに当てない)
  assert.match(summary.slice(0, summary.indexOf("}")), /line-height:\s*20px/,
    "語と — で行の高さが変わらないよう固定する(run の行と共有)");
  assert.equal(css.includes(".run-board-idle-machine {"), false, "専用の行の作りは残さない");
  assert.equal(css.includes(".run-board-row-scope"), false, "根の行は置かない");
  // 2段(機械 → デバイス)。デバイスの名前は機械の行のバッジと同じ位置から始まる
  const lane = css.slice(css.indexOf(".run-board-lane > .run-board-col-left {"));
  assert.match(lane.slice(0, lane.indexOf("}")), /padding-left:\s*40px/);
});

// 機械の並びは常に同じ(local → 登録簿の順)。run が始まると行の種類は変わるが**位置は動かない**
// —— 動くと目が追えない(2026-09-20 の指摘: M1Max の run が local の上に来ていた)。
test("並びは常に機械の順で、run が始まっても位置が動かない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "hostMetricsMachines", machines: ["M1Max", "M1Ultra"] });
  post(window, { type: "monitorRuns", observed: true, runs: [] });                 // local = 空き
  post(window, { type: "monitorRuns", machine: "M1Ultra", observed: true, runs: [] });
  const label = () => boardRows(document).map((el) =>
    `${badgeOf(el)}:${el.dataset.rowKey.startsWith("run") ? "run" : "空き"}`);
  assert.deepEqual(label(), ["local:空き", "M1Max:空き", "M1Ultra:空き"]);

  post(window, monitorRunsMessage({ machine: "M1Max" }));   // 真ん中の機械で run が始まる
  assert.deepEqual(label(), ["local:空き", "M1Max:run", "M1Ultra:空き"],
    "run の始まった機械は同じ位置のまま run の行になる");
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
  assert.equal(chevron.textContent, "▶");
  assert.equal(chevron.getAttribute("aria-expanded"), "false", "run のある行も既定は閉じた状態");
  assert.equal(chevron.dataset.expanded, "false");
  assert.match(chevron.getAttribute("aria-label"), /開く/);
  assert.equal(chevron.title, "", "ツールチップは出さない(名前は aria-label だけ)");
  assert.equal(chevron.dataset.hoverTip, undefined);
  click(window, chevron);
  assert.equal(chevron.textContent, "▶", "文字は展開しても差し替えない");
  assert.equal(chevron.getAttribute("aria-expanded"), "true");
  assert.equal(chevron.dataset.expanded, "true", "向きは CSS の回転で表すので data 属性が要る");
  assert.match(chevron.getAttribute("aria-label"), /閉じる/);
  assert.equal(chevron.title, "");
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

// デバイスの行の左にはデバイスのアイコンを置き、**色はプラットフォームのバッジと同じ**にする
// (ユーザー決定 2026-09-22)。platform を持たないデバイスには色を付けない(知らないものを
// iOS にも Android にも見せない)
test("台の行にはプラットフォームの色のデバイスアイコンが付く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    devices: [
      { id: "ios:iPhone 17-01", name: "iPhone 17-01", platform: "ios", state: "connected",
        kind: "virtual", udid: "UDID-1", recording: false },
      { id: "android:Pixel-01", name: "Pixel-01", platform: "android", state: "connected",
        kind: "virtual", serial: "SER-1", recording: false },
    ],
  });
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  const icons = [...document.querySelectorAll(".run-board-lane")].map((el) => {
    const icon = el.querySelector(".run-board-lane-icon");
    return `${el.querySelector(".run-board-lane-name").textContent}:${icon.getAttribute("class")}`;
  });
  assert.deepEqual(icons, [
    "iPhone 17-01:run-board-lane-icon run-board-lane-icon-ios",
    "Pixel-01:run-board-lane-icon run-board-lane-icon-android",
  ]);
  // アイコンは名前の**左**(左カラムの先頭)に置く
  const first = document.querySelector(".run-board-lane .run-board-col-left");
  assert.equal(first.firstChild.getAttribute("class").includes("run-board-lane-icon"), true);
  // 色はバッジと同じ値(jsdom は CSS を読まないので宣言で押さえる)
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  for (const [platform, color] of [["ios", "#29b6f6"], ["android", "#3ddc84"]]) {
    const icon = css.slice(css.indexOf(`.run-board-lane-icon-${platform} {`));
    const badge = css.slice(css.indexOf(`.platform-badge-${platform}.selected {`));
    assert.match(icon.slice(0, icon.indexOf("}")), new RegExp(`color:\\s*${color}`), platform);
    assert.match(badge.slice(0, badge.indexOf("}")), new RegExp(`background-color:\\s*${color}`), platform);
  }
});

// デバイスの行は**押しても何も起きない**(ユーザー決定 2026-09-22)—— 実行状況を読む場所であって、
// ラインビューの選択を動かす口ではない
test("台の行を押してもラインビューの選択は動かない", (t) => {
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
  const laneEl = document.querySelector(".run-board-lane");
  assert.ok(laneEl, "展開するとレーン行が見える");
  const selected = () => [...document.querySelectorAll("#grid .tile.selected")]
    .map((el) => el.querySelector(".tile-name").textContent.trim());
  const before = selected();
  click(window, laneEl);
  assert.deepEqual(selected(), before, "押す前と同じ(選択を動かさない)");
  // CSS でも押せる面に見せない(jsdom は CSS を読まないので宣言そのものをテキストで押さえる)
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  const lane = css.slice(css.indexOf(".run-board-lane {"));
  assert.doesNotMatch(lane.slice(0, lane.indexOf("}")), /cursor:\s*pointer/);
  assert.equal(css.includes(".run-board-lane:hover {"), false, "hover の地色も付けない");
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
  assert.equal(runRows(document).length, 0);
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
  const issuerEl = document.querySelector(".run-board-issuer");
  assert.notEqual(issuerEl.style.display, "none");
  assert.match(issuerEl.textContent, /alice@air/);

  post(window, { type: "runBoardReset" });
  post(window, monitorRunsMessage());
  const issuerElAfter = document.querySelector(".run-board-issuer");
  assert.equal(issuerElAfter.style.display, "none", "自分の run では issuer 行を出さない");
});

// ---- デバイスのツリー(ユーザー決定 2026-09-22: 実行状態に関わらず出す) ----

/** 機械ごとのデバイス。machine 省略 = 手元(MonitorDevice の規約)。 */
function sendDevices(window, devices) {
  post(window, {
    type: "devices",
    devices: devices.map((d) => ({
      id: `ios:${d.name}`, name: d.name, platform: "ios", state: "connected",
      kind: "virtual", recording: false, ...d,
    })),
  });
}

// run が1本も走っていなくても、認識したデバイスは機械の行のツリーに出す(出さないと「何も無い」
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
  const machines = idleRows(document);
  assert.deepEqual(machines.map(badgeOf), ["local", "M1Max"]);
  assert.deepEqual(laneNames(machines[0]), ["iPhone 17 Pro-01", "iPhone 17 Pro-02"], "手元の台");
  assert.deepEqual(laneNames(machines[1]), ["iPhone 17 Pro-01"], "その機械の台だけ");
});

// run 中でも「その機械のデバイス」を全部出す(ユーザー決定)。run が使っていないデバイスも見える。
test("run の行にも機械の全台が並び、run が使う台にだけシナリオが添う", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [
    { name: "iPhone 17-01", udid: "UDID-1" },   // monitorRunsMessage のレーンと同じ鍵
    { name: "iPhone 17-02", udid: "UDID-2" },   // run に出ていないデバイス
  ]);
  post(window, monitorRunsMessage());
  const row = runRows(document)[0];
  assert.deepEqual(laneNames(row), ["iPhone 17-01", "iPhone 17-02"], "run に出ていない台も並ぶ");
  const scenarios = [...row.querySelectorAll(".run-board-lane-scenario")].map((el) => el.textContent);
  assert.deepEqual(scenarios, ["▶ 05_検索", ""], "run が使っている台にだけシナリオを添える");
});

// タイルが消えたデバイス(観測窓の外)でも run の事実は残す —— レーンの側にしか無いデバイスを落とすと、
// 走っているのにツリーから消える
test("レーンにしか無い台も run の行に残る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{ name: "iPhone 17-02", udid: "UDID-2" }]);   // レーンのデバイスは居ない
  post(window, monitorRunsMessage());
  const row = runRows(document)[0];
  assert.deepEqual(laneNames(row), ["iPhone 17-02", "iPhone 17-01"], "台の一覧のあとにレーンだけの台");
});

// 「起動中のデバイス」(設定 fleetest.monitorDeviceFilter)はタイル側だけの表示フィルタ ——
// ツリーにも効かせると、**ビルド中の run の下からデバイスが丸ごと消える**(供給前なのでどのデバイスも
// まだ起動していない)。ユーザー指摘 2026-09-22 / docs/design.md §18.5。
test("「起動中のデバイス」で絞っていてもツリーの台は消えない(消えるのはタイルだけ)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    filter: "running",
    devices: [
      { id: "ios:iPhone 17-01", name: "iPhone 17-01", platform: "ios", state: "offline",
        kind: "virtual", udid: "UDID-1", recording: false },
      { id: "ios:iPhone 17-02", name: "iPhone 17-02", platform: "ios", state: "connected",
        kind: "virtual", udid: "UDID-2", recording: false },
    ],
  });
  // ビルド中 = レーンがまだ1本も無い。デバイスの一覧だけがツリーの供給源になる
  post(window, { type: "monitorRuns", observed: true, runs: [{
    pid: 41233, runID: "run-1", mine: true, phase: "building", requeued: 0, laneDropouts: 0,
    project: "E2E-CMP", profile: "ios-inapp",
    elapsedSeconds: 8, total: 0, done: 0, failed: 0, lanes: [],
  }] });
  const row = runRows(document)[0];
  assert.equal(row.querySelector(".run-board-counts").textContent, "ビルド中");
  assert.deepEqual(laneNames(row), ["iPhone 17-01", "iPhone 17-02"],
    "停止中の台もツリーには出す(run の下から台を消さない)");
  assert.deepEqual([...document.querySelectorAll("#grid .tile .tile-name")].map((el) => el.textContent),
    ["iPhone 17-02"], "タイルは従来どおり起動中だけ");
});

// 上と対: 機械の行(run 無し)のツリーも同じ規律 —— 全台停止中の機械が「デバイスが1枚も無い」に
// 見えると、フリートに何が居るのかがここから分からない
test("run が無い機械の枝でも、停止中の台がツリーに並ぶ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  post(window, {
    type: "devices",
    filter: "running",
    devices: [{ id: "ios:iPhone 17-01", name: "iPhone 17-01", platform: "ios", state: "offline",
                kind: "virtual", udid: "UDID-1", recording: false }],
  });
  assert.deepEqual(laneNames(idleRows(document)[0]), ["iPhone 17-01"]);
});

// 既定は **run のある行が開き・run の無い行が閉じ**(ユーザー決定 2026-09-30 の図)。
// 三角を押した「その場で」開閉する —— 次の監視サイクル(約2秒)を待つ作りにすると、
// 押してから開くまでの遅れが目に見える(ユーザー指摘 2026-09-22)。
test("run の無い機械の行は既定で閉じ、三角でその場で開閉できる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  sendDevices(window, [{ name: "iPhone 17 Pro-01", udid: "U-L1" }]);
  const row = () => idleRows(document)[0];
  assert.equal(row().classList.contains("run-board-row-expanded"), false, "run の無い行の既定は閉じた状態");
  assert.deepEqual(laneNames(row()), ["iPhone 17 Pro-01"], "閉じていても子は持つ(CSS で隠す)");

  click(window, row().querySelector(".run-board-chevron"));
  assert.equal(row().classList.contains("run-board-row-expanded"), true, "押した直後に開く");
  assert.equal(row().querySelector(".run-board-chevron").dataset.expanded, "true");
  // 次の監視サイクルが来ても利用者の開閉を保つ
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  assert.equal(row().classList.contains("run-board-row-expanded"), true, "描き直しでも開いたまま");

  click(window, row().querySelector(".run-board-chevron"));
  assert.equal(row().classList.contains("run-board-row-expanded"), false, "押した直後に閉じる");
});

// 「全て展開を維持」が OFF の間は、利用者が開かない限りどの行も開かない(ユーザー決定 2026-10-01)。
// 開閉の記録は機械ごと —— 行の鍵(pid・run の有無)で引くと、次の run や 空き⇔実行中 の
// 切り替わりで記録を失い、行が勝手に開閉する。
const expandedMachines = (document) => boardRows(document)
  .filter((el) => el.classList.contains("run-board-row-expanded")).map(badgeOf);

function runOn(machine, pid) {
  return { type: "monitorRuns", machine, observed: true,
           runs: [{ ...monitorRunsMessage().runs[0], machine, pid, runID: `run-${pid}` }] };
}

function twoMachines(window) {
  post(window, { type: "hostMetricsMachines", machines: ["M1Max"] });
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  post(window, { type: "monitorRuns", machine: "M1Max", observed: true, runs: [] });
  sendDevices(window, [
    { name: "iPhone 17-01", udid: "UDID-1" },
    { name: "iPhone 17 Pro-01", id: "ios:M1Max-01", udid: "U-M1", machine: "M1Max" },
  ]);
}

test("展開維持 OFF では run が始まっても行は開かない(空き → 実行中 → 次の run)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  twoMachines(window);
  assert.deepEqual(expandedMachines(document), []);
  post(window, runOn(undefined, 100));
  post(window, runOn("M1Max", 200));
  assert.equal(runRows(document).length, 2);
  assert.deepEqual(expandedMachines(document), [], "run が始まっても開かない");
  post(window, runOn("M1Max", 201));
  assert.deepEqual(expandedMachines(document), [], "次の run(別の pid)でも開かない");
});

test("開いた機械は次の run・空きに戻っても開いたまま、他の機械は閉じたまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  twoMachines(window);
  click(window, idleRows(document)[1].querySelector(".run-board-chevron"));
  assert.deepEqual(expandedMachines(document), ["M1Max"]);
  post(window, runOn("M1Max", 200));
  assert.deepEqual(expandedMachines(document), ["M1Max"], "空き → 実行中");
  post(window, runOn("M1Max", 201));
  assert.deepEqual(expandedMachines(document), ["M1Max"], "次の run");
  click(window, runRows(document)[0].querySelector(".run-board-chevron"));
  assert.deepEqual(expandedMachines(document), [], "run の行で閉じる");
  post(window, { type: "monitorRuns", machine: "M1Max", observed: true, runs: [] });
  assert.deepEqual(expandedMachines(document), [], "実行中 → 空き でも閉じたまま");
});

test("展開維持 ON は全行を開き、あとから始まった run も開く。OFF に戻すと全部閉じる", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  twoMachines(window);
  const button = document.getElementById("run-board-expand-all");
  click(window, button);
  assert.deepEqual(sent.filter((m) => m.type === "setRunBoardExpandAll").map((m) => m.value), [true]);
  assert.deepEqual(expandedMachines(document), ["local", "M1Max"]);
  post(window, runOn("M1Max", 200));
  assert.deepEqual(expandedMachines(document), ["local", "M1Max"], "あとから始まった run も開く");
  click(window, button);
  assert.deepEqual(expandedMachines(document), [], "OFF で全部閉じる");
  post(window, runOn("M1Max", 201));
  assert.deepEqual(expandedMachines(document), [], "OFF のあとの run も開かない");
});

test("展開維持 ON のまま1行を閉じるとモードを抜け、他の行は開いたまま", (t) => {
  const { window, document, sent } = createWebview();
  t.after(() => window.close());
  twoMachines(window);
  post(window, { type: "runBoardExpandAll", value: true });
  assert.deepEqual(expandedMachines(document), ["local", "M1Max"]);
  click(window, idleRows(document)[0].querySelector(".run-board-chevron"));
  assert.deepEqual(sent.filter((m) => m.type === "setRunBoardExpandAll").map((m) => m.value), [false]);
  assert.deepEqual(expandedMachines(document), ["M1Max"]);
  assert.equal(document.getElementById("run-board-expand-all").getAttribute("aria-pressed"), "false");
});

// 準備中の控えは runID を持たず、走り出すと同じ pid の控えが runID 入りに上書きされる。
test("準備中に開いた run の行は、走り出して runID が付いても開いたまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, [{ name: "iPhone 17 Pro-01", udid: "U-L1" }]);
  const run = (fields) => ({ type: "monitorRuns", observed: true, runs: [Object.assign({
    pid: 41233, mine: true, requeued: 0, laneDropouts: 0, project: "E2E-iOS", profile: "ios-inapp",
    elapsedSeconds: 3, total: 0, done: 0, failed: 0, lanes: [],
  }, fields)] });
  post(window, run({ phase: "preparing" }));
  const row = () => runRows(document)[0];
  assert.equal(row().classList.contains("run-board-row-expanded"), false);
  click(window, row().querySelector(".run-board-chevron"));
  assert.equal(row().classList.contains("run-board-row-expanded"), true);

  post(window, run({ phase: "running", runID: "run-1", runGroup: "group-1", total: 4, done: 1 }));
  assert.equal(runRows(document).length, 1);
  assert.equal(row().classList.contains("run-board-row-expanded"), true, "走り出しても開いたまま");
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
  const summary = runRows(document)[0].querySelector(".run-board-row-summary");
  assert.match(colText(summary, "left"), /^▶local ?ec-mobile \/ ios-smoke$/, "左 = 機械と run の範囲");
  assert.match(colText(summary, "right"), /7\/12/, "右 = 進捗");
  assert.match(colText(summary, "right"), /4:21/, "右 = 経過");
  const lane = document.querySelector(".run-board-lane");
  assert.equal(colText(lane, "left"), "iPhone 17-01", "左 = 台の名前だけ");
  assert.match(colText(lane, "right"), /05_検索/, "右 = 実行中のシナリオ");
});

test("run の無い機械の行も同じ2カラム(名前は左・状態は右)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  const header = idleRows(document)[0].querySelector(".run-board-row-summary");
  assert.equal(colText(header, "left").includes("local"), true);
  const status = header.querySelector(".run-board-idle-machine-status");
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
// デバイスが増えて名前が伸びたら追従する(ドラッグするまでの間)。
test("境目の既定はいちばん長いラベル + 100px で、ドラッグで幅が変わる", (t) => {
  const { window, document, sent, getState } = createWebview();
  t.after(() => window.close());
  giveWidth(document);
  giveLabelWidth(window, 10);
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  // 機械の行の左カラムは "▶local"(6字)。**いちばん長い行に合わせる**ので、デバイスが出ると
  // そちら("iPhone 17 Pro-01" = 16字)に広がる。既定は**それに 100px 足した幅**(ユーザー決定 2026-09-30)
  assert.equal(leftWidth(document), "161px", "6字 × 10 + 端数 0.4 を切り上げて 61 + 100");
  sendDevices(window, [{ name: "iPhone 17 Pro-01", udid: "U-1" }]);
  // 16字 × 10 + 端数 0.4 → **切り上げる**(切り捨てるとその行だけ "…" になる)+ 100
  assert.equal(leftWidth(document), "261px", "短い行ではなく長い行に合わせ、端数は切り上げる");

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


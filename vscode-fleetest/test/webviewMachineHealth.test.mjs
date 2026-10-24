// ダッシュボード「マシンの健全性」(dashboard/machineHealth.js)を実 HTML+実バンドルで動かす DOM テスト(jsdom)。
// 履歴(api results の machineHealth)とモニター(hostCharts.js の最新サンプル)の結合・「–」と 0 の区別・
// FM チップ・警告色・内訳ツールチップを見る。方式は webviewDashboardExtras.test.mjs / webviewHostMetricsRows.test.mjs と同じ。

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

function createWebview(posted = [], persisted = undefined) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const noop = () => {};
  window.HTMLCanvasElement.prototype.getContext = () => ({
    setTransform: noop, clearRect: noop, beginPath: noop, moveTo: noop, lineTo: noop,
    closePath: noop, fillRect: noop, stroke: noop, fill: noop, globalAlpha: 1, fillStyle: "", strokeStyle: "",
    lineWidth: 0, lineJoin: "", lineCap: "",
  });
  window.acquireVsCodeApi = () => ({ postMessage: (m) => posted.push(m), setState: noop, getState: () => persisted });
  window.HTMLElement.prototype.scrollIntoView = noop;
  window.Element.prototype.setPointerCapture = noop;
  window.Element.prototype.releasePointerCapture = noop;
  window.eval(webviewBundle);
  window.document.getElementById("tab-dashboard").click();
  const send = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  return { window, document: window.document, send };
}

const RUN = {
  schemaVersion: 1, runID: "20260901-000000Z-abcd1234", project: "P", profile: "ios-inapp",
  host: "H", trigger: "cli", startedAt: "2026-09-01T00:00:00Z", finishedAt: "2026-09-01T00:01:00Z",
  total: 3, passed: 2, failed: 1,
};

function payload(machineHealth, machines = []) {
  return {
    schemaVersion: 1, project: "P", generatedAt: "2026-09-01T00:02:00Z", since: "2026-06-03T00:00:00Z",
    runs: [RUN], summary: [], flaky: [], deviceHealth: [], machineHealth,
    slow: [], insights: [], performance: { runs: [], invalidCount: 0 }, machines, runStats: [],
  };
}

function health(host, overrides = {}) {
  return { host, runs: 2, fmDeadRuns: 0, notes: {}, ...overrides };
}

function sample(machine, extra = {}) {
  return {
    type: "hostMetrics", ...(machine ? { machine } : {}),
    cpu: 0.34, cpuCores: 8, gpu: 0.1, gpuCores: 38,
    memUsedBytes: 61 * 1024 ** 3, memTotalBytes: 100 * 1024 ** 3,
    fmCalls: 0, fmFailures: 0, fmTotalMs: 0, fmTextState: null, fmVisionState: null, fmDeadReason: null,
    fmCheckedAt: Date.now() / 1000, visionCalls: 0, visionFailures: 0, visionTotalMs: 0, ocrCompiling: 0,
    ...extra,
  };
}

function loadData(send, p) {
  send({ type: "dashboard", message: { type: "data", payload: p } });
}

const rowsOf = (document) => [...document.querySelectorAll("#table-machine-health-body tr")];
const labelOf = (tr) => tr.children[0].textContent;
const tipOf = (cell) => cell.getAttribute("data-hover-tip") || "";

test("行の集合は履歴とモニターの和集合で、local が先頭・残りは名前昇順", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  send({ type: "hostMetricsMachines", machines: ["zeta"] });
  send(sample("zeta"));
  send(sample(""));
  loadData(send, payload([health("alpha-host"), health("H")], [{ host: "alpha-host", machine: "alpha" }]));
  assert.deepEqual(rowsOf(document).map(labelOf), ["local", "H", "alpha", "zeta"]);
  const alpha = rowsOf(document)[2];
  assert.equal(alpha.children[1].textContent.includes("?"), true, "モニターに居ない行の FM は不明");
  assert.equal(alpha.children[4].textContent, "–", "モニターに居ない行の負荷は「–」");
  const zeta = rowsOf(document)[3];
  assert.equal(zeta.children[5].textContent, "–", "履歴に居ない行の実行は「–」");
  assert.equal(zeta.children[12].textContent, "–");
  assert.equal(zeta.children[6].textContent, "–");
});

test("履歴の 0 と欠けている値(nil)を区別する", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  send(sample(""));
  loadData(send, payload([health("H", { runs: 0 }), health("X")]));
  const [h, x] = rowsOf(document).filter((tr) => ["H", "X"].includes(labelOf(tr)));
  for (const tr of [h, x]) {
    assert.equal(tr.children[12].textContent, "0", "fmDeadRuns 0");
    assert.equal(tr.children[10].textContent, "–", "fm が nil なら FM 失敗は「–」");
    assert.equal(tr.children[11].textContent, "–", "guard が nil なら「–」");
    assert.equal(tr.children[9].textContent, "–");
    assert.equal(tr.children[7].textContent, "0", "注記は 0 件と表示");
    assert.equal(tr.children[6].textContent, "–", "pacedSteps が nil なら「–」");
  }
  assert.equal(h.children[5].textContent, "0");
});

test("FM チップ: 生存・停止・不明を文字と記号で出し、停止は理由と確認時刻をツールチップに載せる", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  send({ type: "hostMetricsMachines", machines: ["m2", "m3"] });
  send(sample("m2", { fmTextState: "alive", fmVisionState: "dead", fmDeadReason: "no memory" }));
  send(sample("m3"));
  send(sample(""));
  loadData(send, payload([]));
  const byLabel = Object.fromEntries(rowsOf(document).map((tr) => [labelOf(tr), tr]));
  const m2 = byLabel.m2.children[1];
  const chips = [...m2.querySelectorAll(".mh-chip")];
  assert.equal(chips.length, 2);
  assert.equal(chips[0].textContent, "● Text");
  assert.equal(chips[0].getAttribute("aria-label"), "Text alive");
  assert.ok(chips[0].classList.contains("mh-fm-alive"));
  assert.equal(chips[1].textContent, "✕ Image");
  assert.equal(chips[1].getAttribute("aria-label"), "Image dead");
  assert.ok(chips[1].classList.contains("mh-fm-dead"));
  assert.match(tipOf(m2), /no memory/);
  const m3 = [...byLabel.m3.children[1].querySelectorAll(".mh-chip")];
  assert.ok(m3.every((c) => c.classList.contains("mh-fm-unknown") && c.textContent.includes("?")));
});

test("AVE チップ: 生存・停止・不明を記号で出し、停止は理由と確認時刻をツールチップに載せる", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  send({ type: "hostMetricsMachines", machines: ["m2", "m3"] });
  send(sample("m2", { videoEncoderState: "dead", videoEncoderError: "-17691", videoEncoderCheckedAt: Date.now() / 1000 }));
  send(sample("m3", { videoEncoderState: "alive", videoEncoderCheckedAt: Date.now() / 1000 }));
  send(sample(""));
  loadData(send, payload([]));
  const byLabel = Object.fromEntries(rowsOf(document).map((tr) => [labelOf(tr), tr]));
  const dead = byLabel.m2.children[2];
  const deadChip = dead.querySelector(".mh-chip");
  assert.equal(deadChip.textContent, "✕");
  assert.ok(deadChip.classList.contains("mh-fm-dead"));
  assert.equal(deadChip.getAttribute("aria-label"), "AVE dead");
  assert.match(tipOf(dead), /ハードウェアビデオエンコーダー/);
  assert.match(tipOf(dead), /-17691/);
  assert.match(tipOf(dead), /確認: /);
  const alive = byLabel.m3.children[2].querySelector(".mh-chip");
  assert.equal(alive.textContent, "●");
  assert.ok(alive.classList.contains("mh-fm-alive"));
  const unknown = byLabel.local.children[2].querySelector(".mh-chip");
  assert.equal(unknown.textContent, "?");
  assert.ok(unknown.classList.contains("mh-fm-unknown"));
});

test("今の列: Vision の件数・失敗(>0 で警告色)・コンパイル中・負荷", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  send(sample("", { visionCalls: 4, visionFailures: 1, ocrCompiling: 1 }));
  loadData(send, payload([]));
  const local = rowsOf(document)[0];
  const vision = local.children[3];
  assert.match(vision.textContent, /4/);
  assert.match(vision.textContent, /1/);
  assert.ok(vision.classList.contains("mh-warn"));
  assert.ok(vision.querySelector(".mh-chip-compiling"));
  assert.match(tipOf(vision), /1/, "窓の秒数");
  assert.equal(local.children[4].textContent, "CPU 34% · MEM 61%");
});

test("今の列の数字は幅の決まった枠に入る(90% → 100% で列幅が組み直されて表が動かない)", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  send(sample("", { cpu: 0.9, visionCalls: 7, visionFailures: 0 }));
  loadData(send, payload([]));
  const nums = (cell) => [...cell.querySelectorAll(".mh-num")].map((el) => [el.textContent, el.className]);
  const local = rowsOf(document)[0];
  assert.deepEqual(nums(local.children[4]), [["90%", "mh-num mh-num-4"], ["61%", "mh-num mh-num-4"]]);
  assert.deepEqual(nums(local.children[3]), [["7", "mh-num mh-num-4"], ["0", "mh-num mh-num-3"]]);
  send(sample("", { cpu: 1, visionCalls: 7, visionFailures: 0 }));
  assert.equal(rowsOf(document)[0].children[4].textContent, "CPU 100% · MEM 61%");
  assert.deepEqual(nums(rowsOf(document)[0].children[4])[0], ["100%", "mh-num mh-num-4"]);
  const css = readFileSync(path.resolve("src/webview/dashboard/style.css"), "utf8");
  assert.match(css, /\.mh-num \{[^}]*display: inline-block;[^}]*font-variant-numeric: tabular-nums;/);
  assert.match(css, /\.mh-num-3 \{ min-width: 3ch; \}/);
  assert.match(css, /\.mh-num-4 \{ min-width: 4ch; \}/);
});

test("集計期間の列: 失敗・停止・素通り・要注意の注記で警告色になり、内訳ツールチップが出る", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  send(sample(""));
  const fm = {
    scenarios: 3, calls: 20, failures: 2, retries: 1, retrySuccesses: 1, skipped: 0, totalMs: 4000, maxMs: 900,
    gateWaitTotalMs: 6000, gateWaitMaxMs: 2500,
    lastError: { at: "2026-09-01T00:00:00Z", scenarioID: "Foo.S0010", message: "boom" },
  };
  loadData(send, payload([
    health("H", {
      fmDeadRuns: 1, lastFMDead: { at: "2026-09-01T00:00:00Z", paths: ["text"], reason: "ane down" },
      guarded: 10, guardSkipped: 2, guardStaleFrame: 1, fm,
      notes: { "ocr-budget-exhausted": 3, "ocr-compile-waited": 2, "vision-helper-rescued": 4, mystery: 9 },
      pacedSteps: 5, pacedMs: 2500,
    }),
    health("Quiet", { guarded: 5, guardSkipped: 0, notes: { "ocr-compile-waited": 1, "vision-helper-rescued": 1 } }),
  ]));
  const byLabel = Object.fromEntries(rowsOf(document).map((tr) => [labelOf(tr), tr]));
  const h = byLabel.H;
  assert.ok(h.children[12].classList.contains("mh-warn"));
  assert.match(tipOf(h.children[12]), /ane down/);
  assert.equal(h.children[10].textContent, "2 / 20");
  assert.ok(h.children[10].classList.contains("mh-warn"));
  assert.match(tipOf(h.children[10]), /boom/);
  assert.equal(h.children[11].textContent, "2 / 10");
  assert.ok(h.children[11].classList.contains("mh-warn"));
  assert.equal(h.children[9].textContent, "2.5");
  assert.equal(h.children[7].textContent, "5", "OCR 群の合計(未知の mystery は数えない)");
  assert.ok(h.children[7].classList.contains("mh-warn"));
  assert.match(tipOf(h.children[7]), /OCR の予算切れ: 3/);
  assert.match(tipOf(h.children[7]), /OCR のコンパイルを待った: 2/);
  assert.equal(h.children[8].textContent, "4");
  assert.equal(h.children[8].classList.contains("mh-warn"), false, "情報の注記だけなら警告色にしない");
  assert.equal(h.children[6].textContent, "5");
  assert.match(tipOf(h.children[6]), /2\.5/);

  const quiet = byLabel.Quiet;
  assert.equal(quiet.children[11].textContent, "0 / 5");
  assert.equal(quiet.children[11].classList.contains("mh-warn"), false);
  assert.equal(quiet.children[7].classList.contains("mh-warn"), false);
});

test("両方が届くまでは空の文言が「確認中」で、行が無ければ記録なしの文言になる", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  const empty = document.getElementById("machines-empty");
  loadData(send, payload([]));
  assert.match(empty.textContent, /確認/);
  send(sample(""));
  assert.equal(rowsOf(document).length, 1);
  assert.equal(empty.style.display, "none");
});

test("期間内の run が0件でも健全性の2セクションは出し、他のセクションだけ隠す", async (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  // jsdom は外部 CSS を読まないので、隠す側は「#content に dash-no-runs が付く」+「CSS にその規則がある」で見る
  const visible = (id) => document.getElementById(id).style.display !== "none";
  const content = document.getElementById("content");
  loadData(send, { ...payload([health("H")]), runs: [] });
  assert.equal(visible("content"), true);
  assert.equal(visible("status-empty"), true);
  assert.equal(content.classList.contains("dash-no-runs"), true);
  assert.deepEqual(rowsOf(document).map(labelOf), ["H"]);
  const { readFile } = await import("node:fs/promises");
  const css = await readFile(path.resolve("src/webview/dashboard/style.css"), "utf8");
  assert.match(css, /#content\.dash-no-runs > \.dash-section:not\(#section-machines\):not\(#section-devices\)\s*\{\s*display: none !important;/);
  // 文言は健全性の2セクションの直後(他のセクションより前)にある
  const order = [...content.children].map((el) => el.id);
  assert.ok(order.indexOf("status-empty") > order.indexOf("section-devices"));
  assert.ok(order.indexOf("status-empty") < order.indexOf("section-headline"));

  // run が戻れば隠しを外し、0件の文言は消える
  loadData(send, payload([health("H")]));
  assert.equal(visible("status-empty"), false);
  assert.equal(content.classList.contains("dash-no-runs"), false);
});

test("見出し「集計期間」に窓の開始(since)と集計時刻(generatedAt)を手元の時刻で付ける", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  const header = document.getElementById("mh-period-header");
  assert.equal(header.textContent, "集計期間");
  loadData(send, payload([health("H")]));
  const stamp = "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}";
  assert.match(header.textContent, new RegExp(`^集計期間（${stamp} - ${stamp}）$`));
  const pad = (n) => String(n).padStart(2, "0");
  const local = (iso) => {
    const d = new Date(iso);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  };
  assert.equal(header.textContent, `集計期間（${local("2026-06-03T00:00:00Z")} - ${local("2026-09-01T00:02:00Z")}）`);
  // run が0件でも付ける(健全性は期間に関わらず出すので、どの期間の集計かは常に要る)
  loadData(send, { ...payload([]), runs: [], since: "2026-08-31T23:02:00Z" });
  assert.equal(header.textContent, `集計期間（${local("2026-08-31T23:02:00Z")} - ${local("2026-09-01T00:02:00Z")}）`);
});

test("1Hz の更新では行を作り直さず「今」の列だけを同じセルで差し替える(ホバー中のツールチップが点滅しない)", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  loadData(send, payload([health("H", { notes: { "vision-helper-rescued": 2 } })], [{ host: "H", machine: "local" }]));
  send(sample("", { cpu: 0.2 }));
  const tr = rowsOf(document)[0];
  const notesCell = tr.children[8];
  const loadCellEl = tr.children[4];
  assert.match(loadCellEl.textContent, /20%/);
  send(sample("", { cpu: 0.55 }));
  const after = rowsOf(document)[0];
  assert.equal(after, tr, "行は同じ要素のまま");
  assert.equal(after.children[8], notesCell, "集計期間のセル(ホバー中かもしれない)は同じ要素のまま");
  assert.equal(after.children[4], loadCellEl, "今の列も同じ td の中身だけを差し替える");
  assert.match(loadCellEl.textContent, /55%/);
});

test("集計期間の列は発生順(実行 → 減速 → OCR → Vision → FM 枠待ち → FM 失敗 → 判定の素通り → FM 停止)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const heads = [...document.querySelectorAll("#table-machine-health thead tr:nth-child(2) th")].map((th) => th.textContent);
  assert.deepEqual(heads.slice(4), ["実行", "減速", "OCR 注記", "Vision 注記", "FM 枠待ち", "FM 失敗", "判定の素通り", "FM 停止"]);
});

test("他のタブからダッシュボードへ切り替えたら取り直す(起動時・ダッシュボードのままの切り替えでは送らない)", (t) => {
  const posted = [];
  const { window, document, send } = createWebview(posted);
  t.after(() => window.close());
  const refreshes = () => posted.filter((m) => m.type === "dashboard" && m.message.type === "refresh").length;
  // createWebview は起動時の初期タブ(デバイスモニター)からダッシュボードへ切り替える = 1回。起動時の最初の
  // 切り替え(初期タブの表示)では送らない(ready が取得する)
  assert.equal(refreshes(), 1);
  // 表示中のタブのクリックは tabs.js が捨てるので、ダッシュボードのままの切り替えはホストの switchTab で起こす
  send({ type: "switchTab", tab: "dashboard" });
  assert.equal(refreshes(), 1, "ダッシュボードのまま");
  document.getElementById("tab-devices").click();
  assert.equal(refreshes(), 1);
  document.getElementById("tab-dashboard").click();
  assert.equal(refreshes(), 2, "他のタブから切り替えたときだけ取り直す");
});

test("起動時の初期タブがダッシュボードなら refresh を送らない(ready が同じ取得を起こす)", (t) => {
  const posted = [];
  const { window } = createWebview(posted, { activeTab: "dashboard" });
  t.after(() => window.close());
  const types = posted.filter((m) => m.type === "dashboard").map((m) => m.message.type);
  assert.deepEqual(types.filter((type) => type === "refresh"), []);
  assert.ok(types.includes("ready"));
});

test("プロジェクトの選択は本文があれば「最後の実行」の直前、本文が隠れている間はツールバーの直下(選び直して復帰できる)", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  const row = document.getElementById("dash-project-row");
  const toolbar = document.getElementById("dash-toolbar");
  assert.equal(toolbar.querySelector("#dash-project-select"), null, "ツールバーには置かない");
  assert.ok(row.querySelector(".dash-title") && row.querySelector("#dash-project-select"));
  send({ type: "dashboard", message: { type: "error", message: "project unresolved" } });
  assert.equal(document.getElementById("content").style.display, "none");
  assert.equal(toolbar.nextElementSibling, row, "本文が隠れている間はツールバーの直下");
  loadData(send, payload([]));
  assert.equal(row.nextElementSibling, document.getElementById("section-headline"));
  assert.equal(row.parentElement, document.getElementById("content"));
  assert.ok(document.getElementById("content").classList.contains("dash-no-runs") === false);
});

test("run が0件でもプロジェクトの選択は本文の中に残る(.dash-no-runs が隠すのは .dash-section だけ)", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  loadData(send, { ...payload([]), runs: [] });
  const content = document.getElementById("content");
  assert.ok(content.classList.contains("dash-no-runs"));
  const row = document.getElementById("dash-project-row");
  assert.equal(row.parentElement, content);
  assert.equal(row.nextElementSibling, document.getElementById("section-headline"));
  assert.ok(!row.classList.contains("dash-section"));
});

test("プロジェクトの行はツールバー(集計期間の行)と同じ帯で、ツールバーの実測の高さの位置に貼り付く(sticky)", () => {
  const css = readFileSync(path.resolve("src/webview/dashboard/style.css"), "utf8");
  const band = css.match(/\.dash-toolbar,\n\.dash-project-row \{[^}]*\}/);
  assert.ok(band, "帯の見た目は2つの行で1つの規則");
  assert.match(band[0], /position: sticky;/);
  assert.match(band[0], /background-color:/, "下を流れる本文が透けない");
  assert.match(band[0], /background-image: linear-gradient/);
  assert.match(css, /\n\.dash-project-row \{\n  top: var\(--dash-toolbar-height, 0px\);\n\}/);
  const js = readFileSync(path.resolve("src/webview/monitor/dashboardTab.js"), "utf8");
  assert.match(js, /setProperty\('--dash-toolbar-height'/);
});

test("「更新」は押した瞬間から取得の終わり(data / error)までリングを回す", (t) => {
  const posted = [];
  const { window, document, send } = createWebview(posted);
  t.after(() => window.close());
  const btn = document.getElementById("btn-refresh");
  const busy = () => [btn.classList.contains("busy"), btn.getAttribute("aria-busy")];
  send({ type: "dashboard", message: { type: "loading" } });
  assert.deepEqual(busy(), [true, "true"], "最初の読み込み中も回す");
  loadData(send, payload([]));
  assert.deepEqual(busy(), [false, "false"]);
  btn.click();
  assert.deepEqual(busy(), [true, "true"], "ホストの loading を待たずに回す");
  assert.ok(posted.some((m) => m.type === "dashboard" && m.message.type === "refresh"));
  send({ type: "dashboard", message: { type: "loading" } });
  assert.deepEqual(busy(), [true, "true"]);
  send({ type: "dashboard", message: { type: "error", message: "boom" } });
  assert.deepEqual(busy(), [false, "false"], "失敗でも止める");
  btn.click();
  loadData(send, payload([health("H")]));
  assert.deepEqual(busy(), [false, "false"]);
});

test("「更新」のリングはタブバーの「更新する」と同じ規則・集計期間の右に余白", () => {
  const monitorCss = readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");
  assert.match(monitorCss, /#tabbar \.tabbar-update\.busy::before,\n#panel-dashboard #btn-refresh\.busy::before \{[^}]*animation: ft-placeholder-spin/);
  const css = readFileSync(path.resolve("src/webview/dashboard/style.css"), "utf8");
  assert.match(css.match(/\.dash-since-field \{[^}]*\}/)[0], /margin-right: 8px;/);
  assert.match(css.match(/\.dash-since-field \{[^}]*\}/)[0], /gap: 8px;/, "ラベルと選択欄の間");
  assert.match(css, /\n\.dash-title,\n\.dash-since-label \{\n  font-weight: 600;\n\}/, "集計期間のラベルはテストプロジェクトのラベルと同じ規則");
  assert.equal(css.match(/\.dash-since-label[ ,{]/g).length, 1, "集計期間のラベルの規則は上の1つだけ(控えめな色・小さい字の規則を持たない)");
});

test("テストプロジェクトの選択欄も集計期間と同じ色の枠(録画タブと共用の select.dash-project は変えない)", () => {
  const css = readFileSync(path.resolve("src/webview/dashboard/style.css"), "utf8");
  const rule = css.match(/select\.dash-since,\n#panel-dashboard select#dash-project-select \{[^}]*\}/);
  assert.ok(rule, "集計期間と1つの規則");
  assert.match(rule[0], /border: 1px solid var\(--vscode-button-background\);/);
  assert.doesNotMatch(css.match(/\nselect\.dash-project \{[^}]*\}/)[0], /button-background/);
});

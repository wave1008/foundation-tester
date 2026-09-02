// ツールバーのホストグラフ(MEM/CPU/GPU/FM)を**機械ごとの行**にする配線テスト(hostCharts.js)。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewAutoFitToggle.test.mjs と同じ。
//
// ここで見るのは行の集合と宛先の分岐だけ(描画そのものは jsdom にキャンバスが無いので測れない):
// - 既定は手元の1行だけ。左端の機械名は出さない(.hm-multi が付かない)
// - hostMetricsMachines で行が増え、左端が local / <機械名> になる
// - サンプルは machine の行にだけ積む(手元のサンプルが machine 欄を持たないことと対)
// - **描く瞬間は全行で1つ**(リモートは受信時には保持だけ・手元の tick で保持済みの最新値を描く)
// - 手元が黙ったら刻みをリモートへ委譲し、手元が戻れば手元へ返す
// - 機械が消えたら行も消える(観測が止まったまま最後の値を出し続けない)
// - FM(供給元は hostMetrics サンプルの fmCalls/fmFailures/fmTotalMs)も機械ごとの行へ、
//   直近10 tick の移動窓レート(回/秒)として積む

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

/** jsdom は canvas を持たない(getContext が null)。描画は測らないので何もしない 2D を返す。 */
function stubCanvas(window) {
  const noop = () => {};
  window.HTMLCanvasElement.prototype.getContext = () => ({
    setTransform: noop, clearRect: noop, beginPath: noop, moveTo: noop, lineTo: noop,
    closePath: noop, stroke: noop, fill: noop, globalAlpha: 1, fillStyle: "", strokeStyle: "",
    lineWidth: 0, lineJoin: "", lineCap: "",
  });
}

/** window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない */
function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.Element.prototype.setPointerCapture = () => {};
  window.Element.prototype.releasePointerCapture = () => {};
  stubCanvas(window);
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function send(window, message) {
  window.dispatchEvent(new window.MessageEvent("message", { data: message }));
}

function rows(document) {
  return [...document.querySelectorAll("#host-metrics .hm-row")];
}

function machineLabels(document) {
  return rows(document).map((row) => row.querySelector(".hm-machine").textContent);
}

/** 1行ぶんの表示値(MEM/CPU/GPU/FM の順)。 */
function values(row) {
  return [...row.querySelectorAll(".host-metric")].map((metric) => metric.querySelector(".hm-value").textContent);
}

function rowFor(document, machine) {
  return document.querySelector(`#host-metrics .hm-row[data-machine="${machine}"]`);
}

/** FM のツールチップ。**窓(直近 N tick)の集計はラベルではなくここに出る** ——
 *  ラベルは直近 1 tick の回数なので、窓の不変条件(欠測を分母に入れない・古い tick を落とす)は
 *  こちらでしか検証できない。 */
function fmTitle(document, machine) {
  return rowFor(document, machine).querySelector('[data-metric="fm"]').title;
}

/** fm 省略時は fmCalls:0(既知の0件、欠測ではない)。欠測にしたいテストは { fmCalls: null } を渡す。
 *  死活(fmTextState/fmVisionState/fmDeadReason/fmCheckedAt)は**回数とは別の軸**なので、
 *  省略時は不明(null)= 旧 CLI の行と同じ形。 */
function hostMetricsSample(machine, cpu, fm = {}) {
  const {
    fmCalls = 0, fmFailures = 0, fmTotalMs = 0,
    fmTextState = null, fmVisionState = null, fmDeadReason = null,
    fmCheckedAt = Date.now() / 1000,
  } = fm;
  return {
    type: "hostMetrics", ...(machine ? { machine } : {}),
    cpu, gpu: 0.25, memUsedBytes: 8 * 1024 * 1024 * 1024, memTotalBytes: 32 * 1024 * 1024 * 1024,
    fmCalls, fmFailures, fmTotalMs, fmTextState, fmVisionState, fmDeadReason, fmCheckedAt,
  };
}

test("既定は手元の1行だけで、左端の機械名は出さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  assert.equal(rows(document).length, 1);
  assert.equal(rows(document)[0].dataset.machine, "");
  assert.equal(
    document.getElementById("host-metrics").classList.contains("hm-multi"), false,
    "手元だけのときに 'local' と書いても情報が増えない",
  );
});

test("hostMetricsMachines で機械ごとの行が増え、左端が local / <機械名> になる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2", "mac3"] });

  assert.deepEqual(machineLabels(document), ["local", "mac2", "mac3"], "手元が先・以降は機械名順");
  assert.ok(document.getElementById("host-metrics").classList.contains("hm-multi"));
  for (const row of rows(document)) {
    assert.deepEqual(
      [...row.querySelectorAll(".host-metric")].map((m) => m.dataset.metric),
      ["mem", "cpu", "gpu", "fm"], "どの行も MEM/CPU/GPU/FM の4系列を持つ",
    );
  }
  assert.equal(document.querySelectorAll("#hm-cpu").length, 1, "複製した行に id を残さない");
});

// 占有(dispatch.lock)の錠前。**行より先に届く** —— ランナー機の子は最初のサイクルで占有を
// 出すので、行を作る hostMetricsMachines より前に来る(実行中にモニターを開いた形)。
// 捨てると「配信は止まっているのに理由が画面のどこにも無い」になる。
test("占有の錠前は行より先に届いても出る(行の生成時に貼る)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "machineLock", machine: "mac2", held: true, issuer: "bob", mine: false });
  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });

  const chip = rowFor(document, "mac2").querySelector(".hm-lock");
  assert.ok(chip.classList.contains("hm-lock-on"), "行ができた時点で錠前が点く");
  // 説明はタイルと同じ自前ツールチップ(hoverTip.js)。ネイティブ title は遅延が約1秒で
  // 指定できず、小さい的では「乗せても何も出ない」に見える
  assert.match(chip.getAttribute("data-hover-tip"), /bob/, "誰の run かはツールチップに出す");
  assert.equal(chip.title, "", "ネイティブ title は残さない(二重に出る)");
  assert.equal(
    rowFor(document, "").querySelector(".hm-lock").classList.contains("hm-lock-on"), false,
    "手元の行には出さない",
  );

  send(window, { type: "machineLock", machine: "mac2", held: false, mine: false });
  assert.equal(chip.classList.contains("hm-lock-on"), false, "空きは無印");
  assert.equal(chip.getAttribute("data-hover-tip"), null, "空きの錠前に説明を残さない");
});

// **錠前は行の幅を動かさない** —— 出る行にだけ要素を足すと、その行だけ MEM/CPU/… が右へずれる
// (2026-08-31 の実害)。枠は全行に常にあり、切り替えるのは可視性だけ
test("錠前が出ても行ごとの列がずれない(枠は全行に常にある)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2", "mac3"] });
  const slots = rows(document).map((row) => row.querySelectorAll(".hm-lock").length);
  assert.deepEqual(slots, [1, 1, 1], "どの行にも錠前の枠が1つある(手元の行も含む)");

  send(window, { type: "machineLock", machine: "mac2", held: true, issuer: "bob", mine: false });
  // 要素の増減で列がずれないこと = 錠前の有無に関わらず、各行の子要素の並びが同じであること
  const shapes = rows(document).map((row) =>
    [...row.children].map((child) => child.className.split(" ")[0]).join(","));
  assert.equal(new Set(shapes).size, 1, `行の構造が揃っていない: ${JSON.stringify(shapes)}`);
});

test("サンプルは machine の行にだけ積み、描くのは手元の tick で全行まとめて", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  send(window, hostMetricsSample("mac2", 0.9));

  assert.deepEqual(
    values(rowFor(document, "mac2")), ["–", "–", "–", "–"],
    "リモートのサンプルは保持するだけ(行ごとにばらばらの瞬間で書き換えない)",
  );
  assert.deepEqual(values(rowFor(document, "")), ["–", "–", "–", "–"], "手元の行も動かない");

  send(window, hostMetricsSample(undefined, 0.1));
  assert.deepEqual(values(rowFor(document, "")), ["25%", "10%", "25%", "0"], "machine 欄が無ければ手元");
  assert.deepEqual(
    values(rowFor(document, "mac2")), ["25%", "90%", "25%", "0"],
    "リモートは手元と同じ tick で、保持していた最新値で描かれる",
  );
});

test("同じ tick までに複数届いたら最後の1つだけを使う", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  send(window, hostMetricsSample("mac2", 0.9));
  send(window, hostMetricsSample("mac2", 0.4));
  send(window, hostMetricsSample(undefined, 0.1));

  assert.deepEqual(values(rowFor(document, "mac2")), ["25%", "40%", "25%", "0"]);
});

test("サンプルの無い tick は直近の値を使い回し、途絶えたら欠測にする", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  send(window, hostMetricsSample("mac2", 0.9));
  send(window, hostMetricsSample(undefined, 0.1));

  const cpuOf = (machine) => values(rowFor(document, machine))[1];
  send(window, hostMetricsSample(undefined, 0.1));
  assert.equal(cpuOf("mac2"), "90%", "位相のずれで1 tick 落ちても穴にしない");
  send(window, hostMetricsSample(undefined, 0.1));
  assert.equal(cpuOf("mac2"), "90%");
  send(window, hostMetricsSample(undefined, 0.1));
  assert.equal(cpuOf("mac2"), "–", "観測が途絶えた行に古い値を出し続けない");
});

test("手元が黙ったらリモートが刻みを引き取り、手元が戻れば手元へ返す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  // 手元の host-metrics 子が落ちて自動再起動の猶予(5s)も過ぎた状況を作る
  const advance = (ms) => {
    const now = window.Date.now();
    window.Date.now = () => now + ms;
  };

  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  send(window, hostMetricsSample("mac2", 0.9));
  assert.deepEqual(values(rowFor(document, "mac2")), ["–", "–", "–", "–"], "猶予の内は手元を待つ");

  advance(6000);
  send(window, hostMetricsSample("mac2", 0.8));
  assert.deepEqual(values(rowFor(document, "mac2")), ["25%", "80%", "25%", "0"], "無音が続けば委譲");

  send(window, hostMetricsSample(undefined, 0.1));
  assert.deepEqual(values(rowFor(document, "")), ["25%", "10%", "25%", "0"]);
  send(window, hostMetricsSample("mac2", 0.5));
  assert.equal(
    values(rowFor(document, "mac2"))[1], "80%",
    "手元が戻ったらリモートは刻まない(保持だけ)",
  );
});

test("サンプル先着で作られた行も並びは機械名順(webview 再読込直後の経路)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  // hostMetricsMachines より先にサンプルが届く順序(再読込直後・行の集合が変わる前)
  send(window, hostMetricsSample("mac3", 0.2));
  send(window, hostMetricsSample("mac2", 0.3));

  assert.deepEqual(machineLabels(document), ["local", "mac2", "mac3"]);
});

test("機械が消えたら行も消える(古い値を出し続けない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2", "mac3"] });
  send(window, hostMetricsSample("mac2", 0.9));
  send(window, { type: "hostMetricsMachines", machines: ["mac3"] });

  assert.deepEqual(machineLabels(document), ["local", "mac3"]);
  assert.equal(rowFor(document, "mac2"), null);

  send(window, { type: "hostMetricsMachines", machines: [] });
  assert.equal(rows(document).length, 1);
  assert.equal(document.getElementById("host-metrics").classList.contains("hm-multi"), false);
});

// ラベルは**直近 1 tick の呼び出し回数そのもの**(移動平均ではない)。スパークラインが描くのも
// tick ごとの回数なので、線と数字の単位が揃う
test("FM のラベルは直近 tick の呼び出し回数", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  const fmOf = (machine) => values(rowFor(document, machine)).at(-1);
  for (const c of [1, 0, 0, 0, 1, 0, 0, 1, 0, 3]) {
    send(window, hostMetricsSample("mac2", 0.9, { fmCalls: c }));
    send(window, hostMetricsSample(undefined, 0.1)); // 手元の tick で commit させる
  }

  assert.equal(fmOf("mac2"), "3", "最後の tick が3件なら 3(窓の平均 0.6 ではない)");

  send(window, hostMetricsSample("mac2", 0.9, { fmCalls: 0 }));
  send(window, hostMetricsSample(undefined, 0.1));
  assert.equal(fmOf("mac2"), "0", "次の tick が0件なら即 0(平均のように尾を引かない)");

  // 窓の集計はツールチップに残る(ラベルが tick 単位になっても捨てない)。
  // この時点の窓は末尾10 tick = [0,0,0,1,0,0,1,0,3,0] で合計5(先頭の1は窓から出た)
  assert.match(fmTitle(document, "mac2"), /5回|5 calls/, "直近10 tick の合計はツールチップ");
});

// 分母は「観測できた tick 数」。欠測を分母に入れると取りこぼしのたびにレートが静かに小さく出る。
test("欠測 tick は分母に数えない(観測できた tick だけで平均する)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  const fmOf = (machine) => values(rowFor(document, machine)).at(-1);
  // 10 tick のうち5つが欠測、残り5つは各1件 = 観測できた範囲では 1.0/s。
  // 窓長(10)で割ると 0.5/s になり、欠測を「0件」として混ぜたことになる
  for (let i = 0; i < 10; i += 1) {
    const fm = i % 2 === 0 ? { fmCalls: null, fmFailures: null, fmTotalMs: null } : { fmCalls: 1 };
    send(window, hostMetricsSample("mac2", 0.9, fm));
    send(window, hostMetricsSample(undefined, 0.1));
  }

  assert.match(fmTitle(document, "mac2"), /FM 1\.0回\/秒|FM 1\.0\/s/,
    "観測できた5 tick で5件 = 1.0/s(欠測は分母に入れない。窓長10で割ると 0.5 になる)");
});

test("移動窓は古い tick を落とす(実行が終われば下がる)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  const fmOf = (machine) => values(rowFor(document, machine)).at(-1);
  const push = (calls, times) => {
    for (let i = 0; i < times; i += 1) {
      send(window, hostMetricsSample("mac2", 0.9, { fmCalls: calls }));
      send(window, hostMetricsSample(undefined, 0.1));
    }
  };

  push(1, 10);
  assert.match(fmTitle(document, "mac2"), /FM 1\.0回\/秒|FM 1\.0\/s/);
  // 窓が古い tick を落とさないと 10件/20 tick = 0.5/s に居座り、run が終わっても下がらない
  push(0, 10);
  assert.match(fmTitle(document, "mac2"), /FM 0\.0回\/秒|FM 0\.0\/s/,
    "窓から出た呼び出しは残らない");
  assert.equal(fmOf("mac2"), "0", "ラベルも0件");
});

test("fmCalls が null は欠測(–)、0 は 0(不明と0件を混ぜない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  const fmOf = (machine) => values(rowFor(document, machine)).at(-1);

  for (let i = 0; i < 3; i++) {
    send(window, hostMetricsSample("mac2", 0.9, { fmCalls: null }));
    send(window, hostMetricsSample(undefined, 0.1));
  }
  assert.equal(fmOf("mac2"), "–", "直近 tick が不明(控えを読めない)なら欠測表示");

  for (let i = 0; i < 3; i++) {
    send(window, hostMetricsSample("mac2", 0.9, { fmCalls: 0 }));
    send(window, hostMetricsSample(undefined, 0.1));
  }
  assert.equal(fmOf("mac2"), "0", "既知の0件(呼び出しが無かった)は欠測と区別する");
});

test("FM は機械ごとの行に正しく振り分けられる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "hostMetricsMachines", machines: ["mac2", "mac3"] });
  const fmOf = (machine) => values(rowFor(document, machine)).at(-1);

  for (let i = 0; i < 5; i++) {
    send(window, hostMetricsSample("mac2", 0.9, { fmCalls: 1 }));
    send(window, hostMetricsSample("mac3", 0.9, { fmCalls: 0 }));
    send(window, hostMetricsSample(undefined, 0.1, { fmCalls: 0 }));
  }

  assert.equal(fmOf("mac2"), "1", "mac2 は毎tick1件");
  assert.equal(fmOf("mac3"), "0", "mac3 は呼んでいない機械の行を混ぜない");
  assert.equal(fmOf(""), "0", "手元も別に集計される");
});

test("窓内に失敗が混ざると warn(⚠)、全て失敗すると dead(値は '–')の表示になる", (t) => {
  {
    const { window, document } = createWebview();
    t.after(() => window.close());
    send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
    send(window, hostMetricsSample("mac2", 0.9, { fmCalls: 3, fmFailures: 1, fmTotalMs: 300 }));
    send(window, hostMetricsSample(undefined, 0.1));

    const entry = rowFor(document, "mac2").querySelector('.host-metric[data-metric="fm"]');
    assert.ok(entry.classList.contains("hm-fm-warn"), "一部失敗は warn");
    assert.equal(entry.classList.contains("hm-fm-dead"), false);
    assert.match(values(rowFor(document, "mac2")).at(-1), /^⚠/);
  }
  {
    const { window, document } = createWebview();
    t.after(() => window.close());
    send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
    // 窓内で観測された呼び出しが2件、うち2件とも失敗 = FMHealth.Snapshot.allFailed 相当
    send(window, hostMetricsSample("mac2", 0.9, { fmCalls: 2, fmFailures: 2, fmTotalMs: 200 }));
    send(window, hostMetricsSample(undefined, 0.1));

    const entry = rowFor(document, "mac2").querySelector('.host-metric[data-metric="fm"]');
    assert.ok(entry.classList.contains("hm-fm-dead"), "窓内が全滅なら dead");
    // 死んでいる間の回数には意味が無いので出さない(死はグレーの線とツールチップが言う)
    assert.equal(values(rowFor(document, "mac2")).at(-1), "–");
  }
});

// **この行の穴**だった: 回数の窓だけで死を判定すると、誰も FM を使っていない間(fmCalls:0)は
// 何も出ない —— 「使われていない」と「死んでいる」が同じ絵になる。台帳(FMLiveness)由来の
// 死活は呼び出し0件でも出る。
test("呼び出しが0件でも、台帳が死と言えば dead になり理由が出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  send(window, hostMetricsSample("mac2", 0.9, {
    fmCalls: 0, fmVisionState: "dead", fmTextState: "alive",
    fmDeadReason: "vision: ModelManagerError(1001)",
  }));
  send(window, hostMetricsSample(undefined, 0.1));

  const entry = rowFor(document, "mac2").querySelector('.host-metric[data-metric="fm"]');
  assert.ok(entry.classList.contains("hm-fm-dead"), "呼び出し0件でも台帳の死は dead");
  assert.equal(values(rowFor(document, "mac2")).at(-1), "–", "回数(0)は出さない");
  const title = fmTitle(document, "mac2");
  assert.match(title, /vision/, "どの経路が死んだかを名指しする");
  assert.match(title, /ModelManagerError\(1001\)/, "理由を出す");
});

test("台帳が生きていると言っているだけの行には印を付けない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  send(window, hostMetricsSample("mac2", 0.9, { fmTextState: "alive", fmVisionState: "alive" }));
  send(window, hostMetricsSample(undefined, 0.1));

  const entry = rowFor(document, "mac2").querySelector('.host-metric[data-metric="fm"]');
  assert.equal(entry.classList.contains("hm-fm-dead"), false);
  assert.equal(entry.classList.contains("hm-fm-warn"), false);
  assert.equal(values(rowFor(document, "mac2")).at(-1), "0");
});

// 観測が途絶えた行(欠測)は**不明へ戻す**。古い「死んでいる」を出し続けると、直った後も
// ✕ が残って読み手が信じなくなる(不明と死を混ぜない、の表示側)
test("行が欠測になったら台帳の死活も落とす", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });
  send(window, hostMetricsSample("mac2", 0.9, { fmTextState: "dead", fmDeadReason: "text: boom" }));
  send(window, hostMetricsSample(undefined, 0.1));
  assert.ok(rowFor(document, "mac2").querySelector('[data-metric="fm"]').classList.contains("hm-fm-dead"));

  // mac2 のサンプルを止め、手元の tick だけ進める(HM_STALE_TICKS を超えると欠測)
  for (let i = 0; i < 4; i += 1) {
    send(window, hostMetricsSample(undefined, 0.1));
  }
  assert.equal(
    rowFor(document, "mac2").querySelector('[data-metric="fm"]').classList.contains("hm-fm-dead"),
    false,
    "観測が途絶えたら不明へ戻す",
  );
});

/** strokeStyle を canvas ごとに記録する 2D(色だけを見るテスト用)。 */
function recordStrokeStyles(window) {
  window.HTMLCanvasElement.prototype.getContext = function getContext() {
    const canvas = this;
    canvas.__strokes = [];
    const noop = () => {};
    const ctx = {
      setTransform: noop, clearRect: noop, beginPath: noop, closePath: noop,
      moveTo: noop, lineTo: noop, fill: noop,
      stroke: () => canvas.__strokes.push(ctx.strokeStyle),
      globalAlpha: 1, fillStyle: "", strokeStyle: "", lineWidth: 0, lineJoin: "", lineCap: "",
    };
    return ctx;
  };
}

/** その行の FM スパークラインに最後に使われた線の色。 */
function fmStroke(document, machine) {
  const canvas = rowFor(document, machine).querySelector('[data-metric="fm"] .hm-canvas');
  return (canvas.__strokes ?? []).at(-1);
}

// **色相を持たない**のが要件(ユーザー決定 2026-09-03)。赤(cpu と同色)で描いていた頃は
// 「異常な値が出ている」に見えたが、死んでいる間の回数は 0 で張り付くだけで値に意味が無い。
// R=G=B ではなく「他系列のどれとも違い、彩度が低い」ことで確かめる —— 具体的な hex を
// 貼ると、パレットを1段動かしただけでこのテストが落ちて意図が伝わらない
test("FM が死んでいる間はスパークラインの色相を落とす(生きている間の色とは別)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  recordStrokeStyles(window);
  send(window, { type: "hostMetricsMachines", machines: ["mac2"] });

  // 生きている(台帳 alive・失敗なし)ときの色
  for (let i = 0; i < 3; i += 1) {
    send(window, hostMetricsSample("mac2", 0.9, { fmCalls: 2, fmTextState: "alive" }));
    send(window, hostMetricsSample(undefined, 0.1));
  }
  const alive = fmStroke(document, "mac2");

  send(window, hostMetricsSample("mac2", 0.9, { fmCalls: 0, fmTextState: "dead", fmDeadReason: "text: boom" }));
  send(window, hostMetricsSample(undefined, 0.1));
  const dead = fmStroke(document, "mac2");

  assert.notEqual(dead, alive, "死んだら色が変わる");
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(dead.slice(i, i + 2), 16));
  const chroma = Math.max(r, g, b) - Math.min(r, g, b);
  assert.ok(chroma <= 24, `死の色は彩度を持たない(chroma=${chroma}, ${dead})`);
});

/** lineTo の Y を canvas ごとに記録する 2D。**縦軸そのものは公開されていない**ので、
 *  描かれた高さの比から間接的に読む(高さ = 22 - y)。 */
function recordCanvas(window) {
  window.HTMLCanvasElement.prototype.getContext = function getContext() {
    const canvas = this;
    canvas.__ys = [];
    const noop = () => {};
    return {
      setTransform: noop, clearRect: noop, beginPath: noop, closePath: noop,
      stroke: noop, fill: noop,
      moveTo: (x, y) => canvas.__ys.push(y),
      lineTo: (x, y) => canvas.__ys.push(y),
      globalAlpha: 1, fillStyle: "", strokeStyle: "", lineWidth: 0, lineJoin: "", lineCap: "",
    };
  };
}

// FM の縦軸は**全行で1つ**。行ごとに取ると「2回の機械」と「8回の機械」が同じ高さに描かれ、
// 並べて比べるという FM 行の目的が消える。描かれた高さの比が値の比と一致することで確かめる
// (行ごとのスケールなら 8/max(5,8)=1.00 と 2/max(5,2)=0.40 で比は 2.5 にしかならない)。
test("FM の縦軸は全行で共有される(行ごとに伸縮しない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  recordCanvas(window);

  send(window, { type: "hostMetricsMachines", machines: ["mac2", "mac3"] });
  for (let i = 0; i < 4; i += 1) {
    send(window, hostMetricsSample("mac2", 0.5, { fmCalls: 8 }));
    send(window, hostMetricsSample("mac3", 0.5, { fmCalls: 2 }));
    send(window, hostMetricsSample(undefined, 0.5, { fmCalls: 0 }));
  }

  const peakHeight = (machine) => {
    const canvas = rowFor(document, machine).querySelector('[data-metric="fm"] .hm-canvas');
    return 22 - Math.min(...canvas.__ys);   // y が小さいほど高い
  };

  const high = peakHeight("mac2");
  const low = peakHeight("mac3");
  assert.ok(high > 0 && low > 0, "両方とも描かれていること");
  assert.ok(Math.abs(high / low - 4) < 0.01,
    `高さの比は値の比(8:2=4)になるはず。実際 ${(high / low).toFixed(2)}(行ごとなら約2.5)`);
});

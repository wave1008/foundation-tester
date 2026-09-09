// 「シナリオ別サマリ」の見出し(monitorHtml.ts)とセル(render.js)は**位置で対応する**契約。
// 片方だけ並べ替えると値が別の見出しの下に出るが、**描画もテストも通る**(型も見ない)ので、
// 期待する順序をここ1箇所に置いて両側を突き合わせる。列を増減したら EXPECTED を直す。
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();

/** [i18n キー, そのセルが読むフィールド式の一部] の順序 */
const EXPECTED = [
  ["colScenarioId", "row.scenarioID"],
  ["colLastResult", "row.lastPassed"],
  ["colLastRun", "row.lastRunAt"],
  ["colRuns", "row.runs"],
  ["colSuccessRate", "row.successRate"],
  ["colAvgSec", "row.avgDurationMs"],
];

function headerKeys() {
  const html = readFileSync(path.join(ROOT, "src/monitorHtml.ts"), "utf8");
  // #table-summary の thead の <tr> 1行
  const table = html.slice(html.indexOf('id="table-summary"'));
  const row = table.slice(table.indexOf("<tr>"), table.indexOf("</tr>"));
  return [...row.matchAll(/exploreHeal\.dashboard\.(\w+)/g)].map((m) => m[1]);
}

function cellFields() {
  const js = readFileSync(path.join(ROOT, "src/webview/dashboard/render.js"), "utf8");
  const fn = js.slice(js.indexOf("export function renderSummaryTable"));
  const append = fn.slice(fn.indexOf("tr.append("), fn.indexOf("body.appendChild"));
  return EXPECTED.map(([, field]) => ({ field, at: append.indexOf(field) }))
    .filter((e) => e.at >= 0)
    .sort((a, b) => a.at - b.at)
    .map((e) => e.field);
}

test("シナリオ別サマリの見出しの並びが期待どおり", () => {
  assert.deepEqual(headerKeys(), EXPECTED.map(([key]) => key));
});

test("シナリオ別サマリのセルの並びが見出しと一致する", () => {
  assert.deepEqual(cellFields(), EXPECTED.map(([, field]) => field),
    "render.js のセル順が monitorHtml.ts の見出し順とズレています(値が別の列に出ます)");
});

// 寄せはセルの class と見出しの class の**対**で決まる(CSS は .dash-table th.mid, td.mid)。
// 片方だけ付けると見出しと値の寄せが食い違う(描画は通る)
test("最終結果は見出しもセルも中央寄せ(mid)の対になっている", () => {
  const html = readFileSync(path.join(ROOT, "src/monitorHtml.ts"), "utf8");
  const table = html.slice(html.indexOf('id="table-summary"'));
  const row = table.slice(table.indexOf("<tr>"), table.indexOf("</tr>"));
  const lastResultTh = row.split("<th").find((th) => th.includes("colLastResult"));
  assert.ok(lastResultTh.includes('class="mid"'), "最終結果の見出しに class=\"mid\" が無い");

  const js = readFileSync(path.join(ROOT, "src/webview/dashboard/render.js"), "utf8");
  const fn = js.slice(js.indexOf("export function renderSummaryTable"));
  const append = fn.slice(fn.indexOf("tr.append("), fn.indexOf("body.appendChild"));
  const cell = append.split("\n").find((line) => line.includes("row.lastPassed"));
  assert.match(cell, /tdMid\(/, "最終結果のセルが tdMid ではない");

  const css = readFileSync(path.join(ROOT, "src/webview/dashboard/style.css"), "utf8");
  assert.match(css, /\.dash-table th\.mid, \.dash-table td\.mid \{\s*text-align: center;/,
    "mid の中央寄せ規則が style.css に無い");
});

// ライブ操作タブの「操作記録」が「時刻 / 操作 / MCP のコマンド」の3列で、MCP 列はクリックでコピー
// (copyText)することの DOM E2E(jsdom)。harness は webviewLivePlaceholderStretch.test.mjs と同型。
//
// ユーザー指示(2026-09-24): 操作記録を2カラムにし、右側に同じ操作を MCP で撃つコマンドを出す。
// 文字列は host(mcpCommandForServeCommand)が作り、webview は表示とコピーだけ。テスト実行由来の行
// (injectTestStep)には MCP が無いので、列だけ揃えて空にする。

import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);
let panelHtml, webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")], bundle: true, platform: "node",
    format: "cjs", target: "node18", write: false, external: ["vscode"], logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(
    mod, mod.exports, (id) => (id === "vscode" ? vscodeStub : require2(id)));
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" }, { path: "" });
  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")], bundle: true, platform: "browser",
    format: "iife", target: "es2022", write: false, logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

function createWebview(initialState) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const posted = [];
  let state = initialState;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message), setState: (next) => { state = next; }, getState: () => state,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  // PointerEvent / setPointerCapture は jsdom に無い(webviewFleetMarquee.test.mjs と同じシム)
  window.Element.prototype.setPointerCapture = () => {};
  window.Element.prototype.releasePointerCapture = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted, getState: () => state };
}

function pointerEvent(window, type, x, pointerId = 1) {
  const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: 0, button: 0 });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}

function post(window, message) {
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "live", message } }));
}

function rows(document) {
  return [...document.querySelectorAll("#live-oplog-list .oplog-row")];
}

test("操作記録の行は 時刻 / 操作 / MCP の3列で、MCP 列に host のコマンドを出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "operationLog", label: "タップ: Go", ok: true, mcp: 'ft_tap {"x":120,"y":210}' });
  const [row] = rows(document);
  assert.ok(row, "前提: 行がある");
  assert.deepEqual([...row.children].map((el) => el.className), ["oplog-time", "oplog-label", "oplog-mcp"]);
  assert.equal(row.querySelector(".oplog-label").textContent, "タップ: Go");
  assert.equal(row.querySelector(".oplog-mcp").textContent, 'ft_tap {"x":120,"y":210}');
});

test("失敗した操作にも MCP 列を出し、テスト実行由来(mcp 無し)の行は MCP 列を空にする(列は揃える)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "operationLog", label: "入力: abc", ok: false, mcp: 'ft_type {"text":"abc"}' });
  post(window, { type: "operationLog", label: "タップ: 送信", ok: true });
  const [failed, fromRun] = rows(document);
  assert.ok(failed.classList.contains("failed"));
  assert.equal(failed.querySelector(".oplog-mcp").textContent, 'ft_type {"text":"abc"}');
  assert.equal(fromRun.children.length, 3, "列数は同じ");
  assert.equal(fromRun.querySelector(".oplog-mcp").textContent, "", "MCP が無い行は空");
});

test("MCP 列をクリックすると copyText でコピーする", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());

  post(window, { type: "operationLog", label: "ホーム", ok: true, mcp: 'ft_navigate {"target":"home"}' });
  rows(document)[0].querySelector(".oplog-mcp").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const copied = JSON.parse(JSON.stringify(posted.filter((m) => m.type === "copyText")));
  assert.deepEqual(copied, [{ type: "copyText", text: 'ft_navigate {"target":"home"}' }]);
});

// ---- 左右スクロールと列幅のドラッグ(ユーザー指示 2026-09-24: 右列が右端で途切れる) ----

test("一覧は左右にもスクロールし、MCP 列は省略しない(CSS)", () => {
  const css = fs.readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");
  const list = css.slice(css.indexOf("#panel-live .oplog-list {"), css.indexOf("}", css.indexOf("#panel-live .oplog-list {")));
  assert.match(list, /overflow: auto;/, "一覧は両方向にスクロールすること");
  const row = css.slice(css.indexOf("#panel-live .oplog-row,\n#panel-live .oplog-head {"));
  const rowBlock = row.slice(0, row.indexOf("}"));
  assert.match(rowBlock, /grid-template-columns: 8ch var\(--oplog-label-width\) max-content;/,
    "操作列は変数の幅・MCP 列は中身の幅(省略しない)");
  assert.match(rowBlock, /width: max-content;\s*min-width: 100%;/, "行の幅は中身で決まり、はみ出したぶんがスクロールになる");
  assert.doesNotMatch(css.slice(css.indexOf("#panel-live .oplog-row .oplog-mcp {")).slice(0, 120), /text-overflow/,
    "MCP 列を省略しないこと");
});

test("見出し行は一覧の中に1本あり、クリアしても消えない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const head = () => document.querySelectorAll("#live-oplog-list .oplog-head");
  assert.equal(head().length, 1, "前提: 見出し行がある");
  assert.deepEqual([...head()[0].children].map((el) => el.className), ["oplog-time", "oplog-label", "oplog-mcp"]);
  assert.ok(head()[0].querySelector(".oplog-col-resizer"), "操作列の境目にドラッグの取っ手がある");

  post(window, { type: "operationLog", label: "ホーム", ok: true, mcp: 'ft_navigate {"target":"home"}' });
  document.getElementById("live-btn-oplog-clear").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(rows(document).length, 0, "行は消える");
  assert.equal(head().length, 1, "見出し行は残る");
});

test("操作列の幅は見出しの境目のドラッグで変わり、setState に永続化される", (t) => {
  const { window, document, getState } = createWebview();
  t.after(() => window.close());
  const list = document.getElementById("live-oplog-list");
  const resizer = list.querySelector(".oplog-col-resizer");
  assert.equal(list.style.getPropertyValue("--oplog-label-width"), "220px", "前提: 既定の幅");

  resizer.dispatchEvent(pointerEvent(window, "pointerdown", 100));
  resizer.dispatchEvent(pointerEvent(window, "pointermove", 160));
  assert.equal(list.style.getPropertyValue("--oplog-label-width"), "280px", "ドラッグ中に追従すること");
  resizer.dispatchEvent(pointerEvent(window, "pointerup", 160));
  assert.equal(getState().liveOplogLabelWidth, 280, "離した時点で永続化すること");

  // 潰し切らない(下限 60px)
  resizer.dispatchEvent(pointerEvent(window, "pointerdown", 100));
  resizer.dispatchEvent(pointerEvent(window, "pointermove", -900));
  assert.equal(list.style.getPropertyValue("--oplog-label-width"), "60px");
  resizer.dispatchEvent(pointerEvent(window, "pointerup", -900));
});

test("永続化した操作列の幅は次に開いたときに戻る", (t) => {
  const { window, document } = createWebview({ liveOplogLabelWidth: 333 });
  t.after(() => window.close());
  assert.equal(document.getElementById("live-oplog-list").style.getPropertyValue("--oplog-label-width"), "333px");
});

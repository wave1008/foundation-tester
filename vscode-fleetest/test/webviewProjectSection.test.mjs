// プロファイルタブ先頭「プロジェクト」セクション(#project-section)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewProjectSelect.test.mjs(デバイスタブの #project-select)と
// 同じ。こちらはプロファイルタブの #project-section-select + 追加/コピー/削除/名前変更ボタンを見る。
//
// 検証対象:
// - profileInfo の projects/project で一覧と選択が入る(0件時は static 表示に切り替わる)
// - [+]は常に有効、コピー/削除/名前変更は一覧0件で無効
// - 各ボタンで projectAdd/projectCopy/projectDelete/projectRename を送る
// - select の変更で selectProject を送る(デバイスタブの project-select と同じメッセージ)

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

function createWebview() {
  const posted = [];
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

function sendProfileInfo(window, overrides) {
  window.dispatchEvent(
    new window.MessageEvent("message", {
      data: {
        type: "profileInfo",
        projects: ["E2E-Android", "E2E-CMP"],
        profiles: [],
        current: "",
        filter: "all",
        apps: [],
        project: "E2E-CMP",
        projectDir: "TestProjects/E2E-CMP",
        ...overrides,
      },
    }),
  );
}

test("profileInfo の projects/project で一覧と選択が入る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendProfileInfo(window);

  const select = document.getElementById("project-section-select");
  assert.deepEqual([...select.options].map((o) => o.value), ["E2E-Android", "E2E-CMP"]);
  assert.equal(select.value, "E2E-CMP");
  assert.equal(select.style.display, "");
  assert.equal(document.getElementById("project-name-static").style.display, "none");
});

test("プロジェクトディレクトリは参照のみで、解決できないときは行ごと隠す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendProfileInfo(window);
  const row = document.getElementById("project-directory-row");
  const value = document.getElementById("project-directory");
  assert.equal(row.style.display, "");
  assert.equal(value.textContent, "TestProjects/E2E-CMP");
  // ellipsis で切れるので全体はホバーで読む
  assert.equal(value.title, "TestProjects/E2E-CMP");
  assert.equal(value.tagName, "SPAN", "入力欄ではない(参照のみ)");

  sendProfileInfo(window, { project: "", projectDir: "" });
  assert.equal(row.style.display, "none");
});

test("0件では select を隠し static 表示に切り替える", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendProfileInfo(window, { projects: [], project: "" });

  assert.equal(document.getElementById("project-section-select").style.display, "none");
  const staticSpan = document.getElementById("project-name-static");
  assert.equal(staticSpan.style.display, "");
  assert.notEqual(staticSpan.textContent, "");
});

test("[+]は常に有効、コピー/削除/名前変更は一覧0件で無効", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendProfileInfo(window, { projects: [], project: "" });
  assert.equal(document.getElementById("btn-project-add").disabled, false);
  assert.equal(document.getElementById("btn-project-copy").disabled, true);
  assert.equal(document.getElementById("btn-project-remove").disabled, true);
  assert.equal(document.getElementById("btn-project-rename").disabled, true);

  sendProfileInfo(window);
  assert.equal(document.getElementById("btn-project-add").disabled, false);
  assert.equal(document.getElementById("btn-project-copy").disabled, false);
  assert.equal(document.getElementById("btn-project-remove").disabled, false);
  assert.equal(document.getElementById("btn-project-rename").disabled, false);
});

test("未解決(project 空)では置き札を出しコピー/削除/名前変更を無効にする", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  // 候補は複数あるがどれとも決まっていない状態(resolveProjectName の ambiguous)。
  // 有効にすると押しても対象が無く無言で何も起きない
  sendProfileInfo(window, { project: "" });

  const select = document.getElementById("project-section-select");
  assert.equal(select.value, "");
  assert.equal(select.options[0].disabled, true, "先頭は選べない置き札");
  assert.equal(document.getElementById("btn-project-add").disabled, false);
  assert.equal(document.getElementById("btn-project-copy").disabled, true);
  assert.equal(document.getElementById("btn-project-remove").disabled, true);
  assert.equal(document.getElementById("btn-project-rename").disabled, true);
});

test("[+]は projectAdd を送る(一覧0件でも押せる)", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window, { projects: [], project: "" });
  posted.length = 0;

  document.getElementById("btn-project-add").click();
  assert.deepEqual(
    posted.map((m) => ({ type: m.type })),
    [{ type: "projectAdd" }],
  );
});

test("コピー/削除/名前変更は現在の選択を添えて送る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  posted.length = 0;

  document.getElementById("btn-project-copy").click();
  document.getElementById("btn-project-remove").click();
  document.getElementById("btn-project-rename").click();

  assert.deepEqual(
    posted.map((m) => ({ type: m.type, project: m.project })),
    [
      { type: "projectCopy", project: "E2E-CMP" },
      { type: "projectDelete", project: "E2E-CMP" },
      { type: "projectRename", project: "E2E-CMP" },
    ],
  );
});

test("select の変更で selectProject を送る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  posted.length = 0;

  const select = document.getElementById("project-section-select");
  select.value = "E2E-Android";
  select.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.deepEqual(
    posted.map((m) => ({ type: m.type, project: m.project })),
    [{ type: "selectProject", project: "E2E-Android" }],
  );
});

// 「テスト実行」タブのツールバーにあるテストプロジェクト選択(#project-select)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewDevicesTabVisible.test.mjs と同じ。
//
// 検証対象:
// - profileInfo の projects/project で一覧と選択が入る(実行プロファイルと同じ1メッセージで届く)
// - 未解決(project:"")では選べない placeholder を先頭に置く
// - 変更で selectProject を送る(placeholder のままでは送らない)
// - 候補が無ければ disabled(押しても切り替え先が無い)

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

/** window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない */
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
        profiles: ["local"],
        current: "local",
        filter: "all",
        apps: [],
        project: "E2E-CMP",
        ...overrides,
      },
    }),
  );
}

test("profileInfo の projects で一覧と現在値が入る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendProfileInfo(window);

  const select = document.getElementById("project-select");
  assert.deepEqual([...select.options].map((o) => o.value), ["E2E-Android", "E2E-CMP"]);
  assert.equal(select.value, "E2E-CMP");
  assert.equal(select.disabled, false);
});

test("プロジェクト未解決では選べない placeholder を先頭に置く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendProfileInfo(window, { project: "" });

  const select = document.getElementById("project-select");
  assert.equal(select.value, "");
  assert.equal(select.options[0].disabled, true, "placeholder は選択肢として選べない");
  assert.deepEqual([...select.options].slice(1).map((o) => o.value), ["E2E-Android", "E2E-CMP"]);
});

test("選択の変更で selectProject を送る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  posted.length = 0;

  const select = document.getElementById("project-select");
  select.value = "E2E-Android";
  select.dispatchEvent(new window.Event("change", { bubbles: true }));

  // jsdom 側の realm で作られたオブジェクトなので、値だけを写して比べる
  assert.deepEqual(
    posted.filter((m) => m?.type === "selectProject").map((m) => ({ type: m.type, project: m.project })),
    [{ type: "selectProject", project: "E2E-Android" }],
  );
});

test("候補が無ければ disabled のまま(切り替え先が無い)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendProfileInfo(window, { projects: [], project: "" });

  assert.equal(document.getElementById("project-select").disabled, true);
});

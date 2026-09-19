// 「配信を表示する」OFF の間は全タイルと拡大表示の明度を下げる(streamToggle.js が #panel-devices に
// .stream-display-off を付け、style.css が .tile / .lane-preview-frame を暗くする)の DOM テスト。
// 守る3つ: チェックを外すと付く / 戻すと外れる / host からの復元値(showStreamDuringRun)でも同じに付く。
// 実 HTML+実バンドルを jsdom で動かす方式は webviewAndroidBridgeNotRunning.test.mjs と同じ。

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
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

const dimmed = (document) => document.getElementById("panel-devices").classList.contains("stream-display-off");

test("チェックを外すと暗くし、戻すと元に戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const checkbox = document.getElementById("chk-show-stream-during-run");
  assert.equal(dimmed(document), false, "既定 ON は暗くしない");
  checkbox.click();
  assert.equal(dimmed(document), true, "OFF は暗くする");
  checkbox.click();
  assert.equal(dimmed(document), false, "ON に戻すと元に戻す");
});

test("host からの復元値でも同じに付け外しする", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "showStreamDuringRun", value: false });
  assert.equal(dimmed(document), true);
  post(window, { type: "showStreamDuringRun", value: true });
  assert.equal(dimmed(document), false);
});

test("暗くする CSS は絵・名前・バッジに掛かり、状態の表示と実行ログのバッジには掛からない", async () => {
  const fs = await import("node:fs");
  const css = fs.readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");
  const rule = css.match(/((?:\.stream-display-off [^,{]+,\s*)*\.stream-display-off [^,{]+)\{\s*filter: brightness\(/);
  assert.ok(rule, "OFF の明度の規則がある");
  const selectors = rule[1].split(",").map((sel) => sel.trim());
  for (const target of [".frame-wrap img", ".frame-wrap canvas", ".lane-preview-media", ".tile-name",
    ".tile .badge:not(.badge-frozen):not(.badge-unregistered)",
    ".lane-preview-header .badge:not(.badge-frozen):not(.badge-unregistered)"]) {
    assert.ok(selectors.includes(`.stream-display-off ${target}`), `${target} を暗くする`);
  }
  // filter は子で打ち消せないので、状態の表示を含む容器(.tile・拡大表示の枠)には掛けない。
  // 実行ログのレーン見出しのバッジ(.lane-name・.lane-host = .badge)も暗くしない = 素の .badge を使わない
  for (const excluded of [".tile", ".lane-preview-frame", ".lane-preview-header", ".tile-state", ".frame-placeholder",
    ".badge", ".badge:not(.badge-frozen):not(.badge-unregistered)", ".lane-name", ".lane-name:not(.lane-name-neutral)",
    ".lane-host", ".lane-header"]) {
    assert.ok(!selectors.includes(`.stream-display-off ${excluded}`), `${excluded} には掛けない`);
  }
});

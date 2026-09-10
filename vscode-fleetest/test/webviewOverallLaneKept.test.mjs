// 「テスト実行」タブの全体レーン(__overall__)が workersReady で消えないことの DOM テスト。
// 実 HTML + 実バンドルを jsdom で動かす方式は webviewLanePreview.test.mjs と同じ。
//
// 背景(実害 2026-09-09): 供給フェーズの進行(「(3/8) …: starting」)は worker を持たないので
// 全体レーンに入るが、configureLanes が workersReady のワーカー集合に無いレーンを全部消して
// いたため、最初のワーカーが合流した瞬間に**丸ごと消えていた**(複数マシン実行では合流が
// 機械ごとに来るので、最後の合流で残らず消える)。ホスト側の同じ規則は runLaneModel.test.mjs。

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
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: () => {}, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function send(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function laneLines(document) {
  return [...document.querySelectorAll("#lanes-grid .lane-body .lane-line")].map((el) => el.textContent);
}

test("供給フェーズの行は workersReady のあとも残る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "runEvent", action: { type: "cleared" } });
  send(window, { type: "runEvent", action: { type: "line", laneId: "__overall__", text: "  ▶️ (3/8) Pixel 9-03: starting" } });
  assert.deepEqual(laneLines(document), ["  ▶️ (3/8) Pixel 9-03: starting"]);

  // 1機目のワーカーが合流(複数マシン実行では機械ごとに何度も来る)
  send(window, { type: "runEvent", action: { type: "lanesConfigured", lanes: [
    { id: "android:M1Max/Pixel 10-01", name: "Pixel 10-01", platform: "android", detail: "", machine: "M1Max" },
  ] } });
  assert.deepEqual(laneLines(document), ["  ▶️ (3/8) Pixel 9-03: starting"],
    "workersReady で全体レーンごと消えてはいけない");

  // 2機目の合流(累積再送)でも残る
  send(window, { type: "runEvent", action: { type: "lanesConfigured", lanes: [
    { id: "android:M1Max/Pixel 10-01", name: "Pixel 10-01", platform: "android", detail: "", machine: "M1Max" },
    { id: "android:Pixel 9-01", name: "Pixel 9-01", platform: "android", detail: "", machine: undefined },
  ] } });
  send(window, { type: "runEvent", action: { type: "line", laneId: "__overall__", text: "  ✅ (3/8) Pixel 9-03: revived" } });
  assert.deepEqual(laneLines(document).filter((l) => l.includes("(3/8)")),
    ["  ▶️ (3/8) Pixel 9-03: starting", "  ✅ (3/8) Pixel 9-03: revived"]);
});

test("新しい実行の開始(cleared)では全体レーンも消える", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "runEvent", action: { type: "line", laneId: "__overall__", text: "前の実行の行" } });
  assert.equal(laneLines(document).length, 1);
  send(window, { type: "runEvent", action: { type: "cleared" } });
  assert.deepEqual(laneLines(document), [], "前の実行の行を持ち越さない");
});

// 見出しの状況行はレーン欄の外(#lanes-run-status)なので、デバイスを選択して拡大表示に
// なっている間も見える。実害 2026-09-09: 18台選択のまま実行しており、レーン欄には
// 拡大表示だけが並ぶため供給の進行がどこにも出ていなかった。
test("status アクションは見出しの状況行に出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "runEvent", action: { type: "cleared" } });
  assert.equal(document.getElementById("lanes-run-status").textContent, "");

  send(window, { type: "runEvent", action: { type: "status", text: "▶️ (3/8) Pixel 9-03: starting" } });
  assert.equal(document.getElementById("lanes-run-status").textContent, "▶️ (3/8) Pixel 9-03: starting");

  send(window, { type: "runEvent", action: { type: "status", text: "✅ (3/8) Pixel 9-03: revived" } });
  assert.equal(document.getElementById("lanes-run-status").textContent, "✅ (3/8) Pixel 9-03: revived",
    "新しい進行で上書きする");
});

// 完了の集計(「完了: 成功 N / 失敗 M(トータル …)」)は出さない(ユーザー決定)。
// 空に戻すのは、直前の進行が完了後も残って「まだ走っている」と読まれないため
test("runFinished で見出しの状況行は空に戻り、集計は出ない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  send(window, { type: "runEvent", action: { type: "status", text: "▶️ (8/8) Pixel 9-08: starting" } });
  send(window, { type: "runEvent", action: { type: "runFinished" } });
  assert.equal(document.getElementById("lanes-run-status").textContent, "");
});

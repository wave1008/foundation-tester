// デバイスタブのツールバーにある「テスト実行」(#btn-run-tests)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewProjectSelect.test.mjs と同じ。
//
// 検証対象:
// - profileInfo が来るまでは押せない(実行プロファイルが何か分からない)
// - 押せるのは profiles に実在する名前が選ばれているときだけ(未選択・@running・
//   設定にはあるがファイルが無い名前は弾く)
// - 押すと runTests を送る
// - 「モニター再起動」の右隣に並ぶ(左のモニター操作群と切り分けるマージン付き)

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
        projects: ["E2E-CMP"],
        profiles: ["local", "fleet"],
        current: "local",
        filter: "all",
        apps: [],
        project: "E2E-CMP",
        ...overrides,
      },
    }),
  );
}

test("profileInfo が来るまでは押せない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  assert.equal(document.getElementById("btn-run-tests").disabled, true);
});

test("実在する実行プロファイルが選ばれていれば押せる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendProfileInfo(window);

  assert.equal(document.getElementById("btn-run-tests").disabled, false);
});

test("未選択・表示フィルタ・実体の無い名前では押せない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const button = document.getElementById("btn-run-tests");

  sendProfileInfo(window, { current: "" });
  assert.equal(button.disabled, true, "(プロファイルなし)");

  sendProfileInfo(window, { current: "", filter: "running" });
  assert.equal(button.disabled, true, "(起動中のデバイス)は表示フィルタで実行プロファイルではない");

  // 設定に名前はあるがファイルが無い(applyProfileInfo の unknownOption)。値の形では
  // 実在する名前と区別できないので、profiles の集合で弾けていることを見る。
  sendProfileInfo(window, { current: "deleted-one" });
  assert.equal(document.getElementById("profile-select").value, "deleted-one");
  assert.equal(button.disabled, true, "実体が無い");
});

test("選択を変えた時点で押せる/押せないが切り替わる(profileInfo の往復を待たない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  const select = document.getElementById("profile-select");
  const button = document.getElementById("btn-run-tests");

  select.value = "";
  select.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(button.disabled, true);

  select.value = "fleet";
  select.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(button.disabled, false);
});

test("押すと runTests を送る(押せないときは送らない)", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  const button = document.getElementById("btn-run-tests");

  button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.deepEqual(posted.filter((m) => m?.type === "runTests"), []);

  sendProfileInfo(window);
  button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.deepEqual(
    posted.filter((m) => m?.type === "runTests").map((m) => ({ type: m.type })),
    [{ type: "runTests" }],
  );
});

test("「モニター再起動」の右隣に置き、左のモニター操作群とはマージンで切る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const restart = document.getElementById("btn-restart");
  assert.equal(restart.nextElementSibling?.id, "btn-run-tests");
  // マージンの定義は style.css(#btn-restart / #btn-run-tests の margin-right)。バンドル済み
  // CSS は jsdom へ読み込まないので、規則が消えていないことをソースで見る。
  const css = require2("node:fs").readFileSync("src/webview/monitor/style.css", "utf8");
  assert.match(css, /#btn-run-tests \{\n\s*margin-right: 8px;/);
  assert.match(css, /#btn-restart \{\n\s*margin-right: 8px;/);
});

// モニター内タブの切替をホストへ知らせる配線(devicesTabVisible)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewHoverTip.test.mjs と同じ。
//
// 背景: デバイスタイルは他タブへ切り替えると display:none になるが、以前は webview 内で
// 閉じており、ホストの deviceStream.setVisible はパネル自体の表示/非表示でしか呼ばれなかった。
// そのため録画・プロファイル等のタブを見ている間も配信 helper と H.264 デコードが動き続けていた。
//
// 検証対象:
// - デバイス以外のタブへ切り替えると visible:false を送る
// - デバイスタブへ戻すと visible:true を送る
// - 起動時の初期タブでも 1 回送る(ホストが初期状態を知る唯一の経路)

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

function visibilityMessages(posted) {
  return posted.filter((m) => m?.type === "devicesTabVisible");
}

function clickTab(document, id) {
  document.getElementById(`tab-${id}`).dispatchEvent(
    new document.defaultView.MouseEvent("click", { bubbles: true }),
  );
}

test("起動時の初期タブでも devicesTabVisible を1回送る", (t) => {
  const { window, posted } = createWebview();
  t.after(() => window.close());

  const messages = visibilityMessages(posted);
  assert.equal(messages.length, 1, "初期 switchTab で1回だけ送る");
  // 既定の初期タブは devices
  assert.equal(messages[0].visible, true);
});

test("デバイス以外のタブへ切り替えると visible:false を送る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  posted.length = 0;

  clickTab(document, "recordings");

  const messages = visibilityMessages(posted);
  assert.equal(messages.length, 1);
  assert.equal(messages[0].visible, false,
    "タイルが display:none の間は配信 helper とデコードを止められるようにする");
});

test("デバイスタブへ戻すと visible:true を送る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  clickTab(document, "settings");
  posted.length = 0;

  clickTab(document, "devices");

  const messages = visibilityMessages(posted);
  assert.equal(messages.length, 1);
  assert.equal(messages[0].visible, true);
});

test("同じタブを再クリックしても送らない(不要な再構築を起こさない)", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  clickTab(document, "processes");
  posted.length = 0;

  clickTab(document, "processes");

  assert.equal(visibilityMessages(posted).length, 0);
});

test("切替後にデバイスパネルが実際に display:none になっている(前提の確認)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  clickTab(document, "profiles");
  assert.equal(document.getElementById("panel-devices").style.display, "none",
    "この前提が崩れるとホストを止める配線ごと不要になる");

  clickTab(document, "devices");
  assert.equal(document.getElementById("panel-devices").style.display, "flex");
});

test("設定タブ: LPT チェックボックスの操作が setLptScheduling として送られる", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("settings-lpt");
  assert.ok(checkbox, "スケジューリングセクションのチェックボックスがある");

  // 拡張からの現在値反映(既定 ON)
  window.dispatchEvent(new window.MessageEvent("message", {
    data: { type: "lptScheduling", value: true },
  }));
  assert.equal(checkbox.checked, true);

  posted.length = 0;
  checkbox.checked = false;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));

  // jsdom は別 realm なので deepEqual は参照等価性で落ちる。フィールドで比べる
  const messages = posted.filter((m) => m?.type === "setLptScheduling");
  assert.equal(messages.length, 1);
  assert.equal(messages[0].value, false);
});

test("設定タブ: LPT 実績件数は既定値でも値として入る(空欄にしない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  window.dispatchEvent(new window.MessageEvent("message", {
    data: { type: "lptHistoryRuns", value: 5, default: 5 },
  }));

  const input = document.getElementById("settings-lpt-history");
  assert.ok(input, "LPT チェックボックスの下に件数入力がある");
  assert.equal(input.value, "5", "実際に使う件数が常に見えている");
  assert.equal(input.placeholder, "5", "入力を消した一瞬の保険として既定値も出す");
});

test("設定タブ: 既定と異なる値は入力欄に表示される", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  window.dispatchEvent(new window.MessageEvent("message", {
    data: { type: "lptHistoryRuns", value: 50, default: 5 },
  }));

  const input = document.getElementById("settings-lpt-history");
  assert.equal(input.value, "50");
  assert.equal(input.placeholder, "5");
});

test("設定タブ: 件数を入れると setLptHistoryRuns が送られる", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  posted.length = 0;

  const input = document.getElementById("settings-lpt-history");
  input.value = "50";
  input.dispatchEvent(new window.Event("change", { bubbles: true }));

  const messages = posted.filter((m) => m?.type === "setLptHistoryRuns");
  assert.equal(messages.length, 1);
  assert.equal(messages[0].value, 50);
});

test("設定タブ: 空欄・不正値は null(既定へ戻す)を送り入力欄に既定値を入れ直す", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  const input = document.getElementById("settings-lpt-history");
  window.dispatchEvent(new window.MessageEvent("message", {
    data: { type: "lptHistoryRuns", value: 5, default: 5 },
  }));

  for (const raw of ["", "0", "-3", "abc", "2.5"]) {
    posted.length = 0;
    input.value = raw;
    input.dispatchEvent(new window.Event("change", { bubbles: true }));

    const messages = posted.filter((m) => m?.type === "setLptHistoryRuns");
    assert.equal(messages.length, 1, `"${raw}" で1件送る`);
    assert.equal(messages[0].value, null, `"${raw}" は既定へ戻す`);
    assert.equal(input.value, "5", `"${raw}" は入力欄に既定値を入れ直す`);
  }
});

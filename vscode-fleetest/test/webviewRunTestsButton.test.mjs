// 「テスト実行」タブのツールバーにある「テスト実行」(#btn-run-tests)の DOM テスト。
// 実 HTML+実バンドルで動かす方式は webviewProjectSelect.test.mjs と同じ。
//
// 検証対象:
// - profileInfo が来るまでは押せない(実行プロファイルが何か分からない)
// - 押せるのは profiles に実在する名前が選ばれているときだけ(未選択・@running・
//   設定にはあるがファイルが無い名前は弾く)
// - 押すと runTests を送る
// - 一括起動の最中(「デバイスの起動を中断」表示)は「全て終了」「モニター再起動」と揃って押せない
// - 一括停止(「全て終了」)の最中も select・全て起動/終了・テスト実行を触らせない
//   (モニター再起動だけは止めない)
// - 同じ間はテストプロジェクト・実行プロファイルの select も触らせない
// - テスト実行中(testRunActive)は select・一括起動/終了を畳み、ボタンが「テストを中断」になる
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

function sendBootBusy(window, busy, bulkOp) {
  window.dispatchEvent(
    new window.MessageEvent("message", { data: { type: "bootBusy", busy, bulkOp } }),
  );
}

test("一括起動の最中は「全て終了」「モニター再起動」「テスト実行」が揃って押せない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  const ids = ["btn-devices-down", "btn-restart", "btn-run-tests"];

  sendBootBusy(window, true, "up");
  assert.equal(
    document.getElementById("btn-devices-up").textContent,
    "デバイスの起動を中断",
    "この状態を「デバイスの起動を中断」表示で定義している",
  );
  assert.deepEqual(ids.map((id) => document.getElementById(id).disabled), [true, true, true]);

  // 起動が終われば(実行プロファイルは選ばれたまま)3つとも戻る
  sendBootBusy(window, false, undefined);
  assert.deepEqual(ids.map((id) => document.getElementById(id).disabled), [false, false, false]);
});

test("一括起動の最中はテストプロジェクト・実行プロファイルを変更できない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  const selects = ["project-select", "profile-select"];
  assert.deepEqual(selects.map((id) => document.getElementById(id).disabled), [false, false]);

  sendBootBusy(window, true, "up");
  assert.deepEqual(selects.map((id) => document.getElementById(id).disabled), [true, true]);

  // 起動中に profileInfo が届いても解放しない(applyProfileInfo の代入より後に効かせる)
  sendProfileInfo(window);
  assert.deepEqual(selects.map((id) => document.getElementById(id).disabled), [true, true]);

  sendBootBusy(window, false, undefined);
  assert.deepEqual(selects.map((id) => document.getElementById(id).disabled), [false, false]);
});

test("profileInfo より先に bootBusy が来ても select は触らせないまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  sendBootBusy(window, false, undefined);

  // 選択肢が1つも無い select を押せる状態にしない
  assert.equal(document.getElementById("project-select").disabled, true);
  assert.equal(document.getElementById("profile-select").disabled, true);
});

test("一括停止(「全て終了」)の最中も操作させない(モニター再起動だけは止めない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  const locked = ["project-select", "profile-select", "btn-devices-up", "btn-devices-down", "btn-run-tests"];

  sendBootBusy(window, true, "down");
  assert.deepEqual(locked.map((id) => document.getElementById(id).disabled), [true, true, true, true, true]);
  // 停止中に profileInfo が届いても select を解放しない(起動中と同じ理由)
  sendProfileInfo(window);
  assert.deepEqual(locked.map((id) => document.getElementById(id).disabled), [true, true, true, true, true]);
  assert.equal(document.getElementById("btn-restart").disabled, false, "監視の建て直しは止めない");

  sendBootBusy(window, false, undefined);
  assert.deepEqual(locked.map((id) => document.getElementById(id).disabled), [false, false, false, false, false]);
});

test("起動の最中に実行プロファイルを選び直しても「テスト実行」は押せないまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  sendBootBusy(window, true, "up");

  const select = document.getElementById("profile-select");
  select.value = "fleet";
  select.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.equal(document.getElementById("btn-run-tests").disabled, true);
});

function sendTestRunActive(window, active) {
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "testRunActive", active } }));
}

test("テスト実行中はツールバーを畳み、ボタンが「テストを中断」に変わる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  const locked = ["project-select", "profile-select", "btn-devices-up", "btn-devices-down"];
  const button = document.getElementById("btn-run-tests");

  sendTestRunActive(window, true);
  assert.deepEqual(locked.map((id) => document.getElementById(id).disabled), [true, true, true, true]);
  assert.equal(button.textContent, "テストを中断");
  assert.equal(button.classList.contains("bulk-cancel"), true, "中断は起動キューの中断と同じ色");
  assert.equal(button.disabled, false, "止める口は常に開けておく");

  // 実行中に profileInfo が届いても解放しない(applyProfileInfo の代入より後に効かせる)
  sendProfileInfo(window);
  assert.deepEqual(locked.map((id) => document.getElementById(id).disabled), [true, true, true, true]);

  sendTestRunActive(window, false);
  assert.deepEqual(locked.map((id) => document.getElementById(id).disabled), [false, false, false, false]);
  assert.equal(button.textContent, "テスト実行");
  assert.equal(button.classList.contains("bulk-cancel"), false);
});

test("実行中に押すと cancelTests を送り、受理を見せたまま再送もできる", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendProfileInfo(window);
  sendTestRunActive(window, true);
  const button = document.getElementById("btn-run-tests");

  button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(posted.filter((m) => m?.type === "cancelTests").length, 1);
  assert.equal(posted.filter((m) => m?.type === "runTests").length, 0, "実行中に走らせ直さない");
  assert.equal(button.textContent, "中断しています…");
  assert.equal(button.classList.contains("cancelling"), true);
  assert.equal(button.disabled, false);

  button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(posted.filter((m) => m?.type === "cancelTests").length, 2, "刺さったときの再送の口");

  // 実行が終われば受理表示も消える(次の実行が中断表示から始まらない)
  sendTestRunActive(window, false);
  sendTestRunActive(window, true);
  assert.equal(button.textContent, "テストを中断");
  assert.equal(button.classList.contains("cancelling"), false);
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

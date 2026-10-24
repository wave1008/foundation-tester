// ラインビュー見出しのプラットフォーム表示フィルタ(iOS / Android の独立トグル。既定は両方 ON)
// の DOM テスト。OFF の側のデバイスは**4つのセクション**(実行中・デバイス一覧・
// 選択したデバイス・実行ログ)から同時に消える —— 落とすのは deviceTiles.js の applyDevices の
// 入口1箇所で、4つともそこから作られるため。
// 契約は monitorWebviewMessages.ts の setPlatformFilter / platformFilter。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorWebviewMessages";

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
  let state;
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: (next) => { state = next; },
    getState: () => state,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** iOS 2台・Android 1台。run ボードのレーンの鍵(udid/serial)と揃えてある。 */
function sendDevices(window) {
  post(window, { type: "devices", devices: [
    { id: "ios:A", name: "iPhone-01", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "U-1", recording: false, registered: true },
    { id: "ios:B", name: "iPhone-02", platform: "ios", state: "connected", detail: "",
      kind: "virtual", udid: "U-2", recording: false, registered: true },
    { id: "and:C", name: "Pixel-01", platform: "android", state: "connected", detail: "",
      kind: "virtual", serial: "S-1", recording: false, registered: true },
  ] });
}

const tileNames = (document) => [...document.querySelectorAll("#grid .tile .tile-name")].map((el) => el.textContent);
const boardNames = (document) => [...document.querySelectorAll(".run-board-lane-name")].map((el) => el.textContent);
const logNames = (document) => [...document.querySelectorAll("#lanes-grid .lane")]
  .filter((el) => el.style.display !== "none").map((el) => el.querySelector(".lane-header").textContent);
const previewCount = (document) => [...document.querySelectorAll("#preview-grid .lane-preview")]
  .filter((el) => el.style.display !== "none").length;
// トグルは**バッジ**(ユーザー決定 2026-09-22)。ON のものだけ .selected が付く
const badge = (document, value) => document.getElementById(`rad-platform-${value}`);
const toggle = (window, document, value) => {
  badge(document, value).dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
};
const selectedBadges = (document) => ["ios", "android"]
  .filter((value) => badge(document, value).classList.contains("selected"));

test("フィルタはラインビューの見出しで「ライブ更新」のすぐ右に置かれ、「両方」は無い", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const group = badge(document, "ios").closest(".run-board-platform-filter");
  assert.equal(group.parentElement, document.getElementById("line-view-header"));
  assert.equal(
    group.previousElementSibling,
    document.getElementById("chk-show-stream-during-run").closest("label"),
    "すぐ左が「ライブ更新」",
  );
  assert.deepEqual([...group.querySelectorAll("button")].map((b) => b.dataset.value), ["ios", "android"]);
  assert.equal(document.querySelectorAll("#run-board-header .run-board-platform-filter").length, 0, "run ボードの見出しには残さない");
});

test("既定は両方 ON(フィルタを持たない状態と同じ見え方)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.deepEqual(selectedBadges(document), ["ios", "android"]);
  assert.equal(badge(document, "ios").getAttribute("aria-pressed"), "true");
  assert.equal(badge(document, "android").getAttribute("aria-pressed"), "true");
  sendDevices(window);
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"]);
});

test("OFF の側が4つのセクションから消え、監視サイクル後も隠れたまま", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, { type: "monitorRuns", observed: true, runs: [] });
  sendDevices(window);
  document.getElementById("chk-select-all").click();   // 全選択 = 実行ログと拡大表示にも出る
  assert.equal(logNames(document).length, 3, "前提: 実行ログに3台");
  assert.equal(previewCount(document), 3, "前提: 拡大表示に3台");
  assert.deepEqual(boardNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"], "前提: 実行中のツリーに3台");

  toggle(window, document, "android");   // 両方 ON → Android だけ OFF
  assert.deepEqual(selectedBadges(document), ["ios"], "iOS は ON のまま");
  assert.equal(badge(document, "android").getAttribute("aria-pressed"), "false");
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02"], "デバイス一覧");
  assert.deepEqual(boardNames(document), ["iPhone-01", "iPhone-02"], "実行中");
  assert.deepEqual(logNames(document), ["iPhone-01", "iPhone-02"], "実行ログ");
  assert.equal(previewCount(document), 2, "選択したデバイス");
  // **次の監視サイクル(約2秒ごと)が来ても隠れたまま** —— 落とすのは applyDevices の入口なので、
  // ここを通さないと隠したデバイスが次のサイクルで戻ってくる
  sendDevices(window);
  assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02"], "監視サイクル後も隠れたまま");
  assert.deepEqual(logNames(document), ["iPhone-01", "iPhone-02"], "監視サイクル後も隠れたまま(実行ログ)");
});

// 唯一 ON の側を押すと入れ替わる・両方 ON にはできる・両方 OFF にはならない(ユーザー決定 2026-10-24)。
// **次の監視サイクルを待たない** —— 切り替えたその場で描き直す(生の一覧を控えてあるため)
test("唯一 ON の側を押すと入れ替わり、両方 OFF にはならない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  const steps = [
    ["android", ["ios"], ["iPhone-01", "iPhone-02"]],                 // 両方 ON → Android OFF
    ["ios", ["android"], ["Pixel-01"]],                               // iOS だけ ON で iOS → 入れ替え
    ["android", ["ios"], ["iPhone-01", "iPhone-02"]],                 // Android だけ ON で Android → 入れ替え
    ["android", ["ios", "android"], ["iPhone-01", "iPhone-02", "Pixel-01"]], // OFF 側を押す → 両方 ON
    ["ios", ["android"], ["Pixel-01"]],                               // 両方 ON → iOS OFF
    ["ios", ["ios", "android"], ["iPhone-01", "iPhone-02", "Pixel-01"]],
  ];
  for (const [key, on, names] of steps) {
    toggle(window, document, key);
    assert.deepEqual(selectedBadges(document), on, `${key} を押した後`);
    assert.deepEqual(tileNames(document), names, `${key} を押した後`);
  }
  // webview 側の realm で作られたオブジェクトなので、値だけを取り出して比べる
  assert.deepEqual(posted.filter((m) => m?.type === "setPlatformFilter").map((m) => [m.value.ios, m.value.android]),
    [[true, false], [false, true], [true, false], [true, true], [false, true], [true, true]]);
});

test("host の復元値はバッジに入り、投げ返さない", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  post(window, { type: "platformFilter", value: { ios: false, android: true } });
  assert.deepEqual(selectedBadges(document), ["android"]);
  assert.deepEqual(tileNames(document), ["Pixel-01"]);
  assert.deepEqual(posted.filter((m) => m?.type === "setPlatformFilter"), [], "復元は送り返さない");
});

// 知らない形(古い3択の保存値・壊れた設定・両方 OFF)で**デバイスが黙って消えない**こと
test("知らない復元値は両方 ON へ倒す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window);
  for (const value of ["ios", "all", { ios: "yes", android: true }, null, { ios: false, android: false }]) {
    post(window, { type: "platformFilter", value: { ios: false, android: true } });
    post(window, { type: "platformFilter", value });
    assert.deepEqual(selectedBadges(document), ["ios", "android"], JSON.stringify(value));
    assert.deepEqual(tileNames(document), ["iPhone-01", "iPhone-02", "Pixel-01"]);
  }
});

// **jsdom は CSS を読まない**ので宣言そのものをテキストで押さえる(run ボードの CSS テストと同じ方式)
test("バッジは同じ幅で、ON の文字は白・ON はホバーで色を変えない", async () => {
  const css = readFileSync(new URL("../src/webview/monitor/style.css", import.meta.url), "utf8");
  const rule = (selector) => {
    const at = css.indexOf(`${selector} {`);
    assert.notEqual(at, -1, selector);
    return css.slice(at, css.indexOf("}", at));
  };
  const decl = rule(".platform-badge");
  assert.match(decl, /min-width:\s*8ch/, "文字数で幅が変わらないよう下限を揃える");
  assert.match(decl, /text-align:\s*center/);
  assert.match(decl, /background-color:\s*var\(--platform-badge-bg\)/);
  // 「ライブ更新」の右へ流れに沿って続く(中央の絶対位置ではない)
  assert.doesNotMatch(rule(".run-board-platform-filter"), /position:\s*absolute/);
  // 「ライブ更新」との間はバッジ1つぶん(min-width の 8ch。行の gap 6px を引く)
  assert.match(rule(".platform-badge-ios"), /margin-left:\s*calc\(8ch - 6px\)/);
  for (const platform of ["ios", "android"]) {
    const sel = rule(`.platform-badge-${platform}.selected`);
    assert.match(sel, /color:\s*#ffffff/, platform);
    assert.doesNotMatch(sel, /(^|[^-])background-color:/, "背景は変数で持つ(ホバーの固定が効くように)");
  }
  // 素の button:hover:not(:disabled)(0,2,1)に勝つ詳細度でホバー時の背景を今の色に固定する
  assert.match(rule(".platform-badge:hover:not(:disabled)"), /background-color:\s*var\(--platform-badge-bg\)/);
  // 不透明度を上げるのは OFF だけ
  assert.match(rule(".platform-badge:not(.selected):hover"), /opacity:\s*1/);
  assert.equal(css.indexOf(".platform-badge:hover {"), -1, "ON も含むホバーの装飾を置かない");
  assert.equal(css.indexOf("platform-badge-all"), -1, "「両方」の名残を置かない");
});

test("setPlatformFilter は host 側の検証を通り、知らない形と両方 OFF は弾く", () => {
  for (const value of [{ ios: true, android: true }, { ios: false, android: true }, { ios: true, android: false }]) {
    assert.equal(isMonitorFromWebviewMessage({ type: "setPlatformFilter", value }), true, JSON.stringify(value));
  }
  for (const value of ["all", "ios", "android", null, { ios: true }, { ios: 1, android: 0 }, { ios: false, android: false }]) {
    assert.equal(isMonitorFromWebviewMessage({ type: "setPlatformFilter", value }), false, JSON.stringify(value));
  }
});

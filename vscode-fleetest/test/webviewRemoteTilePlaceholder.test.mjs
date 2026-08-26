// リモートのデバイスのタイルが「未起動」と言わないことの DOM テスト。
//
// 背景(実害 2026-08-17): モニターの状態判定は simctl/adb = **手元にしか効かない**ので、
// リモートのデバイスは向こうで起動していても state が offline のまま来ていた。それを
// そのまま「未起動」と表示していたため、`api devices-up` が実際に向こうを起動しても
// 画面が1ミリも変わらず、利用者は「起動しようとしたのかどうか分からない」状態になった。
//
// 現在は**その機械の monitor を1本走らせて合流させる**(RemoteMonitorFanout)ので、届いて
// いれば本物の状態が来る。届いていない台だけが state="unknown" で、表示の規律は3つ:
//  - unknown では**断定しない**(どの機械に届いていないかを言う)
//  - 状態が届いていれば**手元の台と同じ扱い**(リモートだからという理由で別表示にしない)
//  - 操作中(deviceOpBusy)は**本物の進捗**なので従来どおり「起動中」を出す
//    (この行が消えると、リモートを起動しても無反応に見える回帰に戻る)
//
// 実 HTML+実バンドルを jsdom で動かす方式は webviewTileRelayout.test.mjs と同じ。

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
  window.acquireVsCodeApi = () => ({
    postMessage: () => {},
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

/** 手元 1 台 + M1Max 1 台(同名。(machine, name) で一意という前提そのもの) */
function sendMixedDevices(window) {
  post(window, {
    type: "devices",
    devices: [
      {
        id: "ios:Dev 1", name: "Dev 1", platform: "ios", state: "offline", kind: "virtual",
        udid: "UDID-L", recording: false,
      },
      {
        id: "ios:M1Max/Dev 1", name: "Dev 1", platform: "ios", state: "unknown", kind: "virtual",
        udid: "UDID-R", recording: false, machine: "M1Max",
      },
    ],
  });
}

function placeholderTexts(document) {
  return [...document.querySelectorAll("#grid .tile")].map(
    (tile) => tile.querySelector(".frame-placeholder")?.textContent ?? "",
  );
}

test("届いていないタイルは「未起動」ではなくホスト名と観測不能である旨を出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendMixedDevices(window);

  const [local, remote] = placeholderTexts(document);
  assert.match(local, /未起動/, "前提: 手元は従来どおり状態を断定する");
  assert.doesNotMatch(remote, /未起動/, "リモートは observable でないので断定してはいけない");
  assert.match(remote, /M1Max/, "どの機械の話かを出す");
});

test("操作中はリモートでも「起動中」を出す(無反応に見える回帰の witness)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendMixedDevices(window);

  post(window, { type: "deviceOpBusy", name: "Dev 1", machine: "M1Max", op: "up", status: "running" });

  const [local, remote] = placeholderTexts(document);
  assert.match(remote, /起動中/, "deviceStarting は本物の進捗なので出す");
  assert.match(local, /未起動/, "machine が違う手元のタイルは巻き込まれない");
});

test("状態が届いているリモートのタイルは手元の台と同じ表示になる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, {
    type: "devices",
    devices: [
      {
        id: "ios:M1Max/Dev 1", name: "Dev 1", platform: "ios", state: "offline", kind: "virtual",
        udid: "UDID-R", recording: false, machine: "M1Max",
      },
    ],
  });

  const [remote] = placeholderTexts(document);
  assert.match(remote, /未起動/, "その機械の monitor が offline と言っているなら、それが事実");
  assert.doesNotMatch(remote, /取得できません/, "届いているのに「取得できません」は嘘になる");
});

// キュー状態(deviceOpBusy)の宛先。**machine 省略は「手元」であって「どれでもよい」ではない** ——
// ワイルドカードにすると先頭のタイル(= 手元)を書き換え、「M2Ultra の台を停止」で
// 手元のタイルに「シャットダウン中」が出る(2026-08-17 の実害)。
/** 「シャットダウン中」は稼働中の台にしか出ない(offline のタイルは別の表示になる)ので、
 * この2本だけ connected の同名ペアを使う。
 * **リモートを先に置く**のは意図的 —— 「machine 省略 = どれでもよい」の実装は
 * 先頭一致で当てるので、手元を先に置くと偶然正解してしまい欠陥を検出できない。 */
function sendConnectedPair(window) {
  post(window, {
    type: "devices",
    devices: [
      {
        id: "ios:M1Max/Dev 1", name: "Dev 1", platform: "ios", state: "connected", kind: "virtual",
        udid: "UDID-R", recording: false, machine: "M1Max",
      },
      {
        id: "ios:Dev 1", name: "Dev 1", platform: "ios", state: "connected", kind: "virtual",
        udid: "UDID-L", recording: false,
      },
    ],
  });
}

/** sendConnectedPair の並び(リモート, 手元)に対応する取り出し。 */
function connectedPairTexts(document) {
  const [remote, local] = placeholderTexts(document);
  return { remote, local };
}

test("手元宛のキュー状態がリモートのタイルを書き換えない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendConnectedPair(window);

  // machine を持たない = 手元宛
  post(window, { type: "deviceOpBusy", name: "Dev 1", op: "down", status: "running" });

  const { local, remote } = connectedPairTexts(document);
  assert.match(local, /シャットダウン中/, "手元のタイルに出る");
  assert.doesNotMatch(remote, /シャットダウン中/, "リモートのタイルは巻き込まれない");
});

test("リモート宛のキュー状態が手元のタイルを書き換えない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendConnectedPair(window);

  post(window, { type: "deviceOpBusy", name: "Dev 1", machine: "M1Max", op: "down", status: "running" });

  const { local, remote } = connectedPairTexts(document);
  assert.match(remote, /シャットダウン中/, "リモートのタイルに出る");
  assert.doesNotMatch(local, /シャットダウン中/,
    "『M2Ultra の台を停止』で手元のタイルに『シャットダウン中』が出た形");
});

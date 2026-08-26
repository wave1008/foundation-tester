// webviewRemoteHostsSettings.test.mjs
// 設定タブのリモートマシン表(settingsTab.js)が送る setRemoteConfig の payload が、
// 拡張側の最終ゲート(monitorWebviewMessages.ts の isMonitorFromWebviewMessage)を通ることの
// 往復テスト。実 HTML+実バンドルで動かす方式は webviewDevicePickHost.test.mjs と同じ。
//
// **片側だけ改名すると黙って壊れる**: webview は machine で送り、ゲートが name を要求していると
// メッセージごと捨てられ、マシンの追加・削除が画面上は成功したように見えて登録簿に届かない
// (2026-08-26 の host→machine 改名で実際に起きた)。両側を1本のテストで縛る。

import assert from "node:assert/strict";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorModel";

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

function createWebview(onPost = () => {}) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: onPost, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function click(window, element) {
  element.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

function fill(window, input, value) {
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
}

const REMOTE_CONFIG = {
  type: "remoteConfig",
  hosts: [{ machine: "M1Max", host: "user@m1max", dir: "" }],
  artifacts: "collect",
};

test("remoteConfig の machine が表の1列目に出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  const inputs = document.querySelectorAll("#settings-remote-hosts-body tr input");
  assert.equal(inputs[0].value, "M1Max");
  assert.equal(inputs[1].value, "user@m1max");
});

// **マシン名は任意**(2026-08-27)。この Mac だけのエイリアスなので、名前を付けたくない
// 利用者に付けさせない。空欄なら host のホスト部が名前になる(CLI 側も同じ既定を持つが、
// 拡張は差分計算を machine で行うため送る時点で埋める)
test("マシン名が空でもホストだけで確定できる(名前は必須ではない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  click(window, document.getElementById("settings-remote-hosts-add"));
  const pendingRow = document.querySelector("#settings-remote-hosts-body tr.settings-remote-hosts-row-pending");
  const inputs = pendingRow.querySelectorAll("input");
  const confirm = pendingRow.querySelector(".settings-remote-hosts-confirm");

  assert.equal(confirm.disabled, true, "空行では確定できない");
  fill(window, inputs[1], "user@m1ultra.local");
  assert.equal(confirm.disabled, false, "ホストだけで確定できる(マシン名は任意)");
});

test("マシン名欄のウォーターマークが、省略したときに付く名前を先に見せる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  click(window, document.getElementById("settings-remote-hosts-add"));
  const pendingRow = document.querySelector("#settings-remote-hosts-body tr.settings-remote-hosts-row-pending");
  const inputs = pendingRow.querySelectorAll("input");

  assert.match(inputs[0].placeholder, /省略可|optional/,
    "ホスト未入力のうちは「省略できる」ことを出す");
  fill(window, inputs[1], "user@m1ultra.local");
  assert.equal(inputs[0].placeholder, "m1ultra.local", "user@ を落としたホスト部を出す");
  fill(window, inputs[1], "192.168.1.20");
  assert.equal(inputs[0].placeholder, "192.168.1.20");
});

test("マシン名を空のまま確定すると、host のホスト部が machine として送られる", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  click(window, document.getElementById("settings-remote-hosts-add"));
  const pendingRow = document.querySelector("#settings-remote-hosts-body tr.settings-remote-hosts-row-pending");
  const inputs = pendingRow.querySelectorAll("input");
  fill(window, inputs[1], "user@m1ultra.local");
  click(window, pendingRow.querySelector(".settings-remote-hosts-confirm"));

  const message = JSON.parse(JSON.stringify(posted.filter((m) => m.type === "setRemoteConfig").at(-1)));
  const added = message.hosts.find((h) => h.host === "user@m1ultra.local");
  assert.deepEqual(added, { machine: "m1ultra.local", host: "user@m1ultra.local", dir: "" });
  assert.ok(isMonitorFromWebviewMessage(message), "拡張側のゲートを通る");
});

test("行を追加して確定すると setRemoteConfig が machine/host/dir で送られ、拡張側のゲートを通る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  click(window, document.getElementById("settings-remote-hosts-add"));

  const pendingRow = document.querySelector("#settings-remote-hosts-body tr.settings-remote-hosts-row-pending");
  const inputs = pendingRow.querySelectorAll("input");
  fill(window, inputs[0], "M1Ultra");
  fill(window, inputs[1], "user@m1ultra");
  click(window, pendingRow.querySelector(".settings-remote-hosts-confirm"));

  const raw = posted.filter((m) => m.type === "setRemoteConfig").at(-1);
  assert.ok(raw, "setRemoteConfig が送られる");
  // postMessage で渡るオブジェクトは jsdom 側の realm 産で、deepStrictEqual がプロトタイプ不一致で
  // 落ちる(webviewDevicePickHost.test.mjs と同じ罠)。実際の postMessage と同じく構造化して比べる。
  const message = JSON.parse(JSON.stringify(raw));
  assert.deepEqual(
    message.hosts.map((h) => ({ machine: h.machine, host: h.host, dir: h.dir })),
    [
      { machine: "M1Max", host: "user@m1max", dir: "" },
      { machine: "M1Ultra", host: "user@m1ultra", dir: "" },
    ],
  );
  // 拡張側は isMonitorFromWebviewMessage を通らないメッセージを黙って捨てる(monitorPanel.ts)。
  assert.equal(isMonitorFromWebviewMessage(message), true);
});

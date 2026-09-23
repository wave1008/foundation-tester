// webviewLivePlaceholderStretch.test.mjs
// デバイスモニターの「ライブ操作」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// harness は webviewLiveStaleNotice.test.mjs と同型(renderHtml + main.js を実バンドルして
// window.eval で実行する)。
//
// 検証対象: 絵がまだ1枚も来ていない間の placeholder(「デバイスに接続されていません」)が、
// 縦(fitScreenshot が入れる高さ)にも横(ペインの awaiting-image クラス)にも伸びること。
//
// 実害(2026-09-23): placeholder の寸法が中身任せ(パディング+1行)だったため、ライブ操作を
// 開いた直後は縮んだ箱で待ち、最初のフレームが届いた瞬間にペインの寸法が変わって
// レイアウトが組み直っていた。

import assert from "node:assert/strict";
import fs from "node:fs";
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
  const vscodeStub = {
    Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) },
  };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = {
    asWebviewUri: (uri) => `https://localhost${uri.path}`,
    cspSource: "https://localhost",
  };
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

// jsdom はレイアウトを持たない(clientHeight/offsetHeight は常に 0)ので、fitScreenshot の入力に
// なる2つの実測値だけを固定値で与える。liveTab.js の SCREENSHOT_PANE_GAP / SCREENSHOT_WRAP_BORDER
// (CSS と一致させる契約)は production の値をそのまま使う = ここでは高さの一致だけを見る。
const PANE_HEIGHT = 700;
const ACTIONS_HEIGHT = 30;

function createWebview() {
  const dom = new JSDOM(panelHtml, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url: "https://localhost/",
  });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: () => {},
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  window.document.getElementById("tab-live").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );

  const stub = (id, prop, value) => {
    Object.defineProperty(window.document.getElementById(id), prop, { value, configurable: true });
  };
  stub("live-screenshot-pane", "clientHeight", PANE_HEIGHT);
  stub("live-screenshot-actions", "offsetHeight", ACTIONS_HEIGHT);

  return { window, document: window.document };
}

/** fitScreenshot を走らせる(webview 側は resize でも引き直す契約)。 */
function relayout(window) {
  window.dispatchEvent(new window.Event("resize"));
}

test("絵が来るまでの placeholder は絵と同じ高さまで伸びる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const placeholder = document.getElementById("live-screenshot-placeholder");
  const screenshot = document.getElementById("live-screenshot");
  assert.notEqual(placeholder.style.display, "none", "前提: 絵が1枚も来ていないので placeholder が出ている");

  relayout(window);

  assert.notEqual(placeholder.style.height, "", "placeholder に高さが入ること");
  assert.equal(
    placeholder.style.height,
    screenshot.style.maxHeight,
    "絵に入る上限と同じ高さで待つこと(最初のフレームでペインの高さが変わらない)",
  );
});

test("ペインの高さが変われば placeholder も追随する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const placeholder = document.getElementById("live-screenshot-placeholder");
  relayout(window);
  const first = placeholder.style.height;

  Object.defineProperty(document.getElementById("live-screenshot-pane"), "clientHeight", {
    value: PANE_HEIGHT + 200,
    configurable: true,
  });
  relayout(window);

  assert.notEqual(placeholder.style.height, first, "高さを入れ直すこと");
  assert.equal(placeholder.style.height, document.getElementById("live-screenshot").style.maxHeight);
});

/** 絵が1枚届いた状態にする(host の snapshot イベント。liveModel.ts の LiveSnapshot と同形)。 */
function sendSnapshot(window) {
  window.dispatchEvent(new window.MessageEvent("message", {
    data: {
      type: "live",
      message: {
        type: "snapshot",
        platform: "ios",
        screen: { width: 400, height: 800 },
        image: "AAAA",
        elements: [],
        notes: [],
      },
    },
  }));
}

test("絵が来るまではペインが左右にも伸びる(awaiting-image)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const pane = document.getElementById("live-screenshot-pane");
  assert.ok(pane.classList.contains("awaiting-image"), "絵が1枚も来ていない間は左右へ伸ばすこと");

  sendSnapshot(window);
  assert.ok(
    !pane.classList.contains("awaiting-image"),
    "絵が出たら解くこと(以降はペインが絵の実寸にハグし、要素一覧が絵の直後へ並ぶ)",
  );
});

// jsdom は webview の外部 CSS を読まない(クラスの付け外しまでしか見られない)ので、伸ばす規則
// そのものはソースで確かめる。クラスだけ残して規則を消しても DOM テストは緑になる。
test("awaiting-image の規則が CSS にある", () => {
  const css = fs.readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");
  for (const rule of [
    "#panel-live .screenshot-pane.awaiting-image { flex: 1 1 auto; }",
    "#panel-live .screenshot-pane.awaiting-image .screenshot-wrap { width: 100%; }",
    "#panel-live .screenshot-pane.awaiting-image #live-screenshot-placeholder { width: 100%; max-width: none; }",
  ]) {
    assert.ok(css.includes(rule), `CSS に無い: ${rule}`);
  }
});

/** 前のデバイスの絵を掴んだままにしないこと。切り替え後も前の画面が出ていると、lastScreen は
 * 捨てられているのでポインタ操作は無反応 = 生きた画面に見える静止画になる。 */
test("デバイス切り替え(host の clearSnapshot)で前のデバイスの絵を捨てる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const screenshot = document.getElementById("live-screenshot");
  const placeholder = document.getElementById("live-screenshot-placeholder");
  const pane = document.getElementById("live-screenshot-pane");

  sendSnapshot(window);
  assert.ok(screenshot.getAttribute("src"), "前提: 絵が出ている");
  assert.equal(placeholder.style.display, "none");

  window.dispatchEvent(new window.MessageEvent("message", {
    data: { type: "live", message: { type: "clearSnapshot" } },
  }));

  assert.equal(screenshot.getAttribute("src"), null, "前のデバイスの絵を捨てること");
  assert.ok(!screenshot.classList.contains("visible"), "絵を前面から下げること");
  assert.notEqual(placeholder.style.display, "none", "placeholder へ戻ること");
  assert.ok(pane.classList.contains("awaiting-image"), "左右のストレッチも戻ること");
});

test("デバイス選択(プルダウン)を変えた時点で前のデバイスの絵を捨てる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const screenshot = document.getElementById("live-screenshot");
  const select = document.getElementById("live-device-select");

  window.dispatchEvent(new window.MessageEvent("message", {
    data: {
      type: "live",
      message: {
        type: "devices",
        devices: [
          { id: "ios:A", name: "A", platform: "ios", state: "connected" },
          { id: "ios:B", name: "B", platform: "ios", state: "connected" },
        ],
        selectedId: "ios:A",
      },
    },
  }));
  sendSnapshot(window);
  assert.ok(screenshot.getAttribute("src"), "前提: 絵が出ている");

  select.value = "ios:B";
  select.dispatchEvent(new window.Event("change", { bubbles: true }));

  // host の clearSnapshot(serve の張り替え後)を待たずに捨てること
  assert.equal(screenshot.getAttribute("src"), null, "切り替えた時点で捨てること");
  assert.ok(
    document.getElementById("live-screenshot-pane").classList.contains("awaiting-image"),
    "placeholder の状態へ戻ること",
  );
});

// webviewLiveDrag.test.mjs
// デバイスモニターの「ライブ操作」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// renderHtml(monitorHtml.ts)を vscode スタブ付きでオンザフライ bundle して HTML を生成し、
// src/webview/monitor/main.js も esbuild(write:false)で bundle して window.eval で実行する
// (harness は webviewDevicesTabVisible.test.mjs と同型)。
// 実 VSCode webview との差分は acquireVsCodeApi / getBoundingClientRect / PointerEvent のみ
// (setPointerCapture は jsdom に無いが、liveTab.js 側が try/catch で握る契約なのでシム不要)。
//
// 検証対象(ドラッグ=スワイプ機能の回帰):
// - 「ライブ操作」タブへ切り替えると visibility:true を host へ送る(refreshDevices は
//   タブに関わらず起動時に一度だけ送る。main.js の initLive() 参照)
// - snapshot 未取得のまま frame だけ受信 → refreshSnapshot を一度だけ自動要求(パネル開き直しで
//   「ライブ操作」タブが復元された直後の「タップ/ドラッグ無反応」の再発防止)
// - snapshot 取得前はポインタ操作を送らない
// - snapshot 取得後: 移動 5px 未満=tapPoint、以上=dragPoints。pointerup は window 側で拾う
//   (setPointerCapture が効かない環境の取りこぼし防止)。範囲外で離したら表示範囲へクランプ

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
  // renderHtml を vscode スタブで実行して実 HTML を得る
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

  // webview バンドル(media/ 出力を経由せず現ソースから直接 bundle する)
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

/** 実 HTML+バンドルを読み込んだ webview 相当の DOM を作り、host への postMessage を捕捉する。
 * スクリプト実行(=webviewBundle の eval)の直後に「ライブ操作」タブへ切り替える(タブ切替は
 * main.js 側の ft-tab-activated 経由で visibility:true を発火させるのに必要)。 */
/** **window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない**
 * (node --test はファイル単位の子プロセスの終了を待つので、1本の閉じ忘れでスイート全体が
 * 止まる。2026-08-17 に実際に起き、npm test が終わらなくなった)。各 test は t.after で閉じる。 */
function createWebview() {
  const dom = new JSDOM(panelHtml, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url: "https://localhost/",
  });
  const { window } = dom;
  const posts = [];
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posts.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  window.document.getElementById("tab-live").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }),
  );

  const screenshot = window.document.getElementById("live-screenshot");
  // jsdom はレイアウトを持たないため表示サイズを固定で与える(400x800)
  screenshot.getBoundingClientRect = () => ({
    left: 0, top: 0, right: 400, bottom: 800, width: 400, height: 800, x: 0, y: 0,
  });

  const sendToWebview = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  // jsdom レルムのオブジェクトは Object.prototype が異なり deepEqual が落ちるため JSON で正規化する
  const liveMessages = () => posts.filter((p) => p.type === "live").map((p) => JSON.parse(JSON.stringify(p.message)));
  return { window, document: window.document, posts, screenshot, sendToWebview, liveMessages };
}

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0, altKey = false, shiftKey = false }) {
  const event = new window.MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button,
    altKey,
    shiftKey,
  });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}

const SNAPSHOT_MESSAGE = {
  type: "live",
  message: {
    type: "snapshot",
    platform: "ios",
    screen: { width: 400, height: 800 },
    image: "aW1n",
    elements: [],
  },
};
const FRAME_MESSAGE = { type: "live", message: { type: "frame", image: "aW1n" } };

/** デバイスを切り替えると host(monitorLiveController.clearSnapshotCache)が clearSnapshot を送る。
 * 前のデバイスの画面サイズ・要素一覧を握ったままだと、タップ座標が前のデバイスの座標系で換算され
 * (px の Android → pt の iOS で特に大きく外れる)、要素一覧の行タップは新しいデバイスの木の
 * 同じ番号を叩く。捨てたあとは snapshot 未取得と同じ状態(無反応 + 撮り直しの自動要求)に戻る。 */
test("clearSnapshot 後は前のデバイスの座標系でタップせず、要素一覧を捨てて撮り直しを要求する", (t) => {
  const { window, document, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());

  sendToWebview({
    ...SNAPSHOT_MESSAGE,
    message: {
      ...SNAPSHOT_MESSAGE.message,
      elements: [
        { ref: 1, text: "button #btn", type: "button", frame: { x: 0, y: 0, width: 100, height: 40 } },
      ],
    },
  });
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 100, y: 100 }));
  assert.equal(liveMessages().filter((m) => m.type === "tapPoint").length, 1, "前提: snapshot があればタップを送る");
  assert.equal(document.getElementById("live-elements-list").children.length, 1, "前提: 要素一覧が出ている");

  sendToWebview({ type: "live", message: { type: "clearSnapshot" } });
  assert.equal(document.getElementById("live-elements-list").children.length, 0, "要素一覧を捨てること");

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 100, y: 100 }));
  assert.equal(
    liveMessages().filter((m) => m.type === "tapPoint").length,
    1,
    "捨てたあとのタップは送らない(前のデバイスの座標系で換算しない)",
  );

  sendToWebview(FRAME_MESSAGE);
  assert.equal(
    liveMessages().filter((m) => m.type === "refreshSnapshot").length,
    1,
    "次のフレームで撮り直しを自動要求する",
  );
});

// 要素一覧は**読むためのもの**。行を押しただけでデバイスへタップが飛ぶと、見ているつもりの
// 操作が画面を変えてしまう(ユーザー決定 2026-09-22 で無効化。見出しからも「クリックでタップ」を外した)。
test("要素一覧の行をクリックしても何も送らない", (t) => {
  const { window, document, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());

  sendToWebview({
    ...SNAPSHOT_MESSAGE,
    message: {
      ...SNAPSHOT_MESSAGE.message,
      elements: [
        { ref: 1, type: "button", label: "ホーム", identifier: "tab_home", value: null,
          frame: { x: 0, y: 760, width: 134, height: 40 } },
      ],
    },
  });
  const row = document.querySelector("#live-elements-list .element-row");
  assert.ok(row, "前提: 行が出ている");
  const before = liveMessages().length;

  row.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  assert.equal(liveMessages().length, before, "行クリックでは host へ何も送らないこと");
  assert.ok(!row.classList.contains("selected"), "選択表示も付けないこと");
});

test("起動時に refreshDevices を送り、「ライブ操作」タブへの切替で visibility:true を送る", (t) => {
  const { window, liveMessages } = createWebview();
  t.after(() => window.close());
  const messages = liveMessages();
  assert.ok(messages.some((m) => m.type === "visibility" && m.visible === true));
  assert.ok(messages.some((m) => m.type === "refreshDevices"));
});

test("snapshot 未取得で frame のみ受信: refreshSnapshot を一度だけ自動要求し、ポインタ操作は送らない", (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());

  sendToWebview(FRAME_MESSAGE);
  sendToWebview(FRAME_MESSAGE);
  const refreshes = liveMessages().filter((m) => m.type === "refreshSnapshot");
  assert.equal(refreshes.length, 1, "frame を複数回受けても自動 refreshSnapshot は一度だけ");

  // lastScreen が無いのでポインタ操作は無反応(押下時点で弾く)
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 100, y: 300 }));
  const gestures = liveMessages().filter((m) => m.type === "tapPoint" || m.type === "dragPoints");
  assert.equal(gestures.length, 0);
});

test("snapshot 取得後: 5px 以上の移動は dragPoints(window の pointerup で拾う)", (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  const down = pointerEvent(window, "pointerdown", { x: 100, y: 100 });
  screenshot.dispatchEvent(down);
  assert.equal(down.defaultPrevented, true, "pointerdown でネイティブ画像ドラッグを抑止する");
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 100, y: 300 }));
  // capture が効かない環境を想定し、pointerup は window へ直接投げる
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 100, y: 300 }));

  const drags = liveMessages().filter((m) => m.type === "dragPoints");
  assert.equal(drags.length, 1);
  const { pressMs, dragMs, ...rest } = drags[0];
  assert.deepEqual(rest, {
    type: "dragPoints",
    fromX: 100, fromY: 100, toX: 100, toY: 300,
    displayWidth: 400, displayHeight: 800,
  });
  assert.equal(typeof pressMs, "number");
  assert.ok(pressMs >= 0);
  assert.equal(typeof dragMs, "number");
  assert.ok(dragMs >= 0);
});

test("snapshot 取得後: 5px 未満の移動は tapPoint になる", (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 50, y: 60 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 52, y: 61 }));

  const taps = liveMessages().filter((m) => m.type === "tapPoint");
  assert.equal(taps.length, 1);
  assert.deepEqual(taps[0], {
    type: "tapPoint",
    clickX: 52, clickY: 61,
    displayWidth: 400, displayHeight: 800,
  });
  assert.equal(liveMessages().filter((m) => m.type === "dragPoints").length, 0);
});

test("ドラッグ中は軌跡オーバーレイが表示され、離すと消える", (t) => {
  const { window, screenshot, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);
  const overlay = window.document.getElementById("live-drag-overlay");
  const line = window.document.getElementById("live-drag-line");

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100 }));
  assert.ok(overlay.classList.contains("visible"), "押下でオーバーレイ表示");
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 150, y: 250 }));
  assert.equal(line.getAttribute("x2"), "150");
  assert.equal(line.getAttribute("y2"), "250");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 250 }));
  assert.ok(!overlay.classList.contains("visible"), "離すとオーバーレイ非表示");
});

test("軌跡モードのオーバーレイは直線でなく、通った点を結ぶ折れ線を描く", (t) => {
  const { window, document, screenshot, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);
  const overlay = document.getElementById("live-drag-overlay");
  const trace = document.getElementById("live-drag-trace");

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100 }));
  assert.ok(!overlay.classList.contains("trace"), "OFF のときは直線の表示");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 100, y: 100 }));

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 300 }));
  assert.ok(overlay.classList.contains("trace"), "ON のときは折れ線の表示");
  const pts = trace.getAttribute("points");
  assert.ok(pts.startsWith("100,100"), "始点から描く: " + pts);
  assert.ok(pts.includes("200,100"), "途中の曲がり角を含む: " + pts);
  assert.ok(pts.endsWith("200,300"), "今の指の位置まで描く: " + pts);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 300 }));
});

test("500ms 以上ホールドして離すと pressPoint になる", async (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 80, y: 90 }));
  await new Promise((resolve) => setTimeout(resolve, 550));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 81, y: 90 }));

  const presses = liveMessages().filter((m) => m.type === "pressPoint");
  assert.equal(presses.length, 1);
  assert.equal(presses[0].clickX, 81);
  assert.ok(presses[0].holdMs >= 500);
  assert.equal(liveMessages().filter((m) => m.type === "tapPoint").length, 0);
});

test("画像の外で離したドラッグは表示範囲にクランプされる", (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 200, y: 700 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 500, y: 900 }));

  const drags = liveMessages().filter((m) => m.type === "dragPoints");
  assert.equal(drags.length, 1);
  assert.equal(drags[0].toX, 400);
  assert.equal(drags[0].toY, 800);
  assert.equal(typeof drags[0].pressMs, "number");
  assert.ok(drags[0].pressMs >= 0);
  assert.equal(typeof drags[0].dragMs, "number");
  assert.ok(drags[0].dragMs >= 0);
});

// マップ・キャンバス系の操作。**ダブルタップは「素早く2回」では表せない** ——
// パネルの1クリックは既にタップとして送っているので、2回目を待つ設計にすると通常のタップが
// 毎回遅くなる。そこで Alt(Option)+クリックに割り当てている
test("Alt+クリックは doubleTapPoint になる(通常のタップは送らない)", (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 70, y: 80, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 71, y: 80 }));

  const doubles = liveMessages().filter((m) => m.type === "doubleTapPoint");
  assert.equal(doubles.length, 1);
  assert.equal(doubles[0].clickX, 71);
  assert.equal(liveMessages().filter((m) => m.type === "tapPoint").length, 0,
    "ダブルタップのときは通常のタップを送らない(3回タップになる)");
});

// **修飾キーは UI に出ていないと使われない**(README だけでは届かない)。
// ヒント表示と画面領域の tooltip の両方を固定する
test("Option(⌥)+クリックの割り当てがパネル上に表示されている", (t) => {
  const { window } = createWebview();
  t.after(() => window.close());

  const hint = window.document.getElementById("live-gesture-hint");
  assert.ok(hint, "ツールバーに割り当てのヒントを出すこと");
  // macOS 専用のツールなので、キー名は Mac のキーボードの刻印で出す
  assert.ok(hint.textContent.includes("Option(⌥)"), `Option(⌥) で出すこと: ${hint.textContent}`);
  assert.match(hint.textContent, /ダブルタップ|double tap/i);
  // **2行で出す**(CSS の white-space: pre-line が効く前提。文言から改行が落ちると1行に戻る)
  assert.ok(hint.textContent.includes("\n"), `ヒントは2行で出すこと: ${JSON.stringify(hint.textContent)}`);

  // 画面領域をホバーすれば全割り当てが読める
  const wrap = window.document.getElementById("live-screenshot-wrap");
  assert.ok((wrap.getAttribute("title") ?? "").includes("Option(⌥)"));
  assert.ok((wrap.getAttribute("title") ?? "").includes("Shift(⇧)"));
  assert.match(wrap.getAttribute("title") ?? "", /ダブルタップ|double tap/i);
});

test("拡大・縮小ボタンは画面全体のピンチを送る", (t) => {
  const { window, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  window.document.getElementById("live-btn-zoom-in").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }));
  window.document.getElementById("live-btn-zoom-out").dispatchEvent(
    new window.MouseEvent("click", { bubbles: true }));

  const pinches = liveMessages().filter((m) => m.type === "pinch");
  assert.deepEqual(pinches.map((m) => m.zoomIn), [true, false]);
});

// ---- 軌跡モード(Shift+ドラッグ) ----
// 通常のドラッグは1回のスワイプ(dragPoints)に合成される(ユーザー決定・維持)。軌跡モードは
// pointerdown 時の Shift 押下だけで決まり、マウスの軌跡をそのまま1本の離さないタッチとして送る
// (tracePoints)。ツールバーの「軌跡」は押せない表示灯(Shift を押している間だけ点く)。

test("Shift を押していなければドラッグは今までどおり dragPoints", (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 120, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 120, y: 150 }));

  assert.equal(liveMessages().filter((m) => m.type === "dragPoints").length, 1);
  assert.equal(liveMessages().filter((m) => m.type === "tracePoints").length, 0);
});

test("Shift+ドラッグは tracePoints を送る(始点・終点を含む)", (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 110, y: 120 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 130, y: 160 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 130, y: 160 }));

  const traces = liveMessages().filter((m) => m.type === "tracePoints");
  assert.equal(traces.length, 1);
  assert.equal(liveMessages().filter((m) => m.type === "dragPoints").length, 0,
    "軌跡モードのときは dragPoints を送らないこと");
  const trace = traces[0];
  assert.equal(trace.displayWidth, 400);
  assert.equal(trace.displayHeight, 800);
  assert.ok(trace.points.length >= 2, "少なくとも始点・終点は含むこと");
  assert.deepEqual([trace.points[0].x, trace.points[0].y], [100, 100], "始点を含むこと");
  const last = trace.points[trace.points.length - 1];
  assert.deepEqual([last.x, last.y], [130, 160], "終点を含むこと");
  assert.equal(trace.points[0].t, 0, "始点の t は 0");
  for (let i = 1; i < trace.points.length; i++) {
    assert.ok(trace.points[i].t >= trace.points[i - 1].t, "t は単調非減少");
  }
});

test("軌跡モードは押した時点の Shift で決まる(途中で Shift を押しても離しても変わらない)", (t) => {
  const { window, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 60, y: 70 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 90, y: 110, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 90, y: 110, shiftKey: true }));
  assert.equal(liveMessages().filter((m) => m.type === "tracePoints").length, 0);
  assert.equal(liveMessages().filter((m) => m.type === "dragPoints").length, 1);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 60, y: 70, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 90, y: 110 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 90, y: 110 }));
  assert.equal(liveMessages().filter((m) => m.type === "tracePoints").length, 1);
});

test("「軌跡」は押せない表示灯: Shift を押している間だけ点き、離すと消える", (t) => {
  const { window, document, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);
  const indicator = document.getElementById("live-trace-indicator");
  assert.ok(indicator, "表示灯があること");
  assert.equal(document.getElementById("live-btn-trace-toggle"), null, "トグルボタンは無いこと");
  assert.notEqual(indicator.tagName, "BUTTON", "押せる部品にしないこと");
  assert.ok(!indicator.classList.contains("active"), "前提: 最初は消えている");

  window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Shift", shiftKey: true }));
  assert.ok(indicator.classList.contains("active"), "Shift を押すと点く");
  window.dispatchEvent(new window.KeyboardEvent("keyup", { key: "Shift" }));
  assert.ok(!indicator.classList.contains("active"), "Shift を離すと消える");

  // フォーカスが無くてもマウスイベントの shiftKey で追従する
  screenshot.dispatchEvent(pointerEvent(window, "pointermove", { x: 10, y: 10, shiftKey: true }));
  assert.ok(indicator.classList.contains("active"), "画面上で Shift を押したまま動かすと点く");
  screenshot.dispatchEvent(pointerEvent(window, "pointermove", { x: 12, y: 10 }));
  assert.ok(!indicator.classList.contains("active"), "Shift を離して動かすと消える");

  window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Shift", shiftKey: true }));
  window.dispatchEvent(new window.Event("blur"));
  assert.ok(!indicator.classList.contains("active"), "フォーカスを失ったら消す(keyup を取りこぼすため)");

  // クリックしても何も切り替わらず、何も送らない
  const before = liveMessages().length;
  indicator.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.ok(!indicator.classList.contains("active"));
  assert.equal(liveMessages().length, before);
});

test("「軌跡」にマウスを乗せると Shift で操作することを説明する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const indicator = document.getElementById("live-trace-indicator");
  const tip = indicator.getAttribute("data-hover-tip") ?? "";
  assert.match(tip, /Shift/, "自前ツールチップ(0.2 秒で出る)に説明を載せること");
  assert.match(tip, /軌跡|path/);
  assert.equal(indicator.getAttribute("title"), "", "ネイティブ title は空にする(二重に出さない)");
});

test("軌跡モードでも 5px 未満の移動は今までどおり tapPoint(タップ/長押し/ダブルタップは変えない)", (t) => {
  const { window, document, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 50, y: 60, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 52, y: 61 }));

  const taps = liveMessages().filter((m) => m.type === "tapPoint");
  assert.equal(taps.length, 1);
  assert.equal(liveMessages().filter((m) => m.type === "tracePoints").length, 0);
  assert.equal(liveMessages().filter((m) => m.type === "dragPoints").length, 0);
});

// 軌跡は再生時間の絶対上限(60秒)まで。なぞっている最中に超えたら、その場で中止してエラーを出す
// (離すまで気付けないと、それまでの操作が無駄になる)。離しても何も送らない。
test("軌跡モードで60秒を超えて動かしたら、その場で中止してエラーを出し、離しても送らない", (t) => {
  const { window, document, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);
  let now = 1000;
  window.performance.now = () => now;
  const error = document.getElementById("live-action-error");

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100, shiftKey: true }));
  now += 30000;
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 150, y: 100 }));
  assert.ok(!error.classList.contains("visible"), "60秒以内は何も言わない");
  now += 30001;
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 100 }));
  assert.ok(error.classList.contains("visible"), "60秒を超えた時点でエラーを出す");
  assert.match(document.getElementById("live-action-error-text").textContent, /60/);
  assert.ok(!document.getElementById("live-drag-overlay").classList.contains("visible"), "線を消す");

  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 100 }));
  const sent = liveMessages().filter((m) => ["tracePoints", "dragPoints", "tapPoint", "pressPoint"].includes(m.type));
  assert.equal(sent.length, 0, "離しても何も送らない");
});

test("軌跡モードで動かしたあと止めたまま60秒を超えても(pointermove が来なくても)中止してエラーを出す", (t) => {
  const { window, document, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);
  let now = 1000;
  window.performance.now = () => now;
  const timers = [];
  const realSetTimeout = window.setTimeout.bind(window);
  window.setTimeout = (fn, ms, ...rest) => {
    if (ms > 59000) { timers.push(fn); return 0; }
    return realSetTimeout(fn, ms, ...rest);
  };

  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 150, y: 100 }));
  assert.equal(timers.length, 1, "軌跡の押下で上限の時計を仕掛けること");
  now += 60001;
  timers[0]();
  assert.ok(document.getElementById("live-action-error").classList.contains("visible"), "時計でもエラーを出す");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 100 }));
  assert.equal(liveMessages().filter((m) => m.type === "tracePoints").length, 0, "離しても送らない");
});

test("60秒以内に離した軌跡はそのまま送る(上限の中止は効かない)", (t) => {
  const { window, document, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);
  let now = 1000;
  window.performance.now = () => now;
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100, shiftKey: true }));
  now += 59000;
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 100 }));
  assert.ok(!document.getElementById("live-action-error").classList.contains("visible"));
  assert.equal(liveMessages().filter((m) => m.type === "tracePoints").length, 1);
});

test("60秒で中止した後も、次の軌跡(押す→動かす→離す)は普通に送る", (t) => {
  const { window, document, screenshot, sendToWebview, liveMessages } = createWebview();
  t.after(() => window.close());
  sendToWebview(SNAPSHOT_MESSAGE);
  let now = 1000;
  window.performance.now = () => now;

  // 1本目: 60秒を超えて中止(マウスはまだ押したまま)→ 離す
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 100, y: 100, shiftKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 150, y: 100 }));
  now += 60001;
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 220, y: 100 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 220, y: 100 }));
  assert.equal(liveMessages().filter((m) => m.type === "tracePoints").length, 0);

  // 2本目: 普通の軌跡
  now += 1000;
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 200, y: 600, shiftKey: true }));
  assert.ok(document.getElementById("live-drag-overlay").classList.contains("visible"), "線がまた出る");
  now += 300;
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 400 }));
  now += 300;
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 200 }));
  const traces = liveMessages().filter((m) => m.type === "tracePoints");
  assert.equal(traces.length, 1, "2本目は送ること");
  assert.deepEqual([traces[0].points[0].x, traces[0].points[0].y], [200, 600], "2本目の始点から");
  assert.equal(traces[0].points[0].t, 0, "時刻は2本目の押下から数え直す");
  assert.ok(traces[0].points[traces[0].points.length - 1].t < 1000, "1本目の経過を引きずらない");
});

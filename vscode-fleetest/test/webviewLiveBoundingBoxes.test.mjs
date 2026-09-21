// webviewLiveBoundingBoxes.test.mjs
// デバイスモニターの「ライブ操作」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// renderHtml(monitorHtml.ts)を vscode スタブ付きでオンザフライ bundle して HTML を生成し、
// src/webview/monitor/main.js も esbuild(write:false)で bundle して window.eval で実行する
// (harness は webviewDevicesTabVisible.test.mjs と同型)。
// 実 VSCode webview との差分は acquireVsCodeApi / getBoundingClientRect / PointerEvent のみ
// (setPointerCapture は jsdom に無いが、liveTab.js 側が try/catch で握る契約なのでシム不要)。
//
// 検証対象: 「バウンディングボックスを表示」トグル(要素一覧の見出し)と、画像上のホバー。
// 全要素の枠を画像に重ねて出す。枠の座標は hover 枠と同じ frameToDisplayRect(表示px)で、
// 表示サイズが変わるたびに引き直す。トグルの状態は vscode.setState に持つ。
// 画像上でマウスが載っている要素は枠を赤くし、**対になる要素一覧の行も同時に**光らせる
// (当たり判定は liveModel.ts の hitTestElement と同じ「面積最小」規則の複製)。

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
  // scrollIntoView は jsdom に無い。呼び出しを記録して「一覧の外の行を送ったか」を見る
  const scrolled = [];
  window.HTMLElement.prototype.scrollIntoView = function (options) { scrolled.push({ el: this, options }); };
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
  return { window, document: window.document, posts, screenshot, sendToWebview, liveMessages, scrolled };
}

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0, altKey = false }) {
  const event = new window.MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button,
    altKey,
  });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}


const ELEMENTS = [
  { ref: 1, type: "button", label: "ホーム", identifier: "tab_home", value: null,
    frame: { x: 0, y: 760, width: 134, height: 40 } },
  { ref: 2, type: "staticText", label: "情報", identifier: "txt_title", value: null,
    frame: { x: 16, y: 60, width: 370, height: 24 } },
];

const SNAPSHOT = {
  type: "live",
  message: {
    type: "snapshot", platform: "ios",
    screen: { width: 400, height: 800 },
    image: "aW1n",
    elements: ELEMENTS,
  },
};

/** 要素ごとの枠(強調用に重ねる1枚は除く)。 */
function boxes(document) {
  return [...document.getElementById("live-boxes-overlay").querySelectorAll("rect:not(.hot)")];
}

test("トグルが『アプリを起動』の右にある", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const toggle = document.getElementById("live-boxes-toggle");
  assert.ok(toggle, "トグルが存在すること");
  assert.equal(
    toggle.previousElementSibling.id, "live-btn-launch",
    "「アプリを起動」のすぐ右に並ぶこと",
  );
  assert.equal(document.getElementById("live-show-boxes").checked, false, "既定は OFF");
});

test("ON で全要素の枠を出し、OFF で消す", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  sendToWebview(SNAPSHOT);
  assert.equal(boxes(document).length, 0, "既定(OFF)では枠を出さない");

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));

  const drawn = boxes(document);
  assert.equal(drawn.length, ELEMENTS.length, "要素の数だけ枠を出すこと");
  // 画面 400x800 を 400x800 で表示しているので 1:1(createWebview の rect スタブ)
  assert.deepEqual(
    drawn.map((r) => [r.getAttribute("x"), r.getAttribute("y"),
                      r.getAttribute("width"), r.getAttribute("height")].join(",")),
    ["0,760,134,40", "16,60,370,24"],
    "枠の位置は要素の frame を表示座標へ写したもの",
  );

  checkbox.checked = false;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(boxes(document).length, 0, "OFF で消すこと");
});

test("ON のまま新しい snapshot が来たら枠を引き直す", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);
  assert.equal(boxes(document).length, 2, "前提: 2つ出ている");

  sendToWebview({
    ...SNAPSHOT,
    message: { ...SNAPSHOT.message, elements: [ELEMENTS[0]] },
  });
  assert.equal(boxes(document).length, 1, "新しい木の要素数に追随すること");
});

test("デバイスを切り替えたら枠も捨てる", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);
  assert.equal(boxes(document).length, 2, "前提: 出ている");

  sendToWebview({ type: "live", message: { type: "clearSnapshot" } });
  assert.equal(boxes(document).length, 0, "前のデバイスの枠を残さないこと");
});

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerMove(window, x, y) {
  const event = new window.MouseEvent("pointermove", { bubbles: true, clientX: x, clientY: y });
  Object.defineProperty(event, "pointerId", { value: 1 });
  return event;
}

/** 強調用に最前面へ重ねた枠(元の枠とは別の1枚)。 */
function hotBoxes(document) {
  return [...document.getElementById("live-boxes-overlay").querySelectorAll("rect.hot")];
}

test("画像上のホバーで、その要素の枠と一覧の行が同時に光る", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);

  const screenshot = document.getElementById("live-screenshot");
  // 画面 400x800 を 400x800 で表示(createWebview の rect スタブ)なので 1:1。
  // ELEMENTS[1] = staticText (16,60 370x24) の内側を指す
  screenshot.dispatchEvent(pointerMove(window, 100, 70));

  assert.deepEqual(
    hotBoxes(document).map((r) => r.getAttribute("y")), ["60"],
    "指している要素の枠だけが hot になること",
  );
  const rows = [...document.querySelectorAll("#live-elements-list .element-row")];
  assert.deepEqual(
    rows.map((r) => r.classList.contains("hot")), [false, true],
    "対になる行(2行目 = ref 2)も同時に光ること",
  );

  // 重なりの中では面積最小を採る規則。ELEMENTS[0] = button (0,760 134x40) へ移す
  screenshot.dispatchEvent(pointerMove(window, 50, 780));
  assert.deepEqual(hotBoxes(document).map((r) => r.getAttribute("y")), ["760"]);
  assert.deepEqual(
    [...document.querySelectorAll("#live-elements-list .element-row")]
      .map((r) => r.classList.contains("hot")),
    [true, false],
  );

  // どの要素にも載っていない位置では消す
  screenshot.dispatchEvent(pointerMove(window, 399, 400));
  assert.equal(hotBoxes(document).length, 0, "外れたら枠の強調を消すこと");
  assert.equal(
    document.querySelectorAll("#live-elements-list .element-row.hot").length, 0,
    "行の強調も消すこと",
  );
});

test("画像から離れたら強調を消す", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);

  const screenshot = document.getElementById("live-screenshot");
  screenshot.dispatchEvent(pointerMove(window, 100, 70));
  assert.equal(hotBoxes(document).length, 1, "前提: 光っている");

  screenshot.dispatchEvent(new window.MouseEvent("pointerleave", { bubbles: false }));
  assert.equal(hotBoxes(document).length, 0);
  assert.equal(document.querySelectorAll("#live-elements-list .element-row.hot").length, 0);
});

// 重なりの中では**面積最小**を採る(liveModel.ts の hitTestElement と同じ規則)。容器を採ると、
// 画面のどこを指しても一番外側の scrollView が光って何の役にも立たない。
test("重なっている要素では面積が最小のものを採る", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview({
    type: "live",
    message: {
      type: "snapshot", platform: "ios",
      screen: { width: 400, height: 800 },
      image: "aW1n",
      elements: [
        // 先に来るのが外側の容器(木の順序)。素朴に「最初の一致」を採るとこちらが選ばれる
        { ref: 1, type: "scrollView", label: null, identifier: null, value: null,
          frame: { x: 0, y: 0, width: 400, height: 800 } },
        { ref: 2, type: "button", label: "OK", identifier: "btn_ok", value: null,
          frame: { x: 100, y: 100, width: 80, height: 40 } },
      ],
    },
  });

  document.getElementById("live-screenshot").dispatchEvent(pointerMove(window, 120, 120));

  assert.deepEqual(
    hotBoxes(document).map((r) => r.getAttribute("width")), ["80"],
    "内側の button を採ること(外側の scrollView ではない)",
  );
  assert.deepEqual(
    [...document.querySelectorAll("#live-elements-list .element-row")]
      .map((r) => r.classList.contains("hot")),
    [false, true],
    "光る行も内側の要素のほうであること",
  );
});

// 一覧は縦に長く、画像上で指した要素の行が見えていないことがある。**'nearest'** で送るので、
// 既に見えている行では一覧が動かない(マウスを少し動かすたびに跳ねない)。
test("画像上で指した要素の行を、見えるところまで送る", (t) => {
  const { window, document, sendToWebview, scrolled } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);
  scrolled.length = 0;

  // ELEMENTS[1] = staticText (16,60 370x24)
  document.getElementById("live-screenshot").dispatchEvent(pointerMove(window, 100, 70));

  const rows = [...document.querySelectorAll("#live-elements-list .element-row")];
  assert.equal(scrolled.length, 1, "送るのは1回だけ");
  assert.equal(scrolled[0].el, rows[1], "送るのは指した要素の行であること");
  assert.equal(scrolled[0].options.block, "nearest", "見えていれば動かさない指定であること");

  // 同じ要素の上で動かしても呼び直さない(対象が変わった回だけ)
  document.getElementById("live-screenshot").dispatchEvent(pointerMove(window, 110, 72));
  assert.equal(scrolled.length, 1, "対象が同じなら送り直さないこと");

  // 外れたときは送らない
  document.getElementById("live-screenshot").dispatchEvent(pointerMove(window, 399, 400));
  assert.equal(scrolled.length, 1, "どの要素にも載っていないときは送らないこと");
});

// 逆向き: 一覧の行にホバーしても同じ赤で光る(どちらから指しても同じ見た目)。
// 枠を出している間は単一枠(青)を使わない —— 同じ要素に2つ枠が出るため。
test("トグル ON: 行ホバーで枠と行が赤くなり、単一枠は出さない", (t) => {
  const { window, document, sendToWebview, scrolled } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);
  scrolled.length = 0;

  const rows = [...document.querySelectorAll("#live-elements-list .element-row")];
  rows[1].dispatchEvent(new window.MouseEvent("mouseenter", { bubbles: false }));

  assert.ok(rows[1].classList.contains("hot"), "その行が光ること");
  assert.deepEqual(hotBoxes(document).map((r) => r.getAttribute("y")), ["60"], "枠も赤くなること");
  assert.equal(
    document.getElementById("live-hover-box").style.display, "none",
    "単一枠(青)は出さないこと(枠と二重にならない)",
  );
  assert.equal(scrolled.length, 0, "行を直接ホバーしている間は一覧を送らないこと");

  rows[1].dispatchEvent(new window.MouseEvent("mouseleave", { bubbles: false }));
  assert.equal(hotBoxes(document).length, 0, "離れたら消すこと");
  assert.equal(document.querySelectorAll("#live-elements-list .element-row.hot").length, 0);
});

// トグル OFF では従来どおり単一枠(青)を出す(枠が無いので赤くする相手がいない)。
test("トグル OFF: 行ホバーは従来どおり単一枠を出す", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  sendToWebview(SNAPSHOT);
  const rows = [...document.querySelectorAll("#live-elements-list .element-row")];
  rows[1].dispatchEvent(new window.MouseEvent("mouseenter", { bubbles: false }));

  assert.equal(document.getElementById("live-hover-box").style.display, "block", "単一枠を出すこと");
  assert.ok(!rows[1].classList.contains("hot"), "行に赤枠は付けないこと");
});

// トグル OFF でも「どの要素を指しているか」は一覧で分かるようにする。違うのは見た目だけ:
// 赤枠は枠を出しているときだけで(CSS は .boxes-on 配下)、OFF では背景のハイライトになる。
test("トグル OFF: 画像上のホバーで行は光るが、赤枠は付けない", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  sendToWebview(SNAPSHOT); // トグルは既定 OFF のまま
  document.getElementById("live-screenshot").dispatchEvent(pointerMove(window, 100, 70));

  const rows = [...document.querySelectorAll("#live-elements-list .element-row")];
  assert.deepEqual(rows.map((r) => r.classList.contains("hot")), [false, true],
                   "指している要素の行が光ること");
  assert.ok(!document.getElementById("live-elements-list").classList.contains("boxes-on"),
            "赤枠の条件(.boxes-on)は付かないこと");
  assert.equal(boxes(document).length, 0, "枠そのものは出さないこと");
});

// ON のときだけ赤枠の条件が付く(見た目の出し分けは CSS 側)。
test("トグル ON: 一覧に赤枠の条件(.boxes-on)が付く", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  sendToWebview(SNAPSHOT);
  const list = document.getElementById("live-elements-list");
  assert.ok(!list.classList.contains("boxes-on"), "前提: OFF では付かない");

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.ok(list.classList.contains("boxes-on"), "ON で付くこと");

  checkbox.checked = false;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.ok(!list.classList.contains("boxes-on"), "OFF に戻したら外すこと");
});

// OFF のときは一覧も動かさない。指している要素が分からないのに一覧だけスクロールすると、
// 読んでいる場所を見失う(2026-09-22)。
test("トグル OFF: 画像上のホバーで一覧をスクロールしない", (t) => {
  const { window, document, sendToWebview, scrolled } = createWebview();
  t.after(() => window.close());

  sendToWebview(SNAPSHOT); // トグルは既定 OFF のまま
  scrolled.length = 0;

  const screenshot = document.getElementById("live-screenshot");
  screenshot.dispatchEvent(pointerMove(window, 100, 70));
  screenshot.dispatchEvent(pointerMove(window, 50, 780));

  assert.equal(scrolled.length, 0, "OFF の間は一覧を送らないこと");
});

// 強調は**既存の枠の色を変えず、同じ矩形をもう1枚最前面に重ねて**描く。SVG は DOM 順に
// 描かれるので、色だけ変えると後続の枠の下に隠れることがある(2026-09-22 の指摘)。
test("強調は最前面に重ねた別の枠で、元の枠は変えない", (t) => {
  const { window, document, sendToWebview } = createWebview();
  t.after(() => window.close());

  const checkbox = document.getElementById("live-show-boxes");
  checkbox.checked = true;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
  sendToWebview(SNAPSHOT);

  // ELEMENTS[1] = staticText (16,60 370x24)
  document.getElementById("live-screenshot").dispatchEvent(pointerMove(window, 100, 70));

  const overlay = document.getElementById("live-boxes-overlay");
  const all = [...overlay.querySelectorAll("rect")];
  assert.equal(all.length, ELEMENTS.length + 1, "要素の枠に加えて強調用が1枚だけ増えること");
  assert.ok(all[all.length - 1].classList.contains("hot"), "強調用が**最後の子**であること(最前面)");
  assert.equal(
    boxes(document).filter((r) => r.classList.contains("hot")).length, 0,
    "元の枠には強調を付けないこと",
  );
  // 重ねた枠は元の枠と同じ矩形
  const source = boxes(document)[1];
  const hot = all[all.length - 1];
  assert.deepEqual(
    ["x", "y", "width", "height"].map((a) => hot.getAttribute(a)),
    ["x", "y", "width", "height"].map((a) => source.getAttribute(a)),
    "同じ位置・同じ大きさで重ねること",
  );

  // 外れたら重ねた枠ごと外す
  document.getElementById("live-screenshot").dispatchEvent(pointerMove(window, 399, 400));
  assert.equal(overlay.querySelectorAll("rect.hot").length, 0, "外れたら重ねた枠を消すこと");
  assert.equal(boxes(document).length, ELEMENTS.length, "元の枠は残ること");
});

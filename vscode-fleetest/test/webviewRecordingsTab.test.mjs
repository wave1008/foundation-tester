// webviewRecordingsTab.test.mjs
// デバイスモニターパネル「録画」タブの webview を実 HTML+実バンドルで動かす DOM E2E(jsdom)。
// renderHtml(monitorHtml.ts)を vscode スタブ付きでオンザフライ bundle して HTML を生成し、
// src/webview/monitor/main.js も esbuild(write:false)で bundle して window.eval で実行する
// (test/webviewLiveDrag.test.mjs と同じ方式)。
//
// jsdom の HTMLMediaElement は再生を実装しない(load/play/pause は no-op スタブへ差し替える。
// loadedmetadata は発火しないため、動画切替の検証は同期的に反映される video.src の変化で行う)。
//
// 検証対象:
// - recordingsSession 適用でツリーが class→scenario→scene→step の階層で描画される(アイコン class 込み)
// - 動画の無いシナリオ行(とその配下)がグレーアウト+「録画なし」表示になる
// - ツリー行クリックで選択ハイライト+エラー一覧フィルター(チップ表示)、再クリックで解除
// - キーボード(録画タブアクティブ・再生ビュー表示中のみ): Space で play/pause
// - 連続再生 ON で 'ended' 発火時に次のテスト(scenarioNav の次エントリ)の動画へ切り替わる

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
  // renderHtml を vscode スタブで実行して実 HTML を得る(monitorHtml.ts が import する
  // src/i18n/index.ts は vscode を値 import するが、モジュールロード時には呼ばない契約
  // [同ファイル冒頭コメント参照]なのでスタブは Uri.joinPath だけで足りる)。
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

/** 実 HTML+バンドルを読み込んだ webview 相当の DOM を作り、録画タブをアクティブにする
 * (実ユーザー操作と同じくタブボタンをクリックする。キーボードショートカットが
 * 「録画タブアクティブ」を条件にするため必須)。
 * 呼び出し側は必ず t.after(() => window.close()) で後始末すること — main.js は
 * processesTab.js の setInterval(1秒ポーリング)を含むため、close() し忘れると
 * jsdom window ごとにタイマーが残り続け、テストプロセスが終了しなくなる。 */
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
  // jsdom は scrollIntoView を実装しない(updateNowPlaying が再生中行の追従に使う)。
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);

  const video = window.document.getElementById("recordings-video");
  // jsdom は HTMLMediaElement の読み込み/再生を実装しないため no-op に差し替える。
  video.load = () => {};
  let playCalls = 0;
  let pauseCalls = 0;
  video.play = () => {
    playCalls++;
    Object.defineProperty(video, "paused", { value: false, configurable: true });
    return Promise.resolve();
  };
  video.pause = () => {
    pauseCalls++;
    Object.defineProperty(video, "paused", { value: true, configurable: true });
  };

  window.document.getElementById("tab-recordings").click();

  const sendToWebview = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  return {
    window,
    posts,
    video,
    sendToWebview,
    playCalls: () => playCalls,
    pauseCalls: () => pauseCalls,
  };
}

const VIDEOS = [
  { scenarioID: "デモ.ログイン.S0010", videoUri: "https://localhost/videos/S0010.mp4" },
  { scenarioID: "デモ.ログイン.S0030", videoUri: "https://localhost/videos/S0030.mp4" },
  // S0020 は録画対象外(videos に無い) → ツリーでグレーアウト+「録画なし」表示になる
];

const TREE = [
  {
    classID: "デモ.ログイン",
    status: "failed",
    firstScenarioID: "デモ.ログイン.S0010",
    scenarios: [
      {
        scenarioID: "デモ.ログイン.S0010",
        title: "ログインできる",
        method: "S0010",
        startedAt: "2026-07-24T00:00:00.000Z",
        status: "failed",
        offsetMs: 0,
        scenes: [
          {
            scene: 1,
            sceneTitle: "ログイン画面",
            status: "failed",
            offsetMs: 0,
            steps: [
              { index: 0, description: "tap #email", status: "passed", offsetMs: 0 },
              { index: 1, description: "tap #btn", status: "failed", offsetMs: 2000 },
            ],
          },
        ],
      },
      {
        scenarioID: "デモ.ログイン.S0020",
        title: "ログアウトできる",
        method: "S0020",
        startedAt: "2026-07-24T00:05:00.000Z",
        status: "passed",
        offsetMs: 0,
        scenes: [],
      },
      {
        scenarioID: "デモ.ログイン.S0030",
        title: "パスワードを変更できる",
        method: "S0030",
        startedAt: "2026-07-24T00:10:00.000Z",
        status: "passed",
        offsetMs: 0,
        scenes: [],
      },
    ],
  },
];

const ERRORS = [
  {
    scenarioID: "デモ.ログイン.S0010",
    scene: 1,
    stepIndex: 1,
    sceneTitle: "ログイン画面",
    description: "assertion failed",
    detail: null,
    worker: "ios:iPhone 16",
    at: "2026-07-24T00:00:02.000Z",
    offsetMs: 2000,
  },
];

const SESSION_MESSAGE = {
  type: "recordingsSession",
  ok: true,
  project: "SampleApp",
  runID: "20260724-000000",
  error: null,
  videos: VIDEOS,
  errors: ERRORS,
  tree: TREE,
};

test("recordingsSession 適用でツリーが class→scenario→scene→step の階層で描画される", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_MESSAGE);

  const tree = window.document.getElementById("recordings-tree");
  const rows = [...tree.querySelectorAll(".recordings-tree-row")];
  const labels = rows.map((r) => r.querySelector(".recordings-tree-label").textContent);
  assert.deepEqual(labels, [
    "デモ.ログイン",
    "ログインできる",
    "ログイン画面",
    "0. tap #email",
    "1. tap #btn",
    "ログアウトできる",
    "パスワードを変更できる",
  ]);

  // 深さは --tree-depth(class=0/scenario=1/scene=2/step=3)。
  assert.equal(rows[0].style.getPropertyValue("--tree-depth"), "0");
  assert.equal(rows[1].style.getPropertyValue("--tree-depth"), "1");
  assert.equal(rows[2].style.getPropertyValue("--tree-depth"), "2");
  assert.equal(rows[3].style.getPropertyValue("--tree-depth"), "3");

  // アイコン class(pass/fail の丸アイコン)。
  assert.ok(rows[0].querySelector(".recordings-tree-icon-failed"), "クラス行は配下に failed があるので failed アイコン");
  assert.ok(rows[1].querySelector(".recordings-tree-icon-failed"), "S0010 は failed");
  assert.ok(rows[3].querySelector(".recordings-tree-icon-passed"), "step0(tap #email)は passed");
  assert.ok(rows[4].querySelector(".recordings-tree-icon-failed"), "step1(tap #btn)は failed");
  assert.ok(rows[5].querySelector(".recordings-tree-icon-passed"), "S0020 は passed");
});

test("録画が無いシナリオはグレーアウト+「録画なし」表示になる(配下も同様)", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_MESSAGE);

  const rows = [...window.document.querySelectorAll("#recordings-tree .recordings-tree-row")];
  const s0010Row = rows.find((r) => r.querySelector(".recordings-tree-label").textContent === "ログインできる");
  const s0020Row = rows.find((r) => r.querySelector(".recordings-tree-label").textContent === "ログアウトできる");

  assert.equal(s0010Row.classList.contains("recordings-tree-row-no-video"), false);
  assert.equal(s0010Row.querySelector(".recordings-tree-no-video-note"), null);

  assert.equal(s0020Row.classList.contains("recordings-tree-row-no-video"), true);
  const note = s0020Row.querySelector(".recordings-tree-no-video-note");
  assert.ok(note, "録画なしシナリオには注記が付く");
  assert.equal(note.textContent, "録画なし");
});

test("ツリー行クリックで選択ハイライト+エラー一覧フィルター、再クリックで解除", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_MESSAGE);

  const rows = [...window.document.querySelectorAll("#recordings-tree .recordings-tree-row")];
  const s0010Row = rows.find((r) => r.querySelector(".recordings-tree-label").textContent === "ログインできる");
  const filterChip = window.document.getElementById("recordings-errors-filter");
  const errorsList = window.document.getElementById("recordings-errors-list");

  assert.equal(filterChip.style.display, "none");

  s0010Row.click();
  assert.equal(s0010Row.classList.contains("recordings-tree-row-selected"), true);
  assert.notEqual(filterChip.style.display, "none");
  assert.equal(errorsList.querySelectorAll(".recordings-error-item").length, 1);

  s0010Row.click();
  assert.equal(s0010Row.classList.contains("recordings-tree-row-selected"), false);
  assert.equal(filterChip.style.display, "none");
});

test("キーボード: 録画タブ・再生ビュー表示中に Space で play/pause が呼ばれる", (t) => {
  const { window, video, sendToWebview, playCalls, pauseCalls } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_MESSAGE);

  assert.equal(video.paused, true, "初期状態は一時停止扱い");
  window.document.dispatchEvent(new window.KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
  assert.equal(playCalls(), 1, "一時停止中の Space は play()");

  window.document.dispatchEvent(new window.KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
  assert.equal(pauseCalls(), 1, "再生中の Space は pause()");
});

test("キーボードは input/select/textarea へフォーカス中なら無視する", (t) => {
  const { window, sendToWebview, playCalls } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_MESSAGE);

  const input = window.document.getElementById("recordings-seek");
  const event = new window.KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true });
  Object.defineProperty(event, "target", { value: input });
  window.document.dispatchEvent(event);
  assert.equal(playCalls(), 0);
});

test("連続再生 ON で 'ended' 発火時に次のテスト(録画ありの次エントリ)の動画へ切り替わる", (t) => {
  const { window, video, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_MESSAGE);

  // 初期選択はセッション内最初のシナリオ(S0010)の動画。
  assert.equal(video.getAttribute("src"), "https://localhost/videos/S0010.mp4");

  const autoAdvance = window.document.getElementById("recordings-auto-advance");
  autoAdvance.checked = true;

  video.dispatchEvent(new window.Event("ended"));

  // S0020(録画なし)は scenarioNav から除外されるため、次は S0030 になる。
  assert.equal(video.getAttribute("src"), "https://localhost/videos/S0030.mp4");
});

test("連続再生 OFF なら 'ended' で動画を切り替えない", (t) => {
  const { window, video, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview(SESSION_MESSAGE);
  assert.equal(video.getAttribute("src"), "https://localhost/videos/S0010.mp4");

  video.dispatchEvent(new window.Event("ended"));
  assert.equal(video.getAttribute("src"), "https://localhost/videos/S0010.mp4");
});

// 切り出し失敗の可視化(Sources/FTCore/RecordingIndex.swift の clipsAttempted/clipsFailed 由来)。
// 全滅した run も一覧に出す契約なので、動画0本のセッションを開いても一覧へ戻さないこと自体が仕様。

test("一覧: clipsFailed>0 のセッション行に欠落チップが出る(0/未指定では出ない)", (t) => {
  const { window, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({
    type: "recordingsSessions",
    sessions: [
      { project: "SampleApp", runID: "20260817-000001", startedAt: "2026-08-17T00:00:01Z",
        passed: 3, failed: 0, clipsAttempted: 5, clipsFailed: 2, encoderFallback: true },
      { project: "SampleApp", runID: "20260817-000002", startedAt: "2026-08-17T00:00:02Z",
        passed: 3, failed: 0, clipsAttempted: 5, clipsFailed: 0, encoderFallback: false },
      { project: "SampleApp", runID: "20260817-000003", startedAt: "2026-08-17T00:00:03Z",
        passed: 3, failed: 0, clipsAttempted: null, clipsFailed: null, encoderFallback: false },
    ],
  });

  const rows = window.document.querySelectorAll(".recordings-session-item");
  assert.equal(rows.length, 3);
  const chipTexts = [...rows].map((row) => {
    const chips = [...row.querySelectorAll(".recordings-session-counts")];
    return chips.map((c) => c.textContent).join("|");
  });
  assert.match(chipTexts[0], /2/, "clipsFailed=2 の行は件数を出す");
  assert.equal(/クリップ/.test(chipTexts[1]), false, "clipsFailed=0 の行には出さない");
  assert.equal(/クリップ/.test(chipTexts[2]), false, "古い index(フィールド無し)でも出さない");
});

test("再生: 動画0本でも一覧へ戻らず、理由と件数を出してプレイヤーを隠す", (t) => {
  const { window, video, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ ...SESSION_MESSAGE, videos: [], clipsAttempted: 3, clipsFailed: 3, encoderFallback: true });

  const playerView = window.document.getElementById("recordings-player-view");
  assert.notEqual(playerView.style.display, "none", "動画が無くても再生ビューに留まる");
  assert.equal(video.style.display, "none", "死んだプレイヤーを見せない");
  const message = window.document.querySelector(".recordings-no-video-message");
  assert.notEqual(message.style.display, "none");
  assert.match(message.textContent, /3/, "失敗件数を出す");
  // ツリーは scenarios/*.json 由来なので動画が無くても描く
  assert.ok(window.document.querySelectorAll(".recordings-tree-row").length > 0);
});

test("再生: 一部だけ欠落しているときはプレイヤーを出したまま注記を添える", (t) => {
  const { window, video, sendToWebview } = createWebview();
  t.after(() => window.close());
  sendToWebview({ ...SESSION_MESSAGE, clipsAttempted: 5, clipsFailed: 2, encoderFallback: true });

  assert.notEqual(video.style.display, "none", "動画があるならプレイヤーは出す");
  const notice = window.document.querySelector(".recordings-clips-failed-notice");
  assert.notEqual(notice.style.display, "none");
  assert.match(notice.textContent, /2/);
  assert.equal(window.document.querySelector(".recordings-no-video-message").style.display, "none");
});

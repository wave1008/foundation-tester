// webviewProfileAutoSave.test.mjs
// プロファイルタブの自動保存(確定ボタンは無い)の DOM E2E(jsdom)。ハーネスの作りは
// webviewRunProfileDeviceMachine.test.mjs と同じ。縛る性質:
// - 保存の契機は change だけ(打鍵ごとの input では送らない)・どの欄の変更も拾う
// - 保存中もコントロールを無効化しない・送信中の変更は応答の後に1本だけ送る
// - 保存結果の反響(同じ値の runProfileData)でフォームを作り直さない(作り直すとフォーカスが外れる)
// - 送信の後で別のデバイスへ移ったら、応答で選択を引き戻さない

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
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" },
    { path: "" },
  );

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

function createWebview(t) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  t.after(() => window.close());
  const posted = [];
  window.acquireVsCodeApi = () => ({ postMessage: (m) => posted.push(m), setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  const send = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  return { window, document: window.document, posted, send };
}

// プロジェクトのデバイスカタログ(全実行プロファイルの devices[] の和集合)。この実行プロファイル
// 自身が持つのは「シミュ1」だけで、「シミュ2」はカタログにしか居ない(チェックすると追加される)。
const PROFILE_INFO = {
  type: "profileInfo",
  projects: ["SampleApp"],
  profiles: ["ios"],
  current: "ios",
  filter: "all",
  apps: ["sampleapp"],
  project: "SampleApp",
  projectDir: "TestProjects/SampleApp",
  devices: [
    { platform: "ios", name: "シミュ1", detail: "d", model: "iPhone 16", osVersion: "iOS 18.0", udid: "U1" },
    { platform: "ios", name: "シミュ2", detail: "d", model: "iPhone 16", osVersion: "iOS 18.0", udid: "U2" },
  ],
};

// parseRunProfileForForm が返す全欄(monitorProfileForms.ts の RunProfileFormFields)。
const RUN_FIELDS = {
  app: "sampleapp",
  devices: [{ platform: "ios", name: "シミュ1", enabled: true, model: "iPhone 16", osVersion: "iOS 18.0", udid: "U1" }],
  heal: true,
  textVisualCheck: true,
  screenLooksLike: true,
  containerInference: true,
  ocrTextVisualCheck: true,
  iosInappEngine: true,
  iosFastInput: false,
  iosPreActionWarmup: true,
  homeOnStart: true,
  playProtectBypass: true,
  enableAnimations: false,
  reportDir: "reports",
  updateWebView: true,
  wipeDataOnBloat: true,
  wipeDataThresholdGB: "",
  recoverCpuFallbackToGpu: false,
  locale: "",
  record: false,
  recordFailuresOnly: false,
  recordBitrateKbps: "",
  recordFullResolution: false,
  workspace: "",
};

function runProfileData(fields) {
  return { type: "runProfileData", profile: "ios", ok: true, error: null, fields };
}

function loadedRunProfile(t) {
  const harness = createWebview(t);
  harness.send(PROFILE_INFO);
  harness.send(runProfileData(RUN_FIELDS));
  harness.posted.length = 0;
  return harness;
}

const saves = (posted) => posted.filter((m) => m.type === "runProfileSave");

function typeAndCommit(window, input, value) {
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  input.dispatchEvent(new window.Event("change", { bubbles: true }));
}

test("確定・キャンセルのボタンは3セクションとも無い", (t) => {
  const { document } = createWebview(t);
  for (const id of ["run-profile-confirm", "run-profile-cancel", "app-profile-confirm", "app-profile-cancel", "editor-confirm", "editor-cancel"]) {
    assert.equal(document.getElementById(id), null, id);
  }
});

test("Advanced Features セクションは heal を先頭に4トグルがフラットに並び、旧親チェックボックス(#run-profile-fm/#run-profile-ocr)は無い", (t) => {
  const { document } = loadedRunProfile(t);
  assert.equal(document.getElementById("run-profile-fm"), null);
  assert.equal(document.getElementById("run-profile-fm-options"), null);
  assert.equal(document.getElementById("run-profile-ocr"), null);
  assert.equal(document.getElementById("run-profile-ocr-options"), null);

  const ids = [
    "run-profile-heal",
    "run-profile-ocr-text-visual-check",
    "run-profile-text-visual-check",
    "run-profile-screen-looks-like",
  ];
  const section = document.getElementById(ids[0]).closest(".run-profile-section-group");
  // 4行とも字下げラッパーの中ではなく、セクション直下の modal-row として並ぶ(フラット)。
  for (const id of ids) {
    const el = document.getElementById(id);
    assert.equal(el.parentElement.classList.contains("profile-checkbox-row"), true);
    assert.equal(el.parentElement.parentElement, section);
  }
  const order = [...section.querySelectorAll("input[type=checkbox]")].map((el) => el.id);
  assert.deepEqual(order, ids);
});

test("チェックボックスは切り替えた時点で保存する(以前は購読漏れで dirty にならなかった欄も)", (t) => {
  const { document, posted } = loadedRunProfile(t);
  // homeOnStart / playProtectBypass / updateWebView は欄ごとの購読から漏れていた3つ
  for (const [id, key] of [
    ["run-profile-home-on-start", "homeOnStart"],
    ["run-profile-play-protect-bypass", "playProtectBypass"],
    ["run-profile-update-webview", "updateWebView"],
  ]) {
    posted.length = 0;
    document.getElementById(id).click();
    const sent = saves(posted);
    assert.equal(sent.length, 1, `${id} の切り替えで保存される`);
    assert.equal(sent[0].fields[key], false);
    // 次の欄の検証のため、応答で送信中を解く
    document.defaultView.dispatchEvent(
      new document.defaultView.MessageEvent("message", { data: { type: "runProfileSaveResult", profile: "ios", ok: true, error: null } }),
    );
  }
});

test("デバイスのチェックだけを切り替えても保存する(参照一覧は change で作り直されるので、その後の値で判定する)", (t) => {
  const { document, posted } = loadedRunProfile(t);
  const boxes = [...document.querySelectorAll('#run-profile-devices input[type="checkbox"]')];
  boxes[1].click();
  const sent = saves(posted);
  assert.equal(sent.length, 1, "デバイスの切り替えが保存されない");
  // realm 違いの deepStrictEqual を避けるため postMessage と同じく構造化して比べる。
  const devices = JSON.parse(JSON.stringify(sent[0].fields.devices)).map((d) => ({ name: d.name, enabled: d.enabled }));
  assert.deepEqual(devices, [
    { name: "シミュ1", enabled: true },
    { name: "シミュ2", enabled: true },
  ]);
});

test("テキストは打鍵ごとには送らず、入力を終えたとき(change)に trim して保存する", (t) => {
  const { window, document, posted } = loadedRunProfile(t);
  const locale = document.getElementById("run-profile-locale");
  locale.value = " ja_J";
  locale.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(saves(posted).length, 0, "入力途中の値を送っている");

  locale.value = " ja_JP ";
  locale.dispatchEvent(new window.Event("change", { bubbles: true }));
  const sent = saves(posted);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].fields.locale, "ja_JP");
  assert.equal(locale.value, "ja_JP", "送った値と画面を揃える(揃えないと保存後も dirty が残る)");
  assert.equal(locale.disabled, false, "保存中に無効化するとフォーカスが外れる");
});

test("Enter でもテキストの入力を終えて保存する", (t) => {
  const { window, document, posted } = loadedRunProfile(t);
  const threshold = document.getElementById("run-profile-wipe-threshold");
  threshold.value = "8";
  threshold.dispatchEvent(new window.Event("input", { bubbles: true }));
  threshold.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  const sent = saves(posted);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].fields.wipeDataThresholdGB, "8");
});

test("検証で弾かれる値は保存せずエラーを出し、直すと保存する", (t) => {
  const { window, document, posted } = loadedRunProfile(t);
  const threshold = document.getElementById("run-profile-wipe-threshold");
  typeAndCommit(window, threshold, "abc");
  assert.equal(saves(posted).length, 0);
  assert.notEqual(document.getElementById("run-profile-error").textContent, "");

  typeAndCommit(window, threshold, "10");
  assert.equal(saves(posted).length, 1);
  assert.equal(saves(posted)[0].fields.wipeDataThresholdGB, "10");
  assert.equal(document.getElementById("run-profile-error").textContent, "");
});

test("送信中の変更は並行に送らず、応答の後に最新の値で1本だけ送る", (t) => {
  const { window, document, posted, send } = loadedRunProfile(t);
  document.getElementById("run-profile-heal").click();
  assert.equal(saves(posted).length, 1);

  document.getElementById("run-profile-screen-looks-like").click();
  typeAndCommit(window, document.getElementById("run-profile-report-dir"), "out");
  assert.equal(saves(posted).length, 1, "応答を待たずに2本目を送っている(後の保存が先に着くと古い値で上書きされる)");

  send({ type: "runProfileSaveResult", profile: "ios", ok: true, error: null });
  const sent = saves(posted);
  assert.equal(sent.length, 2);
  assert.equal(sent[1].fields.heal, false);
  assert.equal(sent[1].fields.screenLooksLike, false);
  assert.equal(sent[1].fields.reportDir, "out");

  send({ type: "runProfileSaveResult", profile: "ios", ok: true, error: null });
  assert.equal(saves(posted).length, 2, "変更が無いのに送り続けている");
});

test("保存の反響(同じ値の runProfileData)ではフォームを作り直さない", (t) => {
  const { document, send } = loadedRunProfile(t);
  const deviceBox = () => document.querySelector('#run-profile-devices input[type="checkbox"]');
  const before = deviceBox();
  document.getElementById("run-profile-heal").click();
  send({ type: "runProfileSaveResult", profile: "ios", ok: true, error: null });
  send(runProfileData({ ...RUN_FIELDS, heal: false }));
  assert.equal(deviceBox(), before, "作り直すと触っている欄からフォーカスが外れる");

  // 値が違う(外部編集)なら作り直して反映する
  send(runProfileData({ ...RUN_FIELDS, heal: false, reportDir: "elsewhere" }));
  assert.equal(document.getElementById("run-profile-report-dir").value, "elsewhere");
});

test("保存に失敗したらエラーを出し、値は画面に残す", (t) => {
  const { window, document, send } = loadedRunProfile(t);
  const reportDir = document.getElementById("run-profile-report-dir");
  typeAndCommit(window, reportDir, "out");
  send({ type: "runProfileSaveResult", profile: "ios", ok: false, error: "書けません" });
  assert.equal(document.getElementById("run-profile-error").textContent, "書けません");
  assert.equal(reportDir.value, "out");
  // 未保存(dirty)なので外部編集の反映で潰さない
  send(runProfileData(RUN_FIELDS));
  assert.equal(reportDir.value, "out");
});

test("Esc は未保存の編集を捨てて読み直す", (t) => {
  const { window, document, posted } = loadedRunProfile(t);
  const threshold = document.getElementById("run-profile-wipe-threshold");
  typeAndCommit(window, threshold, "abc");
  threshold.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.ok(posted.some((m) => m.type === "runProfileLoad" && m.profile === "ios"));
});

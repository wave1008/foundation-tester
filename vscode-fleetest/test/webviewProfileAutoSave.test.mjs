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

const MACHINE_PROFILE_INFO = {
  type: "machineProfileInfo",
  current: "M1",
  error: null,
  machines: [
    {
      name: "M1",
      devices: [
        { name: "シミュ1", platform: "ios", detail: "d", simulator: "iPhone 16", os: "18.0", udid: "U1" },
        { name: "シミュ2", platform: "ios", detail: "d", simulator: "iPhone 16", os: "18.0", udid: "U2" },
      ],
    },
    {
      name: "M2",
      devices: [{ name: "エミュ1", platform: "android", detail: "d", avd: "Pixel_8" }],
    },
  ],
};

const PROFILE_INFO = { type: "profileInfo", profiles: ["ios"], current: "ios", filter: "all", apps: ["sampleapp"], project: "SampleApp" };

// parseRunProfileForForm が返す全欄(monitorProfileForms.ts の RunProfileFormFields)。
const RUN_FIELDS = {
  machine: "M1",
  app: "sampleapp",
  devices: [{ name: "シミュ1" }],
  fm: true,
  heal: true,
  falsePositiveCheck: true,
  screenLooksLike: true,
  triage: true,
  containerInference: true,
  ocr: true,
  ocrFalsePositiveCheck: true,
  iosInappEngine: true,
  iosFastInput: false,
  iosPreActionWarmup: true,
  homeOnStart: true,
  playProtectBypass: true,
  enableAnimations: false,
  reportDir: "reports",
  defaultTimeout: "5",
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
  harness.send(MACHINE_PROFILE_INFO);
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
  assert.deepEqual(JSON.parse(JSON.stringify(sent[0].fields.devices)), [{ name: "シミュ1" }, { name: "シミュ2" }]);
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
  const timeout = document.getElementById("run-profile-default-timeout");
  timeout.value = "8";
  timeout.dispatchEvent(new window.Event("input", { bubbles: true }));
  timeout.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  const sent = saves(posted);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].fields.defaultTimeout, "8");
});

test("検証で弾かれる値は保存せずエラーを出し、直すと保存する", (t) => {
  const { window, document, posted } = loadedRunProfile(t);
  const timeout = document.getElementById("run-profile-default-timeout");
  typeAndCommit(window, timeout, "abc");
  assert.equal(saves(posted).length, 0);
  assert.notEqual(document.getElementById("run-profile-error").textContent, "");

  typeAndCommit(window, timeout, "10");
  assert.equal(saves(posted).length, 1);
  assert.equal(saves(posted)[0].fields.defaultTimeout, "10");
  assert.equal(document.getElementById("run-profile-error").textContent, "");
});

test("マシンを切り替えた直後(前のマシンのデバイスしか選ばれていない)は保存せず、このマシンのデバイスを選ぶと保存する", (t) => {
  const { window, document, posted } = loadedRunProfile(t);
  const machine = document.getElementById("run-profile-machine");
  machine.value = "M2";
  machine.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(saves(posted).length, 0, "monitor/run が noDevicesInMachineProfile で落ちるプロファイルを書いた");
  assert.match(document.getElementById("run-profile-error").textContent, /M2/);

  const emulator = [...document.querySelectorAll('#run-profile-devices input[type="checkbox"]')]
    .find((box) => box.dataset.deviceName === "エミュ1");
  emulator.click();
  const sent = saves(posted);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].fields.machine, "M2");
  assert.ok(sent[0].fields.devices.some((d) => d.name === "エミュ1"));
});

test("送信中の変更は並行に送らず、応答の後に最新の値で1本だけ送る", (t) => {
  const { window, document, posted, send } = loadedRunProfile(t);
  document.getElementById("run-profile-heal").click();
  assert.equal(saves(posted).length, 1);

  document.getElementById("run-profile-triage").click();
  typeAndCommit(window, document.getElementById("run-profile-report-dir"), "out");
  assert.equal(saves(posted).length, 1, "応答を待たずに2本目を送っている(後の保存が先に着くと古い値で上書きされる)");

  send({ type: "runProfileSaveResult", profile: "ios", ok: true, error: null });
  const sent = saves(posted);
  assert.equal(sent.length, 2);
  assert.equal(sent[1].fields.heal, false);
  assert.equal(sent[1].fields.triage, false);
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
  const timeout = document.getElementById("run-profile-default-timeout");
  typeAndCommit(window, timeout, "abc");
  timeout.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.ok(posted.some((m) => m.type === "runProfileLoad" && m.profile === "ios"));
});

test("マシンのデバイス編集: 名前を変えて別の行へ移ったら、保存の応答で選択を引き戻さない", (t) => {
  const { window, document, posted, send } = createWebview(t);
  send(MACHINE_PROFILE_INFO);
  const rows = () => [...document.querySelectorAll("#machine-device-list .machine-device-row")];
  rows()[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  // blur で change → 保存 → そのまま2行目をクリック(自動保存の普通の流れ)
  typeAndCommit(window, document.getElementById("editor-name"), "シミュ1-改");
  assert.equal(posted.filter((m) => m.type === "machineDeviceUpdate").length, 1);
  rows()[1].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(document.getElementById("editor-udid").textContent, "U2");

  send({ type: "machineDeviceUpdateResult", ok: true, name: "シミュ1-改", error: null });
  send({
    ...MACHINE_PROFILE_INFO,
    machines: [{ ...MACHINE_PROFILE_INFO.machines[0], devices: [
      { ...MACHINE_PROFILE_INFO.machines[0].devices[0], name: "シミュ1-改" },
      MACHINE_PROFILE_INFO.machines[0].devices[1],
    ] }],
  });
  assert.equal(document.getElementById("editor-udid").textContent, "U2", "選択が保存した行へ引き戻された");
  assert.equal(rows()[1].classList.contains("selected"), true);
});

test("マシンのデバイス編集: 改名の保存中に確定した変更は、新しい名前で引き当てて送る", (t) => {
  const { window, document, posted, send } = createWebview(t);
  send(MACHINE_PROFILE_INFO);
  document.querySelector("#machine-device-list .machine-device-row").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  typeAndCommit(window, document.getElementById("editor-name"), "シミュ1-改");
  typeAndCommit(window, document.getElementById("editor-port"), "8200");
  const updates = () => posted.filter((m) => m.type === "machineDeviceUpdate");
  assert.equal(updates().length, 1);

  send({ type: "machineDeviceUpdateResult", ok: true, name: "シミュ1-改", error: null });
  assert.equal(updates().length, 2);
  assert.equal(updates()[1].originalName, "シミュ1-改", "旧名で引くとホストが見つけられない");
  assert.equal(updates()[1].fields.port, "8200");
});

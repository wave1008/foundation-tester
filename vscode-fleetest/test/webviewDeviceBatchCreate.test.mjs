// webviewDeviceBatchCreate.test.mjs
// 「デバイスを追加」左下のバッチ作成(modals.js)の DOM テスト。harness は
// webviewDeviceAddModal.test.mjs と同じ(実 HTML + 実バンドルを jsdom で動かす)。
//
// 守るのは4つ:
//   ①送る名前が「デバイス名-連番2桁・-01 始まり」であること(表示と作られる名前がズレると上書き確認が嘘になる)
//   ②台数の範囲(1-99)を **JS でも** 弾くこと(number 入力は手打ちで範囲外を通す)
//   ③衝突している名前だけ overwriteNames に載ること(ホスト側の上書き確認の入力そのもの)
//   ④開始→進行→完了→OK で「デバイスを選択」へ戻り、**作成できた台すべて**にチェックが入ること

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
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

function click(window, el) {
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

const READY_CATALOG = {
  android: {
    available: true,
    error: null,
    errorCode: null,
    models: [{ id: "pixel_9", name: "Pixel 9" }],
    systemImages: [{
      abi: "arm64-v8a", apiLevel: 36, package: "system-images;android-36;google_apis;arm64-v8a",
      tag: "google_apis", versionName: "Android 16",
    }],
  },
  ios: {
    available: true,
    error: null,
    deviceTypes: [{
      identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
      name: "iPhone 17 Pro", productFamily: "iPhone",
    }],
    runtimes: [{
      identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", name: "iOS 27.0", version: "27.0",
    }],
  },
};

/** installedDevices の応答(実体として存在するデバイス一覧)。衝突判定の入力になる */
function installedDevices(iosDevices) {
  return {
    type: "installedDevices",
    ok: true,
    error: null,
    data: {
      ios: { available: true, error: null, devices: iosDevices, physicalDevices: [] },
      android: { available: true, error: null, avds: [], physicalDevices: [] },
    },
  };
}

/** 「デバイスを選択」→「+」で追加ダイアログまで開き、カタログを流し込む */
function openAddModal(window, document, devices = []) {
  post(window, { type: "machineProfileInfo", machines: [{ name: "M1", devices: [] }], current: "M1", error: null });
  click(window, document.getElementById("btn-device-add-existing"));
  post(window, installedDevices(devices));
  click(window, document.getElementById("device-pick-ios-add-new"));
  post(window, { type: "deviceCatalog", ok: true, catalog: READY_CATALOG, error: null });
}

function batchNames(document) {
  return [...document.querySelectorAll("#device-batch-list .device-batch-row .device-batch-name")]
    .map((el) => el.textContent);
}

function batchStates(document) {
  return [...document.querySelectorAll("#device-batch-list .device-batch-row .device-batch-state")]
    .map((el) => el.textContent);
}

test("既定は2台で、「デバイス名-連番2桁(-01 始まり)」の名前を batchCreateDevices で送る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openAddModal(window, document);
  assert.equal(document.getElementById("dlg-batch-count").value, "2", "既定の台数");

  click(window, document.getElementById("dlg-batch"));

  const message = posted.find((m) => m.type === "batchCreateDevices");
  assert.ok(message, "batchCreateDevices を送る");
  assert.deepEqual(Array.from(message.names), ["iPhone 17 Pro(iOS 27.0)-01", "iPhone 17 Pro(iOS 27.0)-02"]);
  assert.equal(message.platform, "ios");
  assert.equal(message.machine, "M1");
  assert.deepEqual(Array.from(message.overwriteNames), [], "衝突が無ければ空");
});

test("台数は 1-99 の外だと送らずエラーを出す(number 入力の min/max に任せない)", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openAddModal(window, document);
  const count = document.getElementById("dlg-batch-count");
  for (const bad of ["0", "100", "", "3.5", "abc"]) {
    count.value = bad;
    click(window, document.getElementById("dlg-batch"));
    assert.equal(
      posted.filter((m) => m.type === "batchCreateDevices").length, 0,
      `"${bad}" は送らない`,
    );
    assert.notEqual(document.getElementById("dlg-error").textContent, "", `"${bad}" で理由を出す`);
  }
  count.value = "99";
  click(window, document.getElementById("dlg-batch"));
  const message = posted.find((m) => m.type === "batchCreateDevices");
  assert.equal(message.names.length, 99, "上限ちょうどは通る");
  assert.equal(message.names[0], "iPhone 17 Pro(iOS 27.0)-01", "先頭は -01");
  assert.equal(message.names[98], "iPhone 17 Pro(iOS 27.0)-99", "末尾は -99(2桁に収まる)");
});

test("既存と同名になるぶんだけ overwriteNames に載る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openAddModal(window, document, [
    { name: "iPhone 17 Pro(iOS 27.0)-02", udid: "SIM-1", os: "27.0" },
  ]);
  document.getElementById("dlg-batch-count").value = "3";
  click(window, document.getElementById("dlg-batch"));

  const message = posted.find((m) => m.type === "batchCreateDevices");
  assert.deepEqual(Array.from(message.names), [
    "iPhone 17 Pro(iOS 27.0)-01", "iPhone 17 Pro(iOS 27.0)-02", "iPhone 17 Pro(iOS 27.0)-03",
  ]);
  assert.deepEqual(Array.from(message.overwriteNames), ["iPhone 17 Pro(iOS 27.0)-02"], "衝突した1台だけ");
});

test("開始で追加ダイアログが閉じて進行窓が開き、進行→完了で OK が押せるようになる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  openAddModal(window, document);
  click(window, document.getElementById("dlg-batch"));
  const names = ["dev01", "dev02"];
  post(window, { type: "batchCreateStarted", names });

  assert.ok(!document.getElementById("device-add-overlay").classList.contains("visible"), "追加ダイアログは閉じる");
  const overlay = document.getElementById("device-batch-overlay");
  assert.ok(overlay.classList.contains("visible"), "進行窓が開く");
  assert.deepEqual(batchNames(document), Array.from(names));
  const ok = document.getElementById("device-batch-ok");
  assert.equal(ok.disabled, true, "終わるまで OK は押せない");

  post(window, { type: "batchCreateProgress", index: 0, name: "dev01", state: "running", error: null });
  assert.match(batchStates(document)[0], /作成中/);
  post(window, { type: "batchCreateProgress", index: 0, name: "dev01", state: "ok", error: null });
  post(window, { type: "batchCreateProgress", index: 1, name: "dev02", state: "failed", error: "boom" });
  assert.match(batchStates(document)[1], /boom/, "失敗は理由まで出す");

  post(window, {
    type: "batchCreateFinished",
    started: true,
    created: [{ name: "dev01", udid: "SIM-A", avd: null }],
    failed: [{ name: "dev02", error: "boom" }],
    error: null,
  });
  assert.equal(ok.disabled, false, "完了で OK が押せる");
});

test("OK で「デバイスを選択」へ戻り、作成できた台すべてにチェックが入る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openAddModal(window, document);
  click(window, document.getElementById("dlg-batch"));
  post(window, { type: "batchCreateStarted", names: ["dev01", "dev02"] });
  post(window, {
    type: "batchCreateFinished",
    started: true,
    created: [
      { name: "dev01", udid: "SIM-A", avd: null },
      { name: "dev02", udid: "SIM-B", avd: null },
    ],
    failed: [],
    error: null,
  });

  const before = posted.filter((m) => m.type === "installedDevicesRequest").length;
  click(window, document.getElementById("device-batch-ok"));
  assert.ok(!document.getElementById("device-batch-overlay").classList.contains("visible"), "進行窓は閉じる");
  assert.equal(
    posted.filter((m) => m.type === "installedDevicesRequest").length, before + 1,
    "「デバイスを選択」の一覧を取り直す",
  );

  post(window, installedDevices([
    { name: "dev01", udid: "SIM-A", os: "27.0" },
    { name: "dev02", udid: "SIM-B", os: "27.0" },
    { name: "無関係", udid: "SIM-C", os: "27.0" },
  ]));

  const rows = [...document.querySelectorAll("#device-pick-ios-body .device-pick-row")];
  const checked = rows
    .filter((row) => row.querySelector("input[type=checkbox]").checked)
    .map((row) => row.textContent);
  assert.equal(checked.length, 2, "作成した2台だけチェックが入る");
  // 一覧は数百行になり得るので、チェックだけでは「作ったのに出てこない」と読める
  assert.equal(
    rows.filter((row) => row.classList.contains("just-created")).length, 2,
    "作った行に印が付く",
  );
  assert.ok(checked.every((label) => label.includes("dev0")), `checked=${JSON.stringify(checked)}`);
});

test("確認をキャンセルされたら(started:false)追加ダイアログを操作できる状態へ戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  openAddModal(window, document);
  click(window, document.getElementById("dlg-batch"));
  assert.equal(document.getElementById("dlg-ok").disabled, true, "確認中は固める");

  post(window, {
    type: "batchCreateFinished",
    started: false,
    created: [],
    failed: [],
    error: "作成をキャンセルしました。",
  });

  assert.ok(document.getElementById("device-add-overlay").classList.contains("visible"), "追加ダイアログは開いたまま");
  assert.ok(!document.getElementById("device-batch-overlay").classList.contains("visible"), "進行窓は開かない");
  assert.equal(document.getElementById("dlg-ok").disabled, false, "OK が押せる状態に戻る");
  assert.equal(document.getElementById("dlg-batch").disabled, false, "バッチ作成も押せる状態に戻る");
  assert.match(document.getElementById("dlg-error").textContent, /キャンセル/);
});

test("進行窓は「デバイスを選択」より上に重なる(z-index の帯を固定する)", () => {
  // jsdom は webview URI 経由の CSS を読まないので、**ソースの宣言を読む**。
  // 既定(.modal-overlay の 2000)のままだと後ろの DOM が勝ち、進行窓が
  // 「デバイスを選択」の背後に隠れる ―― 作成は成功しているのに何も見えない(2026-08-25 の実害)
  const css = fs.readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");
  const zIndexOf = (selector) => {
    const match = css.match(new RegExp(`\\${selector}\\s*\\{[^}]*z-index:\\s*(\\d+)`));
    assert.ok(match, `${selector} の z-index が見つからない`);
    return Number(match[1]);
  };
  const base = zIndexOf(".modal-overlay");
  const add = zIndexOf("#device-add-overlay");
  const batch = zIndexOf("#device-batch-overlay");
  assert.ok(batch > base, `進行窓(${batch})は .modal-overlay(${base})より上`);
  assert.ok(batch > add, `進行窓(${batch})は「デバイスを追加」(${add})より上`);
});

test("進行窓が出ている間の Esc は「デバイスを選択」を閉じない(手前だけが食う)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  openAddModal(window, document);
  click(window, document.getElementById("dlg-batch"));
  post(window, { type: "batchCreateStarted", names: ["dev01", "dev02"] });

  const esc = () => document.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
  );
  esc(); // 作成中: 何も閉じない
  assert.ok(document.getElementById("device-batch-overlay").classList.contains("visible"), "進行窓は残る");
  assert.ok(document.getElementById("device-pick-overlay").classList.contains("visible"), "奥も閉じない");

  post(window, {
    type: "batchCreateFinished",
    started: true,
    created: [{ name: "dev01", udid: "SIM-A", avd: null }],
    failed: [],
    error: null,
  });
  esc(); // 完了後: OK と同じ扱いで進行窓だけ閉じる
  assert.ok(!document.getElementById("device-batch-overlay").classList.contains("visible"), "進行窓は閉じる");
  assert.ok(document.getElementById("device-pick-overlay").classList.contains("visible"), "「デバイスを選択」は開いたまま");
});

test("OK を押す前に別経路の installedDevices が届いても、自動チェックは使い切られない", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  openAddModal(window, document);
  click(window, document.getElementById("dlg-batch"));
  post(window, { type: "batchCreateStarted", names: ["dev01", "dev02"] });
  post(window, {
    type: "batchCreateFinished",
    started: true,
    created: [
      { name: "dev01", udid: "SIM-A", avd: null },
      { name: "dev02", udid: "SIM-B", avd: null },
    ],
    failed: [],
    error: null,
  });

  // machineProfilesTab の機種/OS 取得など、**こちらが投げていない再取得**の応答。
  // ここで自動チェックを使い切ると、OK の再取得で行が作り直されてチェックが消える(実害)
  post(window, installedDevices([
    { name: "dev01", udid: "SIM-A", os: "27.0" },
    { name: "dev02", udid: "SIM-B", os: "27.0" },
  ]));

  click(window, document.getElementById("device-batch-ok"));
  post(window, installedDevices([
    { name: "dev01", udid: "SIM-A", os: "27.0" },
    { name: "dev02", udid: "SIM-B", os: "27.0" },
    { name: "無関係", udid: "SIM-C", os: "27.0" },
  ]));

  const checked = [...document.querySelectorAll("#device-pick-ios-body .device-pick-row")]
    .filter((row) => row.querySelector("input[type=checkbox]").checked);
  assert.equal(checked.length, 2, "OK 後の一覧でもチェックが入っている");
});

test("一覧にまだ出ていない台のぶんは持ち越す(次の再描画で入る)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  openAddModal(window, document);
  click(window, document.getElementById("dlg-batch"));
  post(window, { type: "batchCreateStarted", names: ["dev01"] });
  post(window, {
    type: "batchCreateFinished",
    started: true,
    created: [{ name: "dev01", udid: "SIM-A", avd: null }],
    failed: [],
    error: null,
  });
  click(window, document.getElementById("device-batch-ok"));

  // 取得の行き違いで、作った台がまだ載っていない一覧が返ってきた場合
  post(window, installedDevices([{ name: "無関係", udid: "SIM-C", os: "27.0" }]));
  assert.equal(
    [...document.querySelectorAll("#device-pick-ios-body .device-pick-row")]
      .filter((row) => row.querySelector("input[type=checkbox]").checked).length,
    0,
  );

  post(window, installedDevices([
    { name: "無関係", udid: "SIM-C", os: "27.0" },
    { name: "dev01", udid: "SIM-A", os: "27.0" },
  ]));
  const checked = [...document.querySelectorAll("#device-pick-ios-body .device-pick-row")]
    .filter((row) => row.querySelector("input[type=checkbox]").checked);
  assert.equal(checked.length, 1, "次の再描画でチェックが入る");
});

test("続けてデバイスを作っても、まだ OK していないチェックは残る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  // 1回目のバッチ: dev-01 を作ってチェックが入る
  openAddModal(window, document);
  click(window, document.getElementById("dlg-batch"));
  post(window, { type: "batchCreateStarted", names: ["dev-01"] });
  post(window, {
    type: "batchCreateFinished",
    started: true,
    created: [{ name: "dev-01", udid: "SIM-A", avd: null }],
    failed: [],
    error: null,
  });
  click(window, document.getElementById("device-batch-ok"));
  post(window, installedDevices([{ name: "dev-01", udid: "SIM-A", os: "27.0" }]));

  // 手でもう1台チェックしておく(登録済みでは無いので「まだ OK していない編集」)
  post(window, installedDevices([
    { name: "dev-01", udid: "SIM-A", os: "27.0" },
    { name: "既存", udid: "SIM-X", os: "27.0" },
  ]));
  const manual = [...document.querySelectorAll("#device-pick-ios-body .device-pick-row")]
    .find((row) => row.textContent.includes("既存"));
  manual.querySelector("input[type=checkbox]").click();

  // 2回目のバッチ: 一覧が作り直される
  click(window, document.getElementById("device-pick-ios-add-new"));
  post(window, { type: "deviceCatalog", ok: true, catalog: READY_CATALOG, error: null });
  click(window, document.getElementById("dlg-batch"));
  post(window, { type: "batchCreateStarted", names: ["dev-02"] });
  post(window, {
    type: "batchCreateFinished",
    started: true,
    created: [{ name: "dev-02", udid: "SIM-B", avd: null }],
    failed: [],
    error: null,
  });
  click(window, document.getElementById("device-batch-ok"));
  post(window, installedDevices([
    { name: "dev-01", udid: "SIM-A", os: "27.0" },
    { name: "既存", udid: "SIM-X", os: "27.0" },
    { name: "dev-02", udid: "SIM-B", os: "27.0" },
  ]));

  const checked = [...document.querySelectorAll("#device-pick-ios-body .device-pick-row")]
    .filter((row) => row.querySelector("input[type=checkbox]").checked)
    .map((row) => row.textContent);
  assert.equal(checked.length, 3, `1回目の作成分・手作業のチェック・2回目の作成分が全部残る: ${JSON.stringify(checked)}`);
});

test("外したチェックも再描画で戻らない(両方向に効く)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  // 登録済み(= 初期チェック ON)のデバイスを1台用意する
  post(window, {
    type: "machineProfileInfo",
    machines: [{ name: "M1", devices: [{ platform: "ios", name: "登録済み", udid: "SIM-R" }] }],
    current: "M1",
    error: null,
  });
  click(window, document.getElementById("btn-device-add-existing"));
  post(window, installedDevices([{ name: "登録済み", udid: "SIM-R", os: "27.0" }]));

  const row = document.querySelector("#device-pick-ios-body .device-pick-row");
  const checkbox = row.querySelector("input[type=checkbox]");
  assert.equal(checkbox.checked, true, "登録済みなので初期はチェック ON");
  checkbox.click(); // 登録解除するつもりで外す(まだ OK していない)

  post(window, installedDevices([{ name: "登録済み", udid: "SIM-R", os: "27.0" }]));
  const after = document.querySelector("#device-pick-ios-body .device-pick-row input[type=checkbox]");
  assert.equal(after.checked, false, "再描画で ON に戻らない");
});

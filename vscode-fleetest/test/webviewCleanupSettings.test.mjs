// webviewCleanupSettings.test.mjs
// 設定タブ「クリーンアップ」(settingsTab.js)の往復テスト。実 HTML+実バンドルで動かす方式は
// webviewDevicesTabVisible.test.mjs と同じ。
//
// 縛るのは3つ:
// - **画面は GB / MB、契約はバイト**。変換は retentionModel.js の1経路だけを通り、往復で値が変わらない
// - **不正値(空欄・負・非数)は null**(CLI 側を既定へ戻す)+ 入力欄に既定値を入れ直す。
//   **0 は有効な指定**(保持しない)なので 0 として送る
// - webview が送る payload が拡張側の最終ゲート(isMonitorFromWebviewMessage)を通る
//   —— 片側だけ鍵を変えるとメッセージごと捨てられ、打った値が黙って届かなくなる

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorModel";
import {
  BYTES_PER_GB,
  BYTES_PER_MB,
  RETENTION_FIELDS,
  bytesToUnitValue,
  formatBytes,
  parseRetentionInput,
  unitValueToBytes,
} from "../src/retentionModel";

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
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({
    postMessage: (message) => posted.push(message),
    setState: () => {},
    getState: () => undefined,
  });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document, posted };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function change(window, input, value) {
  input.value = value;
  input.dispatchEvent(new window.Event("change", { bubbles: true }));
}

// CLI(`fleetest api retention`)の応答そのままの形。**既定値は拡張側に持たない**ので、
// テストもこの応答だけを入力にする。
const RESPONSE = {
  type: "retention",
  policy: {
    deviceCapturesMaxBytes: 21474836480,
    recordingsMaxBytes: 107374182400,
    reportsMaxBytes: 1048576000,
    logsMaxBytes: 524288000,
    sweepAfterRun: true,
  },
  defaults: {
    deviceCapturesMaxBytes: 21474836480,
    recordingsMaxBytes: 107374182400,
    reportsMaxBytes: 1048576000,
    logsMaxBytes: 524288000,
    sweepAfterRun: true,
  },
  usage: { deviceCaptures: 934000000000, recordings: 2900000000, reports: 1430000000, logs: 7340032 },
};

const INPUT_IDS = {
  deviceCapturesMaxBytes: "settings-cleanup-device-captures",
  recordingsMaxBytes: "settings-cleanup-recordings",
  reportsMaxBytes: "settings-cleanup-reports",
  logsMaxBytes: "settings-cleanup-logs",
};

test("単位変換は往復で値が変わらない(GB/MB ⇄ バイト)", () => {
  for (const field of RETENTION_FIELDS) {
    const factor = field.unit === "GB" ? BYTES_PER_GB : BYTES_PER_MB;
    for (const shown of [0, 0.5, 2.5, 20, 100, 1000]) {
      const bytes = unitValueToBytes(shown, field.unit);
      assert.equal(bytes, Math.round(shown * factor), `${field.key}: ${String(shown)} ${field.unit} をバイトへ`);
      assert.equal(bytesToUnitValue(bytes, field.unit), shown, `${field.key}: バイトから戻す`);
    }
  }
  // CLI が返す既定値(バイト)も、画面に出して打ち直しても同じバイト数に戻る
  for (const field of RETENTION_FIELDS) {
    const bytes = RESPONSE.defaults[field.key];
    assert.equal(unitValueToBytes(bytesToUnitValue(bytes, field.unit), field.unit), bytes, field.key);
  }
});

test("入力の判定: 0 は有効・負と非数と空欄だけが不正", () => {
  assert.equal(parseRetentionInput("0"), 0, "0 は「保持しない」の有効な指定");
  assert.equal(parseRetentionInput("2.5"), 2.5, "parseInt で 2 に切り詰めない");
  assert.equal(parseRetentionInput(" 20 "), 20);
  assert.equal(parseRetentionInput(""), null);
  assert.equal(parseRetentionInput("-1"), null);
  assert.equal(parseRetentionInput("abc"), null);
  assert.equal(parseRetentionInput("Infinity"), null);
});

test("クリーンアップ: CLI の実効値が入力欄と使用量に入る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, RESPONSE);

  assert.equal(document.getElementById(INPUT_IDS.deviceCapturesMaxBytes).value, "20", "20 GB");
  assert.equal(document.getElementById(INPUT_IDS.recordingsMaxBytes).value, "100", "100 GB");
  assert.equal(document.getElementById(INPUT_IDS.reportsMaxBytes).value, "1000", "1000 MB");
  assert.equal(document.getElementById(INPUT_IDS.logsMaxBytes).value, "500", "500 MB");
  assert.equal(document.getElementById("settings-cleanup-enabled").checked, true);

  const usage = document.getElementById(`${INPUT_IDS.deviceCapturesMaxBytes}-usage`).textContent;
  assert.ok(
    usage.includes(formatBytes(RESPONSE.usage.deviceCaptures, "GB")),
    `使用量は行の単位で出す: ${usage}`,
  );
  const logsUsage = document.getElementById(`${INPUT_IDS.logsMaxBytes}-usage`).textContent;
  assert.ok(logsUsage.includes(formatBytes(RESPONSE.usage.logs, "MB")), `MB の行: ${logsUsage}`);
});

test("クリーンアップ: 入力した上限はバイトで送られ、ゲートを通る", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);
  posted.length = 0;

  change(window, document.getElementById(INPUT_IDS.deviceCapturesMaxBytes), "10");
  change(window, document.getElementById(INPUT_IDS.logsMaxBytes), "250");

  const messages = posted.filter((m) => m?.type === "setRetention");
  assert.equal(messages.length, 2);
  assert.equal(messages[0].patch.deviceCapturesMaxBytes, 10 * BYTES_PER_GB);
  assert.equal(messages[1].patch.logsMaxBytes, 250 * BYTES_PER_MB);
  for (const message of messages) {
    assert.equal(isMonitorFromWebviewMessage(message), true, "拡張側の最終ゲートを通る");
  }
});

test("クリーンアップ: 0 は 0 として送る(null に丸めない)", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);
  posted.length = 0;

  const input = document.getElementById(INPUT_IDS.reportsMaxBytes);
  change(window, input, "0");

  const messages = posted.filter((m) => m?.type === "setRetention");
  assert.equal(messages.length, 1);
  assert.equal(messages[0].patch.reportsMaxBytes, 0, "「保持しない」は有効な指定");
  assert.equal(input.value, "0", "入力欄も 0 のまま(既定へ戻さない)");
  assert.equal(isMonitorFromWebviewMessage(messages[0]), true);
});

test("クリーンアップ: 空欄・負・非数は null を送り入力欄に既定値を入れ直す", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);
  const input = document.getElementById(INPUT_IDS.recordingsMaxBytes);

  for (const raw of ["", "-3", "abc"]) {
    posted.length = 0;
    change(window, input, raw);

    const messages = posted.filter((m) => m?.type === "setRetention");
    assert.equal(messages.length, 1, `"${raw}" で1件送る`);
    assert.equal(messages[0].patch.recordingsMaxBytes, null, `"${raw}" は既定へ戻す`);
    assert.equal(input.value, "100", `"${raw}" は入力欄に既定値(100 GB)を入れ直す`);
    assert.equal(isMonitorFromWebviewMessage(messages[0]), true);
  }
});

test("クリーンアップ: トグルの切替が setRetention として送られる", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);
  posted.length = 0;

  const checkbox = document.getElementById("settings-cleanup-enabled");
  checkbox.checked = false;
  checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));

  const messages = posted.filter((m) => m?.type === "setRetention");
  assert.equal(messages.length, 1);
  assert.equal(messages[0].patch.sweepAfterRun, false);
  assert.equal(isMonitorFromWebviewMessage(messages[0]), true);
});

test("クリーンアップ: 「今すぐ掃除」は runCleanup を送り、確認はホスト側に委ねる", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);
  posted.length = 0;

  document.getElementById("settings-cleanup-now").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

  const messages = posted.filter((m) => m?.type === "runCleanup");
  assert.equal(messages.length, 1);
  assert.equal(messages[0].dryRun, false, "見積もりも確認もホスト側が撃つ");
  assert.equal(isMonitorFromWebviewMessage(messages[0]), true);
});

test("クリーンアップ: 掃除の進行と結果が行に出る(実行中はボタンを押せない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);

  post(window, { type: "retention", cleanup: { state: "running", dryRun: false } });
  assert.equal(document.getElementById("settings-cleanup-now").disabled, true);

  post(window, { ...RESPONSE, cleanup: { state: "done", dryRun: false, freedBytes: 3 * BYTES_PER_GB } });
  assert.equal(document.getElementById("settings-cleanup-now").disabled, false);
  assert.ok(document.getElementById("settings-cleanup-result").textContent.includes("3 GB"));

  post(window, { type: "retention", cleanup: { state: "cancelled" } });
  assert.notEqual(document.getElementById("settings-cleanup-result").textContent, "");
});

test("クリーンアップ: policy が読めなければ欄を無効にして理由を出す(古い CLI)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "retention", error: "unknown subcommand: retention" });

  assert.equal(document.getElementById("settings-cleanup-enabled").disabled, true);
  assert.equal(document.getElementById("settings-cleanup-now").disabled, true);
  for (const id of Object.values(INPUT_IDS)) {
    assert.equal(document.getElementById(id).disabled, true, id);
  }
  const error = document.getElementById("settings-cleanup-error");
  assert.equal(error.hidden, false);
  assert.ok(error.textContent.includes("unknown subcommand: retention"), error.textContent);
});

test("クリーンアップ: 保存に失敗しても欄は使えるまま理由だけ出す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { ...RESPONSE, error: "permission denied" });

  assert.equal(document.getElementById(INPUT_IDS.logsMaxBytes).disabled, false);
  const error = document.getElementById("settings-cleanup-error");
  assert.equal(error.hidden, false);
  assert.ok(error.textContent.includes("permission denied"), error.textContent);
});

test("クリーンアップ: 使用量は後から届く(上限だけ先に出す2段読み)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  // 1段目: CLI は `--usage` 無しで呼ばれ、usage は鍵ごと null(= 測っていない)
  post(window, {
    type: "retention",
    policy: RESPONSE.policy,
    defaults: RESPONSE.defaults,
    usage: { deviceCaptures: null, recordings: null, reports: null, logs: null },
  });
  // 上限はもう入っている(空欄で待たせない)
  assert.equal(
    document.getElementById(INPUT_IDS.logsMaxBytes).value,
    String(RESPONSE.policy.logsMaxBytes / 1024 / 1024),
  );
  const before = document.getElementById(`${INPUT_IDS.logsMaxBytes}-usage`).textContent;
  assert.ok(!before.includes(formatBytes(RESPONSE.usage.logs, "MB")), `測る前: ${before}`);

  // 2段目: `--usage` 付きの読み直しが届くと、同じ行が使用量で埋まる
  post(window, RESPONSE);
  const after = document.getElementById(`${INPUT_IDS.logsMaxBytes}-usage`).textContent;
  assert.ok(after.includes(formatBytes(RESPONSE.usage.logs, "MB")), `測った後: ${after}`);
});

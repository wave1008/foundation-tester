// webviewCleanupSettings.test.mjs
// 設定タブ「ログ・録画」のクリーンアップ欄(settingsTab.js)の往復テスト。実 HTML+実バンドルで動かす方式は
// webviewDevicesTabVisible.test.mjs と同じ。
//
// 縛るのは3つ:
// - **画面は GB / MB、契約はバイト**。変換は retentionModel.ts の1経路だけを通り、往復で値が変わらない
// - **欄に入るのは明示設定(configured)だけ**。未設定は空欄 + 既定値のプレースホルダ。
//   **不正値(空欄・負・非数)は null**(CLI 側を既定へ戻す)+ 入力欄を空欄にする。
//   **最小値(CLI の minimums)未満は最小値へ引き上げて送る**(CLI は未満を断る)
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
  parseRetentionResponse,
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
    xcresultMaxBytes: 5368709120,
    sweepAfterRun: true,
  },
  // 明示設定。recordings と xcresult は未設定(null)= 空欄 + 既定のプレースホルダ
  configured: {
    deviceCapturesMaxBytes: 21474836480,
    recordingsMaxBytes: null,
    reportsMaxBytes: 1048576000,
    logsMaxBytes: 524288000,
    xcresultMaxBytes: null,
    sweepAfterRun: true,
  },
  defaults: {
    deviceCapturesMaxBytes: 21474836480,
    recordingsMaxBytes: 107374182400,
    reportsMaxBytes: 1048576000,
    logsMaxBytes: 524288000,
    xcresultMaxBytes: 5368709120,
    sweepAfterRun: true,
  },
  // CLI の RetentionPolicy.min…(1 GB / 2 GB / 100 MB / 10 MB / 1 GB)
  minimums: {
    deviceCapturesMaxBytes: 1073741824,
    recordingsMaxBytes: 2147483648,
    reportsMaxBytes: 104857600,
    logsMaxBytes: 10485760,
    xcresultMaxBytes: 1073741824,
  },
  usage: {
    deviceCaptures: 934000000000,
    recordings: 2900000000,
    reports: 1430000000,
    logs: 7340032,
    xcresult: 1200000000,
  },
};

const INPUT_IDS = {
  deviceCapturesMaxBytes: "settings-cleanup-device-captures",
  recordingsMaxBytes: "settings-cleanup-recordings",
  reportsMaxBytes: "settings-cleanup-reports",
  logsMaxBytes: "settings-cleanup-logs",
  xcresultMaxBytes: "settings-cleanup-xcresult",
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

test("クリーンアップ: 明示設定は入力欄に入り、未設定は空欄 + 既定のプレースホルダ・使用量も入る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, RESPONSE);

  assert.equal(document.getElementById(INPUT_IDS.deviceCapturesMaxBytes).value, "20", "20 GB");
  assert.equal(document.getElementById(INPUT_IDS.reportsMaxBytes).value, "1000", "1000 MB");
  assert.equal(document.getElementById(INPUT_IDS.logsMaxBytes).value, "500", "500 MB");
  const recordings = document.getElementById(INPUT_IDS.recordingsMaxBytes);
  assert.equal(recordings.value, "", "未設定は値を入れない(実効値で埋めない)");
  assert.equal(recordings.placeholder, "100", "既定値(100 GB)はプレースホルダに出す");
  const xcresult = document.getElementById(INPUT_IDS.xcresultMaxBytes);
  assert.equal(xcresult.value, "");
  assert.equal(xcresult.placeholder, "5");
  assert.equal(document.getElementById("settings-cleanup-enabled").checked, true);

  const usage = document.getElementById(`${INPUT_IDS.deviceCapturesMaxBytes}-usage`).textContent;
  assert.ok(
    usage.includes(formatBytes(RESPONSE.usage.deviceCaptures, "GB")),
    `使用量は行の単位で出す: ${usage}`,
  );
  const logsUsage = document.getElementById(`${INPUT_IDS.logsMaxBytes}-usage`).textContent;
  assert.ok(logsUsage.includes(formatBytes(RESPONSE.usage.logs, "MB")), `MB の行: ${logsUsage}`);
  const xcresultUsage = document.getElementById(`${INPUT_IDS.xcresultMaxBytes}-usage`).textContent;
  assert.ok(xcresultUsage.includes(formatBytes(RESPONSE.usage.xcresult, "GB")), `GB の行: ${xcresultUsage}`);
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

test("クリーンアップ: 最小値未満(0 を含む)は最小値へ引き上げて送り、欄の下限も最小値", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);

  const cases = [
    [INPUT_IDS.deviceCapturesMaxBytes, "1"],
    [INPUT_IDS.recordingsMaxBytes, "2"],
    [INPUT_IDS.reportsMaxBytes, "100"],
    [INPUT_IDS.logsMaxBytes, "10"],
    [INPUT_IDS.xcresultMaxBytes, "1"],
  ];
  for (const [id, minShown] of cases) {
    const input = document.getElementById(id);
    const key = Object.keys(INPUT_IDS).find((k) => INPUT_IDS[k] === id);
    assert.equal(input.min, minShown, `${id}: 欄の下限`);
    for (const raw of ["0", String(Number(minShown) / 2)]) {
      posted.length = 0;
      change(window, input, raw);
      const messages = posted.filter((m) => m?.type === "setRetention");
      assert.equal(messages.length, 1);
      assert.equal(messages[0].patch[key], RESPONSE.minimums[key], `${id}: "${raw}" は最小値で送る`);
      assert.equal(input.value, minShown, `${id}: 欄にも最小値を入れ直す`);
      assert.equal(isMonitorFromWebviewMessage(messages[0]), true);
    }
    // ちょうど最小値はそのまま
    posted.length = 0;
    change(window, input, minShown);
    assert.equal(posted.filter((m) => m?.type === "setRetention")[0].patch[key], RESPONSE.minimums[key]);
  }
});

test("クリーンアップ: 空欄・負・非数は null を送り入力欄を空欄にする", (t) => {
  const { window, document, posted } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);
  const input = document.getElementById(INPUT_IDS.deviceCapturesMaxBytes);

  for (const raw of ["", "-3", "abc"]) {
    posted.length = 0;
    change(window, input, raw);

    const messages = posted.filter((m) => m?.type === "setRetention");
    assert.equal(messages.length, 1, `"${raw}" で1件送る`);
    assert.equal(messages[0].patch.deviceCapturesMaxBytes, null, `"${raw}" は既定へ戻す`);
    assert.equal(input.value, "", `"${raw}" は空欄にする(既定値はプレースホルダ)`);
    assert.equal(input.placeholder, "20");
    assert.equal(isMonitorFromWebviewMessage(messages[0]), true);
  }
});

test("クリーンアップ: 既定へ戻した応答(configured が null)で欄が空欄に戻る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);
  const input = document.getElementById(INPUT_IDS.logsMaxBytes);
  assert.equal(input.value, "500");

  post(window, { ...RESPONSE, configured: { ...RESPONSE.configured, logsMaxBytes: null } });
  assert.equal(input.value, "", "実効値(policy)で埋め直さない");
  assert.equal(input.placeholder, "500");
});

test("応答の解釈: configured・minimums が無い応答は読めない扱い(古い CLI の形を吸わない)", () => {
  const { type: _type, ...json } = RESPONSE;
  assert.notEqual(parseRetentionResponse(json), undefined);
  const { configured: _configured, ...withoutConfigured } = json;
  assert.equal(parseRetentionResponse(withoutConfigured), undefined);
  const { minimums: _minimums, ...withoutMinimums } = json;
  assert.equal(parseRetentionResponse(withoutMinimums), undefined, "minimums も必須");
  assert.equal(parseRetentionResponse({ ...json, configured: { logsMaxBytes: "500" } }), undefined, "値の型も検める");
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

test("クリーンアップ: 「今すぐクリーンアップ」は runCleanup を送り、確認はホスト側に委ねる", (t) => {
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

  post(window, { type: "retention", cleanup: { state: "running", dryRun: false } });
  post(window, { type: "retention", cleanup: { state: "cancelled" } });
  assert.equal(document.getElementById("settings-cleanup-result").textContent, "", "取り消しは何も出さない");
  assert.equal(document.getElementById("settings-cleanup-now").disabled, false);
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
    configured: RESPONSE.configured,
    defaults: RESPONSE.defaults,
    usage: { deviceCaptures: null, recordings: null, reports: null, logs: null, xcresult: null },
  });
  // 上限はもう入っている(空欄で待たせない)
  assert.equal(
    document.getElementById(INPUT_IDS.logsMaxBytes).value,
    String(RESPONSE.policy.logsMaxBytes / 1024 / 1024),
  );
  const before = document.getElementById(`${INPUT_IDS.logsMaxBytes}-usage`).textContent;
  assert.equal(before, "現在 - MB", "測る前は計測待ちの表示(行の単位つき)");
  assert.equal(document.getElementById(`${INPUT_IDS.deviceCapturesMaxBytes}-usage`).textContent, "現在 - GB");

  // 2段目: `--usage` 付きの読み直しが届くと、同じ行が使用量で埋まる
  post(window, RESPONSE);
  const after = document.getElementById(`${INPUT_IDS.logsMaxBytes}-usage`).textContent;
  assert.ok(after.includes(formatBytes(RESPONSE.usage.logs, "MB")), `測った後: ${after}`);
});

test("クリーンアップ: 設定を変えた応答(使用量を測っていない)で使用量の表示を消さない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const logsUsage = () => document.getElementById(`${INPUT_IDS.logsMaxBytes}-usage`).textContent;
  const measured = formatBytes(RESPONSE.usage.logs, "MB");
  post(window, RESPONSE);

  // 書き込み(`--import`)の応答は `--usage` 無し。ホストの parseRetentionResponse は null を落として {} にする
  const writeResponse = {
    type: "retention",
    policy: { ...RESPONSE.policy, sweepAfterRun: false },
    configured: { ...RESPONSE.configured, sweepAfterRun: false },
    defaults: RESPONSE.defaults,
    usage: {},
  };
  post(window, writeResponse);
  assert.ok(logsUsage().includes(measured), `トグル後も残る: ${logsUsage()}`);
  assert.equal(document.getElementById("settings-cleanup-enabled").checked, false, "設定そのものは反映される");

  // 見積もりだけ(dry-run)は何も消していないので残す
  post(window, { ...writeResponse, cleanup: { state: "done", dryRun: true, freedBytes: 3 * BYTES_PER_GB } });
  assert.ok(logsUsage().includes(measured), `dry-run 後も残る: ${logsUsage()}`);

  // 実際に削除した直後は前の値が嘘になるので計測待ちに戻す(ホストが測り直して埋める)
  post(window, { ...writeResponse, cleanup: { state: "done", dryRun: false, freedBytes: 3 * BYTES_PER_GB } });
  assert.equal(logsUsage(), "現在 - MB", "削除後は古い使用量を出さない");
  // 測り直しの前に設定を変えても計測待ちのまま(古い値に戻らない)
  post(window, writeResponse);
  assert.equal(logsUsage(), "現在 - MB");
  post(window, RESPONSE);
  assert.ok(logsUsage().includes(measured), `測り直しで埋まる: ${logsUsage()}`);

  // 欄が使えなくなったら使用量も出さない
  post(window, { type: "retention", error: "unknown subcommand: retention" });
  assert.equal(logsUsage(), "");
});

// 空欄(既定値はプレースホルダ)でスピンボタン/↑↓キーを押したら既定値から増減する。jsdom はスピンの
// 増減そのものを実装しないので、縛るのは「押した瞬間に既定値が仮に入る」「増減が起きなければ空欄へ戻す」
test("空欄の数値欄は押した瞬間に既定値を起点として入れ、増減が起きなければ空欄へ戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  post(window, RESPONSE);
  post(window, { type: "lptHistoryRuns", value: null, default: 5 });
  post(window, { type: "remoteWaitLock", value: null, default: 3600 });
  post(window, { type: "remoteConfig", hosts: [], defaultFMConcurrency: 4,
    local: { machine: "local", host: "me@localhost", fmConcurrency: 0 } });

  const cases = [
    [document.getElementById(INPUT_IDS.recordingsMaxBytes), "100"],
    [document.getElementById("settings-lpt-history"), "5"],
    [document.getElementById("settings-remote-wait-lock"), "3600"],
    [document.querySelector(".settings-remote-hosts-fm-input"), "4"],
  ];
  for (const [input, expected] of cases) {
    assert.equal(input.value, "", `${input.id || input.className}: 前提は空欄`);

    // 文字部分をクリックしただけ(input が来ない)→ 空欄へ戻す
    input.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true }));
    assert.equal(input.value, expected, "押した瞬間は既定値が起点として入る");
    input.dispatchEvent(new window.MouseEvent("mouseup", { bubbles: true }));
    assert.equal(input.value, "", "増減が起きなければ空欄へ戻す");

    // スピンボタン(mousedown の既定動作で増減 → input)→ 残す
    input.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true }));
    input.value = String(Number(expected) + 1);
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    input.dispatchEvent(new window.MouseEvent("mouseup", { bubbles: true }));
    assert.equal(input.value, String(Number(expected) + 1), "増減した値は残す");

    // ↑↓キーも既定値から
    input.value = "";
    input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    assert.equal(input.value, expected, "↓キーでも既定値が起点");
    input.value = "";
  }

  // 明示値がある欄には触らない
  const explicit = document.getElementById(INPUT_IDS.logsMaxBytes);
  explicit.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true }));
  assert.equal(explicit.value, "500");
});

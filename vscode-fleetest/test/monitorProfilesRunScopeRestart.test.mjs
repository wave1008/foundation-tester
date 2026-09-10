// monitorProfilesRunScopeRestart.test.mjs
// 実行プロファイルの自動保存がモニターを再起動するのは、monitor が読む欄(machine/devices)が
// 変わったときだけ —— を「ロード → 保存 → watcher の判定」の実際の順序で縛る
// (monitorProfilesDeviceMachineScope.test.mjs と同じ fake-deps パターン)。
//
// 順序の罠: 保存の直後にホストはフォームへ再ロードを送る。そこで指紋を置き直すと、続いて来る
// watcher が「変化なし」と読み、devices を変えても再起動しない(タイルが古い台のまま残る)。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { MonitorProfilesController } from "../src/monitorProfilesController";

const RUN_PROFILE = {
  machine: "M1",
  app: "sampleapp",
  devices: [{ name: "シミュ1" }],
  heal: true,
  reportDir: "reports",
};

// webview の runProfileSave が送る全欄(runProfilesTab.js collectRunProfileFields)。
const FORM_FIELDS = {
  machine: "M1",
  app: "sampleapp",
  devices: [{ name: "シミュ1" }],
  fm: true,
  heal: true,
  falsePositiveCheck: true,
  triage: true,
  screenLooksLike: true,
  ocr: true,
  ocrFalsePositiveCheck: true,
  iosInappEngine: true,
  iosFastInput: false,
  iosPreActionWarmup: true,
  homeOnStart: true,
  playProtectBypass: true,
  enableAnimations: false,
  containerInference: true,
  updateWebView: true,
  wipeDataOnBloat: true,
  recoverCpuFallbackToGpu: false,
  record: false,
  recordFailuresOnly: false,
  recordBitrateKbps: "",
  recordFullResolution: false,
  wipeDataThresholdGB: "",
  locale: "",
  workspace: "",
  reportDir: "reports",
  defaultTimeout: "",
};

function makeController() {
  const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-run-scope-test-"));
  const runsDir = path.join(workspaceRoot, "TestProjects", "P", "profiles", "runs");
  fs.mkdirSync(runsDir, { recursive: true });
  const runPath = path.join(runsDir, "ios.json");
  fs.writeFileSync(runPath, `${JSON.stringify(RUN_PROFILE, null, 2)}\n`, "utf8");
  const posts = [];
  // コンストラクタ(FileSystemWatcher)は通さない。class field の初期化もされないので自前で置く
  const controller = Object.create(MonitorProfilesController.prototype);
  controller.runScopeKeys = new Map();
  controller.runFormWrites = new Map();
  controller.runEditedOutside = new Set();
  controller.deps = {
    workspaceRoot,
    getConfig: () => ({ binaryPath: "fleetest", project: "P", profile: "ios" }),
    outputChannel: { appendLine() {} },
    post: (message) => posts.push(message),
  };
  const save = (fields) => {
    controller.handleRunProfileSave({ type: "runProfileSave", profile: "ios", fields: { ...FORM_FIELDS, ...fields } });
    assert.equal(posts.filter((m) => m.type === "runProfileSaveResult").at(-1).ok, true);
  };
  return { controller, runPath, save };
}

test("FM のトグルだけの保存ではモニターを再起動しない", () => {
  const { controller, runPath, save } = makeController();
  controller.handleRunProfileLoad("ios");
  save({ heal: false });
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), false);
});

test("devices を変えた保存はモニターを再起動する(保存直後の再ロードで指紋を置き直さない)", () => {
  const { controller, runPath, save } = makeController();
  controller.handleRunProfileLoad("ios");
  save({ devices: [{ name: "シミュ1" }, { name: "シミュ2" }] });
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), true);
  // 同じ状態への2回目の通知(watcher は1書き込みで複数回鳴ることがある)は再起動しない
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), false);
});

test("machine を変えた保存はモニターを再起動する", () => {
  const { controller, runPath, save } = makeController();
  controller.handleRunProfileLoad("ios");
  save({ machine: "M2" });
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), true);
});

test("フォームが一度も読んでいないファイルの変更は、判定できないので再起動する", () => {
  const { controller, runPath } = makeController();
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), true);
});

// `api monitor` は実行プロファイルを全キーごとデコードする: 手で型を壊すと起動に失敗し(give-up)、
// その欄を直しても machine/devices は同じ。スコープだけで絞ると直してもモニターが戻らない
test("手編集はスコープが同じでも再起動し、その後の最初のフォーム保存も再起動する", () => {
  const { controller, runPath, save } = makeController();
  controller.handleRunProfileLoad("ios");
  save({ heal: false });
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), false);

  const handEdited = { ...JSON.parse(fs.readFileSync(runPath, "utf8")), defaultTimeout: "abc" };
  fs.writeFileSync(runPath, `${JSON.stringify(handEdited, null, 2)}\n`, "utf8");
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), true, "手編集で再起動しない");

  save({ heal: true, defaultTimeout: "5" });
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), true, "手編集で落ちたモニターをフォームで直しても戻らない");
  save({ heal: false, defaultTimeout: "5" });
  assert.equal(controller.runProfileChangeNeedsRestart(runPath), false, "以降のフォーム保存はスコープで絞る");
});
